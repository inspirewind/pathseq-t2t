#!/usr/bin/env bash

# Shared requirement/version/index helpers for pathseq-t2t commands.
_semver_ge() { # usage: _semver_ge MIN ACTUAL
  # returns 0 if ACTUAL >= MIN
  printf '%s\n' "$1" "$2" | sort -V | tail -n1 | grep -qx "$2"
}

_require_samtools_116() {
  local smver
  smver=$(samtools --version 2>/dev/null | head -n1 | awk '{print $2}')
  [[ -n "${smver:-}" ]] || die "samtools not found on PATH."
  _semver_ge "1.16.0" "$smver" || die "samtools >=1.16 required (found $smver). Please upgrade."
}

_parse_first_version() { # print first x.y[.z] from stdin
  grep -Eo '[0-9]+(\.[0-9]+){1,3}' | head -n1
}

# Returns 0 if GATK >= 4 is found; prints the detected version to stdout.
_require_gatk4() {
  if ! command -v gatk >/dev/null 2>&1; then
    die "GATK not found on PATH (need gatk >= 4)."
  fi

  # Avoid set -e/pipefail breaking on non-zero; capture both stdout & stderr.
  local ver_line
  ver_line="$(( gatk --version 2>&1 || true ) | head -n1)"

  # Fallbacks: some builds put version in --help output.
  if [[ -z "$ver_line" ]]; then
    ver_line="$(( gatk --help 2>&1 || true ) | head -n3 | tr -d '\r')"
  fi

  # Extract a semantic version like 4.3.0.0
  local ver
  ver="$(grep -Eo '([0-9]+\.){1,3}[0-9]+' <<<"$ver_line" | head -n1)"

  if [[ -z "$ver" ]]; then
    die "Could not determine GATK version. Probe output: ${ver_line:-<empty>}"
  fi

  # Compare versions (needs sort -V)
  if [[ "$(printf '%s\n' '4.0.0' "$ver" | sort -V | head -n1)" != "4.0.0" ]]; then
    die "GATK >= 4 required (found $ver)."
  fi

  log "Detected GATK version: ${ver}"

  # printf '%s\n' "$ver"
}

_require_java17() {
  local java_major
  java_major=$(java -version 2>&1 | head -n1 | sed -E 's/.*version "([0-9]+).*/\1/')
  [[ "${java_major:-0}" -eq 17 ]] || die "Java 17 required (found major ${java_major:-unknown})."
}

_require_picard() {
  if [[ -z "${PICARD_JAR}" || ! -f "${PICARD_JAR}" ]]; then
    die "--picard-jar not provided or invalid. You can download Picard from the following location:
      https://github.com/broadinstitute/picard/releases/latest
    Download the latest version and provide the path to the picard.jar file when running the script."
  fi
  # Check if the provided Picard JAR file exists
  require_file "${PICARD_JAR}"
  log "Picard found at: ${PICARD_JAR}"
}

_require_bwa() {
  if ! command -v bwa >/dev/null 2>&1; then
    die "bwa not found on PATH.

Install via conda:
  conda install -c bioconda bwa

Or build from source:
  git clone https://github.com/lh3/bwa.git
  cd bwa && make
  export PATH=\$PWD:\$PATH"
  fi

  # Capture version text without tripping 'set -e'
  local raw
  raw="$(( bwa 2>&1 || true ) | head -n5)"

  # Try to extract something like 0.7.17, 0.7.17-r1188, 0.7.17-r1198-dirty, etc.
  local ver
  ver="$(grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' <<<"$raw" | head -n1)"

  if [[ -z "$ver" ]]; then
    die "Could not determine bwa version from output:
$raw"
  fi

  # Require >= 0.7.17 for stable 'bwa mem'
  if [[ "$(printf '%s\n' '0.7.17' "$ver" | sort -V | head -n1)" != "0.7.17" ]]; then
    die "bwa >= 0.7.17 required for 'bwa mem' (found $ver).

bwa reported:
$raw

Upgrade via conda:
  conda install -c bioconda bwa>=0.7.17"
  fi

  log "Detected bwa version: $ver"
}


# Ensure kraken2 executable is available (optional version log).
_require_kraken2() {
  command -v kraken2 >/dev/null 2>&1 || die "kraken2 not found on PATH."
  local kver
  kver="$(kraken2 --version 2>&1 | head -n1 | _parse_first_version || true)"
  [[ -n "$kver" ]] && log "Detected Kraken2 version: $kver"
}



# Ensure MetaPhlAn v4 executable is available and version >= 4
_require_metaphlan4() {
  command -v metaphlan >/dev/null 2>&1 || die "metaphlan not found on PATH."
  local mver_line mver
  mver_line="$(metaphlan --version 2>&1 | head -n1 || true)"
  mver="$(printf '%s' "$mver_line" | _parse_first_version || true)"
  [[ -n "$mver" ]] || die "Could not determine MetaPhlAn version (got: ${mver_line:-<empty>})."
  _semver_ge "4.0.0" "$mver" || die "MetaPhlAn >= 4.0.0 required (found $mver)."
  log "Detected MetaPhlAn version: $mver"
}

