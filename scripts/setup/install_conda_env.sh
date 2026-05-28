#!/usr/bin/env bash
# Install all pathseq-t2t dependencies into a single conda environment.
#
# Strategy: layered install (main -> metaphlan -> checkm2 -> checkv -> gtdbtk).
# Each layer is a separate `conda install` so failures stop early and we know
# which tool family forced a downgrade or conflict.
#
# Usage:
#   bash install_conda_env.sh                # run all layers
#   bash install_conda_env.sh main           # only layer 1
#   bash install_conda_env.sh metaphlan      # only layer 2
#   bash install_conda_env.sh checkm2        # only layer 3
#   bash install_conda_env.sh checkv         # only layer 4
#   bash install_conda_env.sh gtdbtk         # only layer 5
#   bash install_conda_env.sh verify         # smoke-test all tools

set -euo pipefail

ENV_NAME="${PST2T_ENV_NAME:-pathseq_t2t}"
ENV_PREFIX="/home/inspirewind/miniconda3/envs/${ENV_NAME}"

# Make conda available in this shell
source /home/inspirewind/miniconda3/etc/profile.d/conda.sh

# Force libmamba solver (default in conda 24.11 but be explicit)
export CONDA_SOLVER=libmamba
# Override global strict priority for this install only — bioconda's samtools
# pulls a libdeflate version not packaged in conda-forge, which strict mode
# refuses to mix. Flexible lets the solver pick across channels.
export CONDA_CHANNEL_PRIORITY=flexible

# Channel order matches envs/*.yml: bioconda first, conda-forge second
CHANNELS=(-c bioconda -c conda-forge -c defaults)

# ---------- helpers --------------------------------------------------------
env_exists() {
  conda env list | awk '{print $1}' | grep -qx "${ENV_NAME}"
}

layer() {
  local name="$1"; shift
  echo "============================================================"
  echo "[install] LAYER: ${name}"
  echo "[install] packages: $*"
  echo "============================================================"
  conda install -y -n "${ENV_NAME}" "${CHANNELS[@]}" "$@"
}

# ---------- layers ---------------------------------------------------------
# Layer 1 creates the env directly from envs/main.yml so channel priority
# (bioconda > conda-forge > defaults) is established from the start.
# Pre-creating an empty env with `conda create python=3.11` pulls libdeflate
# from defaults first and then conflicts with bioconda's htslib/samtools.
install_main() {
  # NOTE: We deliberately skip envs/main.yml because its pip section
  # (`sylph>=0.9.0`, `sylph-tax`) is broken: 'sylph' on PyPI is a placeholder
  # — the real binary lives on bioconda. We install everything via conda.
  if ! env_exists; then
    echo "[install] creating ${ENV_NAME} via conda env (channels from yml header)"
    # First create the env with python only; channel order will be set on subsequent install.
    conda create -y -n "${ENV_NAME}" "${CHANNELS[@]}" python=3.11
  fi
  layer "main (alignment + samtools + assembly + kraken2 + sylph)" \
    "samtools>=1.16" \
    "bwa>=0.7.17" \
    bowtie2 \
    picard \
    gatk4 \
    "megahit>=1.2.9" \
    "trim-galore>=0.6.10" \
    metabat2 \
    kraken2 \
    pigz \
    "pandas>=1.5" \
    "sylph>=0.9.0" \
    sylph-tax
}

install_metaphlan() {
  layer "metaphlan v4" "metaphlan>=4.0"
}

