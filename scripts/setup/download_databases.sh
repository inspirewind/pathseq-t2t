#!/usr/bin/env bash
# Reproducible download recipe for pathseq-t2t reference databases.
#
# Usage (recommended workflow):
#   1. Read & review this script.
#   2. Run individual sections on a bandwidth-rich machine, then rsync to
#      $PST2T_DB on this host.
#   3. Or run end-to-end here: `bash download_databases.sh all`
#      Sections can also be run individually:
#         bash download_databases.sh grch38
#         bash download_databases.sh t2t
#         bash download_databases.sh metaphlan
#         bash download_databases.sh sylph
#         bash download_databases.sh checkm2
#         bash download_databases.sh checkv
#         bash download_databases.sh gtdbtk
#
# Total disk: ~280 GB (GTDB-Tk dominates at ~110 GB).
# All downloads land under $PST2T_DB.

set -euo pipefail

: "${PST2T_DB:=/mnt/STK4T/pathseq-t2t-db}"
mkdir -p "${PST2T_DB}"
cd "${PST2T_DB}"

# Pick downloader (curl preferred, fall back to wget).
DL() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 5 --retry-delay 10 -o "${out}" "${url}"
  else
    wget --tries=5 --waitretry=10 -O "${out}" "${url}"
  fi
}

# ---------------------------------------------------------------------------
# 1) GRCh38 main reference (FASTQ->BAM first-pass alignment)
#    Source: Broad GATK resource bundle (the same hg38/v0 that pathseq_host
#    was built from, BUT with chrEBV retained so decoy-BED filtering works).
#    Size: ~3.0 GB fasta gz + ~10 GB bwa index + ~2 GB fai/dict
# ---------------------------------------------------------------------------
grch38() {
  mkdir -p grch38 && cd grch38
  local base="https://storage.googleapis.com/genomics-public-data/references/GRCh38"
  # Primary FASTA (analysis set, includes chrEBV, decoy, ALT, HLA)
  [[ -f Homo_sapiens_assembly38.fasta ]] || \
    DL "${base}/Homo_sapiens_assembly38.fasta" Homo_sapiens_assembly38.fasta
  [[ -f Homo_sapiens_assembly38.fasta.fai ]] || \
    DL "${base}/Homo_sapiens_assembly38.fasta.fai" Homo_sapiens_assembly38.fasta.fai
  [[ -f Homo_sapiens_assembly38.dict ]] || \
    DL "${base}/Homo_sapiens_assembly38.dict" Homo_sapiens_assembly38.dict
  # bwa index (pre-built on Broad public bucket; saves ~3 h CPU)
  for ext in 64.alt 64.amb 64.ann 64.bwt 64.pac 64.sa; do
    [[ -f "Homo_sapiens_assembly38.fasta.${ext}" ]] || \
      DL "${base}/Homo_sapiens_assembly38.fasta.${ext}" "Homo_sapiens_assembly38.fasta.${ext}"
  done
  # bwa-mem expects .alt without 64. prefix; symlink for convenience
  cd ..
  echo "[grch38] done -> ${PST2T_DB}/grch38/"
}

# ---------------------------------------------------------------------------
# 2) T2T-CHM13v2.0 (pathseq-t2t's t2tfilter reference)
#    Source: NCBI RefSeq
#    Size: ~960 MB gz, ~3 GB unpacked, +bwa index ~10 GB (built locally)
# ---------------------------------------------------------------------------
t2t() {
  mkdir -p t2t && cd t2t
  local url="https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/009/914/755/GCF_009914755.1_T2T-CHM13v2.0/GCF_009914755.1_T2T-CHM13v2.0_genomic.fna.gz"
  if [[ ! -f GCF_009914755.1_T2T-CHM13v2.0_genomic.fna ]]; then
    DL "${url}" GCF_009914755.1_T2T-CHM13v2.0_genomic.fna.gz
    gunzip GCF_009914755.1_T2T-CHM13v2.0_genomic.fna.gz
  fi
  # Build bwa index + faidx LOCALLY (needs bwa & samtools from pathseq_t2t env)
  if [[ ! -f GCF_009914755.1_T2T-CHM13v2.0_genomic.fna.bwt ]]; then
    echo "[t2t] building bwa index (~2-4 h on 8 cores)"
    bwa index GCF_009914755.1_T2T-CHM13v2.0_genomic.fna
  fi
  [[ -f GCF_009914755.1_T2T-CHM13v2.0_genomic.fna.fai ]] || \
    samtools faidx GCF_009914755.1_T2T-CHM13v2.0_genomic.fna
  cd ..
  echo "[t2t] done -> ${PST2T_DB}/t2t/"
}

# ---------------------------------------------------------------------------
# 3) MetaPhlAn 4 database (mpa_vJun23_CHOCOPhlAnSGB_202403)
#    Source: cmprod1.cibio.unitn.it (manual) OR metaphlan --install
#    Size: ~24 GB
#    Tip: easier to let `metaphlan` download via:
#       metaphlan --install --bowtie2db $PST2T_DB/metaphlan \
#                 --index mpa_vJun23_CHOCOPhlAnSGB_202403
# ---------------------------------------------------------------------------
metaphlan() {
  mkdir -p metaphlan
  if command -v metaphlan >/dev/null 2>&1; then
    echo "[metaphlan] using 'metaphlan --install' (recommended)"
    metaphlan --install \
      --bowtie2db "${PST2T_DB}/metaphlan" \
      --index mpa_vJun23_CHOCOPhlAnSGB_202403
  else
    echo "[metaphlan] metaphlan not on PATH; manual fallback URLs:"
    echo "  http://cmprod1.cibio.unitn.it/biobakery4/metaphlan_databases/"
    echo "  Required files (basename mpa_vJun23_CHOCOPhlAnSGB_202403):"
    echo "    *.1.bt2l *.2.bt2l *.3.bt2l *.4.bt2l *.rev.1.bt2l *.rev.2.bt2l"
    echo "    *.pkl *.fna.bz2 *_marker_info.txt.bz2 *_species.txt"
    return 1
  fi
  echo "[metaphlan] done -> ${PST2T_DB}/metaphlan/"
}