# ---- Sylph: require sylph >= 0.9.0 ------------------------------------------
_require_sylph_090() {
  if ! command -v sylph >/dev/null 2>&1; then
    die "Sylph not found. Install with:
  conda install -c bioconda sylph=0.9"
  fi
  local raw v
  raw="$(sylph --version 2>&1 || sylph -V 2>&1 || true)"
  v="$(grep -oE '[0-9]+(\.[0-9]+){1,3}' <<<"$raw" | head -n1)"
  [[ -n "$v" ]] || die "Could not parse Sylph version from: ${raw}"
  _semver_ge "0.9.0" "$v" || die "Sylph >= 0.9.0 required (found ${v}). Try:
  conda install -c bioconda sylph=0.9"
}

# ---- Sylph: require sylph-tax (any version) ---------------------------------
_require_sylph_tax() {
  if ! command -v sylph-tax >/dev/null 2>&1; then
    die "sylph-tax not found. Install with:
  conda install -c bioconda sylph-tax"
  fi
}

_require_trim_galore_0610() {
  command -v trim_galore >/dev/null 2>&1 || die "trim_galore not found on PATH."
  local raw v
  raw="$(trim_galore --version 2>&1 || true)"
  v="$(
    awk '
      match($0, /[Vv]ersion[[:space:]]+([0-9]+(\.[0-9]+){1,3})/, m) { print m[1]; exit }
      match($0, /^trim_galore[[:space:]]+([0-9]+(\.[0-9]+){1,3})/, m) { print m[1]; exit }
    ' <<<"$raw"
  )"
  [[ -n "$v" ]] || die "Could not parse trim_galore version from output:
${raw:-<empty>}"
  _semver_ge "0.6.10" "$v" || die "trim_galore >= 0.6.10 required (found ${v})."
}

_require_megahit_129() {
  command -v megahit >/dev/null 2>&1 || die "megahit not found on PATH."
  local raw v
  raw="$(megahit --version 2>&1 | head -n1 || true)"
  v="$(grep -oE '[0-9]+(\.[0-9]+){1,3}' <<<"$raw" | head -n1)"
  [[ -n "$v" ]] || die "Could not parse MEGAHIT version from: ${raw}"
  _semver_ge "1.2.9" "$v" || die "MEGAHIT >= 1.2.9 required (found ${v})."
}

_require_bowtie2() {
  command -v bowtie2 >/dev/null 2>&1 || die "bowtie2 not found on PATH."
  command -v bowtie2-build >/dev/null 2>&1 || die "bowtie2-build not found on PATH."
}

_require_metabat2() {
  command -v metabat2 >/dev/null 2>&1 || die "metabat2 not found on PATH."
  command -v jgi_summarize_bam_contig_depths >/dev/null 2>&1 || die "jgi_summarize_bam_contig_depths not found (usually ships with MetaBAT2)."
}

_require_checkm2() {
  command -v checkm2 >/dev/null 2>&1 || die "checkm2 not found on PATH."
}

_require_checkv() {
  command -v checkv >/dev/null 2>&1 || die "checkv not found on PATH."
}

_require_gtdbtk() {
  command -v gtdbtk >/dev/null 2>&1 || die "gtdbtk not found on PATH."
  [[ -n "${GTDBTK_DATA_PATH:-}" ]] || die "GTDBTK_DATA_PATH is not set. GTDB-Tk requires GTDBTK_DATA_PATH to point to the reference data directory."
  [[ -d "${GTDBTK_DATA_PATH}" ]] || die "GTDBTK_DATA_PATH directory not found: ${GTDBTK_DATA_PATH}"
}

_compress_to() { # usage: _compress_to <out.gz> <threads>
  local out="$1" threads="$2"
  if command -v pigz >/dev/null 2>&1; then
    pigz -p "${threads}" -c > "${out}"
  else
    gzip -c > "${out}"
  fi
}




# Helper function to ensure the required PathSeq host directory is available
# Usage: _require_hostdir [<hostdir>]
_require_hostdir() {
  local hostdir_arg="${1:-}"
  # Prefer explicit argument; fall back to $HOSTDIR if set
  local hostdir="${hostdir_arg:-${HOSTDIR:-}}"

  local hostdir_message="HOSTDIR or --hostdir is not set or missing required files. You must specify it (contains pathseq_host.bfi & pathseq_host.fa.img).

You can download and prepare the necessary files using the following commands:

  mkdir host_dir
  gcloud storage cp gs://gatk-best-practices/pathseq/resources/pathseq_host.bfi gs://gatk-best-practices/pathseq/resources/pathseq_host.fa.img ./host_dir
  export HOSTDIR=\$PWD/host_dir

Note: The host directory requires approximately 14 GB of space."

  # Check if hostdir is set
  if [[ -z "${hostdir}" ]]; then
    echo "$hostdir_message"
    die "HOSTDIR is not set."
  fi

  # Check if required files are present in the specified hostdir
  local bfi_file="${hostdir}/pathseq_host.bfi"
  local fa_img_file="${hostdir}/pathseq_host.fa.img"

  if [[ ! -f "$bfi_file" || ! -f "$fa_img_file" ]]; then
    echo "$hostdir_message"
    die "HOSTDIR is missing required files."
  fi

  # Propagate to global HOSTDIR so downstream code can use it
  HOSTDIR="${hostdir}"
  log "HOSTDIR verified: ${HOSTDIR}"
}