# Sidecar-env helper: build an isolated env and drop a PATH wrapper into
# scripts/setup/wrappers/ that exec()s the tool from that env.
# activate.sh prepends wrappers/ to PATH so the main env transparently
# sees these tools.
install_sidecar_env() {
  local env_name="$1"; shift   # e.g. pathseq_t2t_checkm2
  local tool="$1"; shift       # e.g. checkm2
  # Remaining args = conda specs (e.g. python=3.10 checkm2)
  local repo="${PST2T_REPO:-/mnt/STK4T/pathseq-t2t}"
  local wrap_dir="${repo}/scripts/setup/wrappers"
  mkdir -p "${wrap_dir}"

  echo "============================================================"
  echo "[install] SIDECAR env: ${env_name}  (tool: ${tool})"
  echo "[install] specs: $*"
  echo "============================================================"
  conda env list | awk '{print $1}' | grep -qx "${env_name}" || \
    conda create -y -n "${env_name}" "${CHANNELS[@]}" "$@"
  # Verify
  local tool_bin="/home/inspirewind/miniconda3/envs/${env_name}/bin/${tool}"
  [[ -x "${tool_bin}" ]] || { echo "[install] ERROR: ${tool} not found at ${tool_bin}"; return 1; }

  # Write wrapper. We prepend the sidecar env's bin/ to PATH so any subprocess
  # calls inside the tool (e.g. gtdbtk -> fastANI/skani/pplacer/prodigal,
  # checkv -> diamond, checkm2 -> diamond) find their dependencies inside the
  # sidecar env rather than in the calling shell's main env PATH.
  local sidecar_bin="/home/inspirewind/miniconda3/envs/${env_name}/bin"
  cat > "${wrap_dir}/${tool}" <<EOF
#!/bin/sh
# Auto-generated wrapper: pathseq-t2t routes ${tool} to sidecar env ${env_name}.
# Re-run scripts/setup/install_conda_env.sh ${tool} to regenerate.
PATH="${sidecar_bin}:\${PATH}" exec "${tool_bin}" "\$@"
EOF
  chmod +x "${wrap_dir}/${tool}"
  echo "[install] wrapper -> ${wrap_dir}/${tool} -> ${tool_bin}"
}

install_checkm2() {
  # Pin checkm2 1.1.0 explicitly — it's the latest and ships the current
  # uniref100.KO.1.dmnd format referenced by `checkm2 database --download` in
  # download_databases.sh. 1.1.0 requires python>3.12.
  install_sidecar_env pathseq_t2t_checkm2 checkm2 \
    "python=3.12" "checkm2=1.1.0"
}

install_checkv() {
  # checkv typically pins a specific diamond/python — keep it in a sidecar to
  # avoid downgrading main env. Default python 3.10 (matches envs/checkv.yml).
  install_sidecar_env pathseq_t2t_checkv checkv \
    "python=3.10" checkv
}

install_gtdbtk() {
  # gtdbtk pulls pplacer, fastANI, skani, prodigal, hmmer; the new wrapper
  # already prepends the sidecar env's bin to PATH, so all those subprocess
  # lookups resolve inside the sidecar env. No extra wrappers needed.
  install_sidecar_env pathseq_t2t_gtdbtk gtdbtk \
    "python=3.10" gtdbtk
}

# ---------- verify ---------------------------------------------------------
verify() {
  echo "============================================================"
  echo "[verify] tool presence + versions"
  echo "============================================================"
  # Source full activate.sh so sidecar wrappers are on PATH
  source "${PST2T_REPO:-/mnt/STK4T/pathseq-t2t}/scripts/setup/activate.sh"
  local rc=0
  for t in samtools bwa bowtie2 picard gatk megahit trim_galore metabat2 \
           kraken2 pigz sylph sylph-tax metaphlan checkm2 checkv gtdbtk; do
    if command -v "$t" >/dev/null 2>&1; then
      printf '  %-14s OK  %s\n' "$t" "$(command -v $t)"
    else
      printf '  %-14s MISSING\n' "$t"
      rc=1
    fi
  done
  echo
  if (( rc == 0 )); then
    echo "[verify] all tools present"
  else
    echo "[verify] some tools missing — see above"
    return $rc
  fi
}

# ---------- driver ---------------------------------------------------------
target="${1:-all}"
case "${target}" in
  all)        install_main; install_metaphlan; install_checkm2; install_checkv; install_gtdbtk; verify ;;
  main)       install_main ;;
  metaphlan)  install_metaphlan ;;
  checkm2)    install_checkm2 ;;
  checkv)     install_checkv ;;
  gtdbtk)     install_gtdbtk ;;
  verify)     verify ;;
  -h|--help)
    grep -E '^# ' "$0" | head -20
    echo
    echo "Targets: all main metaphlan checkm2 checkv gtdbtk verify"
    ;;
  *) echo "Unknown target: ${target}"; exit 2 ;;
esac