# ---------------------------------------------------------------------------
# 4) Sylph GTDB database (r226 species clusters, k=31, c=200)
#    Source: https://github.com/bluenote-1577/sylph/wiki/Pre%E2%80%90built-databases
#    Size: ~12 GB
# ---------------------------------------------------------------------------
sylph() {
  mkdir -p sylph && cd sylph
  # Pre-built DB (200-genome subsample) - check sylph wiki for latest URL.
  local db_url="https://storage.googleapis.com/sylph-stuff/v0.3-c200-gtdb-r220.syldb"
  local tax_url="https://github.com/bluenote-1577/sylph-utils/raw/main/taxonomy_files/gtdb_r220_metadata.tsv.gz"
  [[ -f v0.3-c200-gtdb-r220.syldb ]] || DL "${db_url}" v0.3-c200-gtdb-r220.syldb
  [[ -f gtdb_r220_metadata.tsv.gz  ]] || DL "${tax_url}" gtdb_r220_metadata.tsv.gz
  cd ..
  echo "[sylph] done -> ${PST2T_DB}/sylph/"
  echo "[sylph] NOTE: --sylph-taxonomy expects a sylph-tax registry name (e.g. 'GTDB_r220')."
  echo "[sylph]       Initialize with: sylph-tax download --download-dir ${PST2T_DB}/sylph/tax"
}

# ---------------------------------------------------------------------------
# 5) CheckM2 DB (DIAMOND profile)
#    Size: ~3 GB
# ---------------------------------------------------------------------------
checkm2() {
  mkdir -p checkm2
  if command -v checkm2 >/dev/null 2>&1; then
    checkm2 database --download --path "${PST2T_DB}/checkm2"
  else
    echo "[checkm2] manual fallback:"
    echo "  https://zenodo.org/record/5571251/files/checkm2_database.tar.gz"
    return 1
  fi
  echo "[checkm2] done -> ${PST2T_DB}/checkm2/"
}

# ---------------------------------------------------------------------------
# 6) CheckV DB
#    Size: ~6 GB
# ---------------------------------------------------------------------------
checkv() {
  mkdir -p checkv && cd checkv
  local url="https://portal.nersc.gov/CheckV/checkv-db-v1.5.tar.gz"
  [[ -d checkv-db-v1.5 ]] || {
    DL "${url}" checkv-db-v1.5.tar.gz
    tar -xzf checkv-db-v1.5.tar.gz
    rm checkv-db-v1.5.tar.gz
  }
  # Build DIAMOND DB once (required by `checkv end_to_end`)
  if command -v diamond >/dev/null 2>&1 && [[ ! -f checkv-db-v1.5/genome_db/checkv_reps.dmnd ]]; then
    cd checkv-db-v1.5/genome_db
    diamond makedb --in checkv_reps.faa -d checkv_reps
    cd "${PST2T_DB}/checkv"
  fi
  cd ..
  echo "[checkv] done -> ${PST2T_DB}/checkv/checkv-db-v1.5"
}

# ---------------------------------------------------------------------------
# 7) GTDB-Tk reference (release 232, matches gtdbtk 2.7.x)
#    Size: ~110 GB compressed, ~150 GB unpacked
#    *** Largest item; download on a bandwidth-rich host then rsync. ***
# ---------------------------------------------------------------------------
gtdbtk() {
  mkdir -p gtdbtk && cd gtdbtk
  local url="https://data.gtdb.aau.ecogenomic.org/releases/release232/232.0/auxillary_files/gtdbtk_package/full_package/gtdbtk_r232_data.tar.gz"
  if [[ ! -d release232 ]]; then
    DL "${url}" gtdbtk_r232_data.tar.gz
    mkdir -p release232
    tar -xzf gtdbtk_r232_data.tar.gz -C release232 --strip 1
    rm gtdbtk_r232_data.tar.gz
  fi
  cd ..
  echo "[gtdbtk] done -> ${PST2T_DB}/gtdbtk/release232"
  echo "[gtdbtk] Set: export GTDBTK_DATA_PATH=${PST2T_DB}/gtdbtk/release232"
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
target="${1:-}"
case "${target}" in
  all)        grch38; t2t; metaphlan; sylph; checkm2; checkv; gtdbtk ;;
  grch38)     grch38 ;;
  t2t)        t2t ;;
  metaphlan)  metaphlan ;;
  sylph)      sylph ;;
  checkm2)    checkm2 ;;
  checkv)     checkv ;;
  gtdbtk)     gtdbtk ;;
  ""|-h|--help)
    grep -E '^# [0-9]\)' "$0"
    echo
    echo "Usage: $0 {all|grch38|t2t|metaphlan|sylph|checkm2|checkv|gtdbtk}"
    ;;
  *) echo "Unknown target: ${target}"; exit 2 ;;
esac