# Resolve and validate the T2T reference FASTA.
# Usage: ref_path="$(_require_t2tref "<optional_path_from_flag>")"
_require_t2tref() {
  local ref_in="${1:-}" src="--reference"
  if [[ -z "${ref_in}" ]]; then
    ref_in="${T2TREF:-}"
    src="\$T2TREF"
  fi

  if [[ -z "${ref_in}" || ! -f "${ref_in}" ]]; then
    local MSG="No T2T reference found.
Provide a path via --reference <t2t.fa> or set \$T2TREF to the FASTA file.

You can obtain the T2T-CHM13v2.0 reference from NCBI and index it like this:

  mkdir -p t2tref && cd t2tref
  wget https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/009/914/755/GCF_009914755.1_T2T-CHM13v2.0/GCF_009914755.1_T2T-CHM13v2.0_genomic.fna.gz
  gunzip GCF_009914755.1_T2T-CHM13v2.0_genomic.fna.gz

  # Build indexes (requires bwa and samtools)
  bwa index GCF_009914755.1_T2T-CHM13v2.0_genomic.fna
  samtools faidx GCF_009914755.1_T2T-CHM13v2.0_genomic.fna

  # Use it for this pipeline
  export T2TREF=\$PWD/GCF_009914755.1_T2T-CHM13v2.0_genomic.fna

Then re-run this command."
    die "${MSG}"
  fi

  log "Using T2T reference: ${ref_in}"
}


# Require a Kraken2 database directory (standardized: *index)
# Usage: _require_kraken2_index /path/to/kraken2_index
_require_kraken2_index() {
  local idx_dir="$1"
  if [[ -z "${idx_dir}" ]]; then
    die "No Kraken2 index provided (--kraken-index) or export \$KRAKEN_INDEX."
  fi
  if [[ ! -d "${idx_dir}" ]]; then
    die "Kraken2 index directory not found: ${idx_dir}
See: https://benlangmead.github.io/aws-indexes/k2"
  fi
  # Kraken2 core files
  for f in hash.k2d opts.k2d taxo.k2d; do
    [[ -f "${idx_dir}/${f}" ]] || die "Kraken2 index incomplete: missing ${f} in ${idx_dir}
See: https://benlangmead.github.io/aws-indexes/k2"
  done
  log "Detected valid Kraken2 index: ${idx_dir}"
}


# Require a MetaPhlAn4 database (Bowtie2 index basename)
# Usage: _require_metaphlan4db /path/to/mpa_index
_require_metaphlan4_index() {
  local index_name="$1"
  local bt2_dir="$2"

  [[ -n "${index_name}" ]] || die "No MetaPhlAn index provided (--metaphlan-index) or export \$METAPHLAN_INDEX."
  [[ -n "${bt2_dir}"    ]] || die "No Bowtie2 index directory provided (--bowtie2-index) or export \$BOWTIE2_INDEX."
  [[ -d "${bt2_dir}"    ]] || die "Bowtie2 index directory not found: ${bt2_dir}"

  local base="${bt2_dir%/}/${index_name}"
  local missing=()
  for ext in 1.bt2l 2.bt2l 3.bt2l 4.bt2l rev.1.bt2l rev.2.bt2l; do
    [[ -f "${base}.${ext}" ]] || missing+=("${base}.${ext}")
  done

  if (( ${#missing[@]} > 0 )); then
    die "MetaPhlAn index appears incomplete under ${bt2_dir} for basename '${index_name}'.
Missing files:
  ${missing[*]}
See: http://cmprod1.cibio.unitn.it/biobakery4/metaphlan_databases/"
  fi

  log "Detected valid MetaPhlAn4 index: ${base}"
}


# Takes a list of paths; each must exist (file or dir). Builds -d args in the
# global array variable 'sylph_ref_args'.
_require_sylph_dbs() {
  sylph_ref_args=()
  if [[ $# -lt 1 ]]; then
    die "Provide at least one --sylph-db <path> (repeatable) to run Sylph."
  fi
  local p
  for p in "$@"; do
    [[ -e "$p" ]] || die "Sylph DB path not found: $p"
    sylph_ref_args+=("-d" "$p")
  done
}
