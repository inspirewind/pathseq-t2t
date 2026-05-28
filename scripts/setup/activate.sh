#!/usr/bin/env bash
# Source me to enable pathseq-t2t on this host.
#   source /mnt/STK4T/pathseq-t2t/scripts/setup/activate.sh
#
# Idempotent: safe to source multiple times.
# Do NOT exec this file (it must export into the calling shell).

# ----- Repo & conda env -----------------------------------------------------
export PST2T_REPO="/mnt/STK4T/pathseq-t2t"
export PST2T_ENV_NAME="pathseq_t2t"
export PST2T_ENV_PREFIX="/home/inspirewind/miniconda3/envs/${PST2T_ENV_NAME}"

# Activate the conda env (without polluting .bashrc).
# Note: CONDA_SHLVL/CONDA_EXE env vars get inherited by child shells, but the
# `conda` shell function does NOT. Check for the function itself.
if ! type conda >/dev/null 2>&1 || [[ "$(type -t conda 2>/dev/null)" != "function" ]]; then
  source /home/inspirewind/miniconda3/etc/profile.d/conda.sh
fi
if ! conda activate "${PST2T_ENV_NAME}"; then
  echo "[activate] WARN: conda env '${PST2T_ENV_NAME}' not yet created or activation failed; skipping."
fi

# ----- Storage layout -------------------------------------------------------
export PST2T_DB="/mnt/STK4T/pathseq-t2t-db"          # downloaded refs/indexes (SSD)
export PST2T_WORK="/mnt/HC5501/colorectal_pathseq-t2t" # intermediates & outputs (HDD)
export PST2T_FASTQ="/mnt/PURZ/colorectal_clean_fq/fastq"

# ----- pathseq-t2t expected env vars ----------------------------------------
# HOSTDIR / T2TREF / KRAKEN_INDEX / METAPHLAN_INDEX / BOWTIE2_INDEX / CHECKVDB / GTDBTK_DATA_PATH
export HOSTDIR="/mnt/HC5501/Pathseq/dataset"        # has pathseq_host.bfi & pathseq_host.fa.img
export T2TREF="${PST2T_DB}/t2t/GCF_009914755.1_T2T-CHM13v2.0_genomic.fna"
export KRAKEN_INDEX="/mnt/STK4T/kraken2/k2-standard"
export METAPHLAN_INDEX="mpa_vJan25_CHOCOPhlAnSGB_202503"
export BOWTIE2_INDEX="${PST2T_DB}/metaphlan"
export CHECKVDB="${PST2T_DB}/checkv/checkv-db-v1.5"
export GTDBTK_DATA_PATH="${PST2T_DB}/gtdbtk/release232"
export CHECKM2DB="${PST2T_DB}/checkm2/CheckM2_database/uniref100.KO.1.dmnd"
export SYLPH_DB="${PST2T_DB}/sylph/gtdb-r226-c200-dbv1.syldb"
export SYLPH_TAXONOMY="GTDB_r226"

# ----- First-pass alignment reference (GRCh38, with chrEBV+decoys) ----------
export PST2T_GRCH38="${PST2T_DB}/grch38/Homo_sapiens_assembly38.fasta"

# ----- Picard jar (conda picard ships under share/picard-X.Y.Z-N/picard.jar)
# bin/picard is a symlink into that share/ dir; readlink -f gives the wrapper
# inside share/, so the jar sits as a sibling of the wrapper.
if command -v picard >/dev/null 2>&1; then
  _picard_wrapper="$(readlink -f "$(command -v picard)")"
  _picard_jar_candidate="$(dirname "${_picard_wrapper}")/picard.jar"
  if [[ -f "${_picard_jar_candidate}" ]]; then
    export PICARD_JAR="${_picard_jar_candidate}"
  else
    # Fallback: search under CONDA_PREFIX/share for picard-*/picard.jar
    _picard_jar_candidate="$(ls -1 "${CONDA_PREFIX:-/dev/null}"/share/picard-*/picard.jar 2>/dev/null | head -n1)"
    [[ -n "${_picard_jar_candidate}" ]] && export PICARD_JAR="${_picard_jar_candidate}"
  fi
  unset _picard_wrapper _picard_jar_candidate
fi

# ----- CLI on PATH ----------------------------------------------------------
case ":${PATH}:" in
  *":${PST2T_REPO}/src:"*) ;;
  *) export PATH="${PST2T_REPO}/src:${PATH}" ;;
esac

# ----- Sidecar-env wrappers on PATH (checkm2, checkv, gtdbtk, …) ------------
# Wrappers exec into pathseq_t2t_{checkm2,checkv,gtdbtk} envs without us
# having to switch conda envs.
if [[ -d "${PST2T_REPO}/scripts/setup/wrappers" ]]; then
  case ":${PATH}:" in
    *":${PST2T_REPO}/scripts/setup/wrappers:"*) ;;
    *) export PATH="${PST2T_REPO}/scripts/setup/wrappers:${PATH}" ;;
  esac
fi

# ----- Sanity hint ----------------------------------------------------------
if [[ "${PST2T_QUIET:-0}" != "1" ]]; then
  echo "[pathseq-t2t] env activated: ${PST2T_ENV_NAME}"
  echo "[pathseq-t2t]  HOSTDIR=${HOSTDIR}"
  echo "[pathseq-t2t]  T2TREF=${T2TREF}"
  echo "[pathseq-t2t]  KRAKEN_INDEX=${KRAKEN_INDEX}"
  echo "[pathseq-t2t]  METAPHLAN_INDEX=${METAPHLAN_INDEX}"
  echo "[pathseq-t2t]  SYLPH_DB=${SYLPH_DB}"
  echo "[pathseq-t2t]  CHECKM2DB=${CHECKM2DB}"
  echo "[pathseq-t2t]  GTDBTK_DATA_PATH=${GTDBTK_DATA_PATH}"
  echo "[pathseq-t2t]  PST2T_DB=${PST2T_DB}"
  echo "[pathseq-t2t]  PST2T_WORK=${PST2T_WORK}"
fi
