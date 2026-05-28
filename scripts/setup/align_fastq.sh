#!/usr/bin/env bash
# Align paired-end FASTQ to GRCh38 (Broad Homo_sapiens_assembly38.fasta) to
# produce the host-aligned BAM that pathseq-t2t's `prefilter` consumes.
#
# Usage:
#   source /mnt/STK4T/pathseq-t2t/scripts/setup/activate.sh
#   bash align_fastq.sh <SAMPLE_ID> [--threads N]
#
#   # Or batch:
#   bash align_fastq.sh --batch SRR34072063 SRR34072064 SRR34072065
#
# Inputs (resolved from $PST2T_FASTQ):
#   ${SID}_R1.clean.fq.gz, ${SID}_R2.clean.fq.gz
#
# Output:
#   $PST2T_WORK/bams_hg38/${SID}.bam (+ .bai)
#
# Notes:
# - We do NOT mark duplicates here; PathSeqFilterSpark in qcfilter does its own
#   QC and PathSeq has historically been run on unduplicated BAM.
# - Read-group is set so downstream tools don't complain.
# - Uses pre-built bwa index at $PST2T_GRCH38; samtools sort streams from bwa.

set -euo pipefail

: "${PST2T_GRCH38:?run: source scripts/setup/activate.sh}"
: "${PST2T_FASTQ:?run: source scripts/setup/activate.sh}"
: "${PST2T_WORK:?run: source scripts/setup/activate.sh}"

BAM_DIR="${PST2T_WORK}/bams_hg38"
mkdir -p "${BAM_DIR}"

THREADS_DEFAULT=32
SORT_THREADS_DEFAULT=8

align_one() {
  local sid="$1" t="${2:-${THREADS_DEFAULT}}" st="${3:-${SORT_THREADS_DEFAULT}}"
  local r1="${PST2T_FASTQ}/${sid}_R1.clean.fq.gz"
  local r2="${PST2T_FASTQ}/${sid}_R2.clean.fq.gz"
  local out="${BAM_DIR}/${sid}.bam"

  [[ -f "$r1" && -f "$r2" ]] || { echo "[align] FASTQ pair missing for ${sid}"; return 1; }
  if [[ -s "$out" ]] && samtools quickcheck "$out" 2>/dev/null; then
    echo "[align] ${sid}: BAM already exists & passes quickcheck — skip"
    return 0
  fi

  echo "[align] ${sid}: bwa mem -t ${t} | samtools sort -@ ${st} → ${out}"
  bwa mem -t "${t}" -K 100000000 -Y \
       -R "@RG\tID:${sid}\tSM:${sid}\tLB:${sid}\tPL:ILLUMINA" \
       "${PST2T_GRCH38}" "${r1}" "${r2}" \
    | samtools sort -@ "${st}" -m 2G -T "${BAM_DIR}/.${sid}.sort" -o "${out}".tmp -
  mv "${out}".tmp "${out}"
  samtools index -@ "${st}" "${out}"
  echo "[align] ${sid}: done"
}

main() {
  if [[ "${1:-}" == "--batch" ]]; then
    shift
    [[ $# -ge 1 ]] || { echo "Usage: $0 --batch SID1 SID2 ..."; exit 2; }
    for sid in "$@"; do align_one "${sid}"; done
  else
    local sid="${1:-}" threads="${THREADS_DEFAULT}"
    [[ -n "${sid}" ]] || { echo "Usage: $0 <SAMPLE_ID> [--threads N]"; exit 2; }
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --threads) threads="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 2 ;;
      esac
    done
    align_one "${sid}" "${threads}"
  fi
}

main "$@"
