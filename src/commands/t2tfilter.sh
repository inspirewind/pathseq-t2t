cmd_t2tfilter() {
  local input_paired="" input_unpaired="" reference=""
  local decoys_to_mask=""
  local output_paired="" output_unpaired=""
  local flagstat_unaligned_paired=""
  local flagstat_unaligned_unpaired=""
  local threads=""
  local sample_id=""
  local dont_overwrite=0
  local keep_intermediate=0
  local PICARD_JAR="${PICARD_JAR:-}"

  # 1) OUTDIR defaults up front (user can still override via --outdir)
  : "${OUTDIR:=./pst2t_out}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      # IDs / dirs to use as defaults for input/output
      --outdir)              OUTDIR="${2:?--outdir requires a directory path}" ; shift 2 ; _set_outdirs ;;
      --dont-overwrite)      dont_overwrite=1; shift ;;

      # Inputs (explicit; otherwise inferred from --outdir + --sample-id/base)
      --input-paired)        input_paired="${2:-}"; shift 2 ;;
      --input-unpaired)      input_unpaired="${2:-}"; shift 2 ;;

      # Reference
      --reference)           reference="${2:-}"; shift 2 ;;
      --decoys-to-mask)      decoys_to_mask="${2:-}"; shift 2 ;;

      # Outputs (explicit; otherwise inferred from --outdir + sample/base)
      --output-paired)       output_paired="${2:-}"; shift 2 ;;
      --output-unpaired)     output_unpaired="${2:-}"; shift 2 ;;

      # Flagstat TSV overrides (explicit; otherwise inferred)
      --flagstat-unaln-paired)   flagstat_unaligned_paired="${2:-}"; shift 2 ;;
      --flagstat-unaln-unpaired) flagstat_unaligned_unpaired="${2:-}"; shift 2 ;;

      # Resources / behavior
      --threads)             threads="${2:-}"; shift 2 ;;
      --sample-id)           sample_id="${2:-}"; shift 2 ;;

      --keep-intermediate)   keep_intermediate=1; shift ;;
      --picard-jar)          PICARD_JAR="${2:-}"; shift 2 ;;

      -h|--help)
        cat <<'HLP'
Usage: pathseq-t2t t2tfilter [ARGS] \

Core options:
  [--outdir <dir>]                  Root output directory (default: ./pst2t_out)
  [--sample-id <string>]            Sample ID to use for naming inputs/outputs if needed
  [--input-paired <bam>]            QC-filtered paired BAM from qcfilter (if omitted, inferred when --sample-id is provided)
  [--input-unpaired <bam>]          QC-filtered unpaired BAM from qcfilter (if omitted, inferred when --sample-id is provided)
  [--reference <t2t.fa>]            T2T reference FASTA (or set \$T2TREF)
  [--decoys-to-mask <bed|None>]     BED of decoy/blacklist regions to retain and merge into final outputs
  [--output-paired <bam>]           Output unmapped (to T2T) paired reads (default: <outdir>/bams/<ID>.t2tfilt_paired.bam)
  [--output-unpaired <bam>]         Output unmapped (to T2T) unpaired reads (default: <outdir>/bams/<ID>.t2tfilt_unpaired.bam)
  [--flagstat-unaln-paired <tsv>]   Flagstat of paired T2T-unmapped output (default: inferred)
  [--flagstat-unaln-unpaired <tsv>] Flagstat of unpaired T2T-unmapped output (default: inferred)

Performance / env:
  [--threads <int>]                 CPU threads (default: auto-detect)
  [--picard-jar </path/picard.jar>] Use a specific Picard JAR instead of 'picard' on PATH
  [--dont-overwrite]                Skip whole step if final outputs already exist
  [--keep-intermediate]             Keep intermediate FASTQs and aligned BAMs (default: remove)

Notes:
- Inputs default to: <outdir>/bams/<ID>.qcfilt_paired.bam and <outdir>/bams/<ID>.qcfilt_unpaired.bam.
- Required reference: provide --reference <t2t.fa> or set \$T2TREF.
- If --sample-id is provided, missing input/output/flagstat paths are filled from defaults.
- If --sample-id is omitted, provide explicit --input-paired, --input-unpaired, --output-paired, --output-unpaired, --flagstat-unaln-paired, and --flagstat-unaln-unpaired.
- If --decoys-to-mask is provided (and not "None"), decoy-overlapping reads from aligned sets are merged into final outputs.
- Requires: samtools >=1.16, Java 17, bwa on PATH, and a T2T reference (--reference or \$T2TREF).
HLP
        return 0 ;;
      --) shift; break ;;
      -*) die "Unknown option for t2tfilter: $1" ;;
      *)  die "Unexpected argument to t2tfilter: $1" ;;
    esac
  done

  # --- Version / tool checks ---
  _require_samtools_116
  _require_java17
  _require_picard
  _require_bwa
  _require_t2tref "${reference:-}"

  # --- Reference handling ---
  if [[ -z "${reference}" ]]; then
    if [[ -n "${T2TREF:-}" ]]; then
      reference="${T2TREF}"
      log "Using reference from T2TREF: ${reference}"
    else
      die "No reference provided. Use --reference <t2t.fa> or set T2TREF environment variable."
    fi
  fi
  require_file "${reference}"

  # Normalize/interpret decoy regions; build L_ARG as an array to avoid quoting issues
  local -a L_ARG=()
  if [[ -n "${decoys_to_mask}" ]]; then
    if [[ "${decoys_to_mask,,}" == "none" ]]; then
      decoys_to_mask=""
      L_ARG=()
    else
      require_file "${decoys_to_mask}"
      if command -v readlink >/dev/null 2>&1; then
        local abs_rl
        abs_rl="$(readlink -f "${decoys_to_mask}" 2>/dev/null || true)"
        [[ -n "${abs_rl}" ]] && decoys_to_mask="${abs_rl}"
      fi
      L_ARG=(-L "${decoys_to_mask}")
      miss=$(
        comm -23 \
          <(awk 'NF&&$1!~/^#/{print $1}' "${decoys_to_mask}" | sort -u) \
          <(awk '/^>/{h=$0; sub(/^>/,"",h); sub(/[[:space:]].*$/,"",h); print h}' "${reference}" | sort -u)
      )
      [[ -z "${miss}" ]] || echo "[t2tfilter] WARNING: BED chrom(s) not in reference FASTA headers: ${miss}" >&2
    fi
  fi

  # Ensure OUTDIR subfolders are present even if --outdir wasn’t passed
  if declare -F _set_outdirs >/dev/null; then
    _set_outdirs
  else
    OUTDIR_BAMS="${OUTDIR}/bams"
    OUTDIR_FILTER="${OUTDIR}/filter_stats"
  fi
  mkdir -p "${OUTDIR_BAMS}" "${OUTDIR_FILTER}"

  # ---------- Naming policy ----------
  # - with --sample-id: fill missing paths from defaults
  # - without --sample-id: require explicit input/output/flagstat paths
  local sample_base=""
  if [[ -n "${sample_id}" ]]; then
    sample_base="${sample_id}"
    [[ -n "${input_paired}" ]] || input_paired="${OUTDIR_BAMS}/${sample_base}.qcfilt_paired.bam"
    [[ -n "${input_unpaired}" ]] || input_unpaired="${OUTDIR_BAMS}/${sample_base}.qcfilt_unpaired.bam"
    [[ -n "${output_paired}" ]] || output_paired="${OUTDIR_BAMS}/${sample_base}.t2tfilt_paired.bam"
    [[ -n "${output_unpaired}" ]] || output_unpaired="${OUTDIR_BAMS}/${sample_base}.t2tfilt_unpaired.bam"
    [[ -n "${flagstat_unaligned_paired}" ]] || flagstat_unaligned_paired="${OUTDIR_FILTER}/${sample_base}.t2tfilt_paired.t2t_unaln.flagstat.tsv"
    [[ -n "${flagstat_unaligned_unpaired}" ]] || flagstat_unaligned_unpaired="${OUTDIR_FILTER}/${sample_base}.t2tfilt_unpaired.t2t_unaln.flagstat.tsv"
  else
    require_nonempty "${input_paired}" "--input-paired (required when --sample-id is not provided)"
    require_nonempty "${input_unpaired}" "--input-unpaired (required when --sample-id is not provided)"
    require_nonempty "${output_paired}" "--output-paired (required when --sample-id is not provided)"
    require_nonempty "${output_unpaired}" "--output-unpaired (required when --sample-id is not provided)"
    require_nonempty "${flagstat_unaligned_paired}" "--flagstat-unaln-paired (required when --sample-id is not provided)"
    require_nonempty "${flagstat_unaligned_unpaired}" "--flagstat-unaln-unpaired (required when --sample-id is not provided)"
    sample_base="$(basename "${output_paired%.bam}")"
  fi

  # Validate inputs
  require_file "${input_paired}"
  require_file "${input_unpaired}"
  ubam_check_or_die "${input_paired}"   "t2tfilter: input_paired"
  ubam_check_or_die "${input_unpaired}" "t2tfilter: input_unpaired"

  # Threads autodetect
  if [[ -z "${threads}" ]]; then
    if command -v nproc >/dev/null 2>&1; then
      threads="$(nproc)"
    elif [[ "$OSTYPE" == "darwin"* ]] && command -v sysctl >/dev/null 2>&1; then
      threads="$(sysctl -n hw.ncpu)"
    else
      threads="8"
    fi
  fi

  # --- Final outputs ---
  ensure_parent_dir "${output_paired}"
  ensure_parent_dir "${output_unpaired}"

  # --- Intermediates & flagstat TSVs (allow explicit override) ---
  local base_paired base_unpaired
  if [[ -n "${sample_id}" ]]; then
    base_paired="${sample_id}.qcfilt_paired"
    base_unpaired="${sample_id}.qcfilt_unpaired"
  else
    base_paired="${sample_base}.qcfilt_paired"
    base_unpaired="${sample_base}.qcfilt_unpaired"
  fi

  local fastq_r1="${OUTDIR_BAMS}/${base_paired}.R1.fq.gz"
  local fastq_r2="${OUTDIR_BAMS}/${base_paired}.R2.fq.gz"
  local fastq_u="${OUTDIR_BAMS}/${base_unpaired}.U.fq.gz"

  local bam_aligned_paired="${OUTDIR_BAMS}/${base_paired}.t2t_aln.bam"
  local bam_aligned_unpaired="${OUTDIR_BAMS}/${base_unpaired}.t2t_aln.bam"
  local bam_decoys_paired="${OUTDIR_BAMS}/${base_paired}.t2t_decoys.bam"
  local bam_decoys_unpaired="${OUTDIR_BAMS}/${base_unpaired}.t2t_decoys.bam"

  ensure_parent_dir "${flagstat_unaligned_paired}"
  ensure_parent_dir "${flagstat_unaligned_unpaired}"

  # Skip whole step only if --dont-overwrite and final outputs exist
  if [[ ${dont_overwrite} -eq 1 && -f "${output_paired}" && -f "${output_unpaired}" ]]; then
    log "t2tfilter (--dont-overwrite): final outputs exist; skipping."
    return 0
  fi

  log "t2tfilter threads=${threads} sample=${sample_base}"
  log "  decoys_to_mask: ${decoys_to_mask:-<None>}"

  # --- Convert QC-filtered BAMs -> FASTQ (paired) ---
  if [[ ! -f "${fastq_r1}" || ! -f "${fastq_r2}" ]]; then
    log "Converting paired QC-filtered BAM to FASTQ"
    if [[ -n "${PICARD_JAR}" ]]; then
      java -jar "${PICARD_JAR}" SamToFastq \
        --INPUT "${input_paired}" \
        --FASTQ "${fastq_r1}" \
        --SECOND_END_FASTQ "${fastq_r2}" \
        --VALIDATION_STRINGENCY LENIENT
    else
      picard SamToFastq \
        --INPUT "${input_paired}" \
        --FASTQ "${fastq_r1}" \
        --SECOND_END_FASTQ "${fastq_r2}" \
        --VALIDATION_STRINGENCY LENIENT
    fi
  fi

  # --- Convert QC-filtered BAM -> FASTQ (unpaired) ---
  if [[ ! -f "${fastq_u}" ]]; then
    log "Converting unpaired QC-filtered BAM to FASTQ"
    if [[ -n "${PICARD_JAR}" ]]; then
      java -jar "${PICARD_JAR}" SamToFastq \
        --INPUT "${input_unpaired}" \
        --FASTQ "${fastq_u}" \
        -VALIDATION_STRINGENCY SILENT
    else
      picard SamToFastq \
        --INPUT "${input_unpaired}" \
        --FASTQ "${fastq_u}" \
        -VALIDATION_STRINGENCY SILENT
    fi
  fi

  # --- Align paired to T2T ---
  if [[ ! -f "${bam_aligned_paired}" || ${dont_overwrite} -eq 0 ]]; then
    log "Aligning paired reads to T2T"
    bwa mem -t "${threads}" -T 0 "${reference}" "${fastq_r1}" "${fastq_r2}" \
      | samtools view -@ "${threads}" -Shb -o "${bam_aligned_paired}"
    [[ -f "${bam_aligned_paired}" ]] || die "Failed to create aligned paired BAM."
  fi

  # --- Extract unaligned paired -> final output_paired ---
  if [[ ! -f "${output_paired}" || ${dont_overwrite} -eq 0 ]]; then
    log "[ Extracting paired unaligned reads ]"
    time samtools view -@ "${threads}" -bh "${bam_aligned_paired}" -f 3 -e '[AS]>35' \
      -U >(samtools view -@ "${threads}" -bh -F 2048 -x SA -x OQ -x MD -o "${output_paired}") \
      -o /dev/null #(samtools flagstat --output-fmt tsv - > "${flagstat_aligned_paired}")

    if [[ -n "${decoys_to_mask}" ]]; then
      log "[ Extracting paired decoy-overlap reads for merge ]"
      time samtools view -@ "${threads}" -bh "${bam_aligned_paired}" -f 3 -e '[AS]>35' "${L_ARG[@]}" \
        | samtools view -@ "${threads}" -bh -F 2048 -x SA -x OQ -x MD -o "${bam_decoys_paired}"

      if [[ -s "${bam_decoys_paired}" ]]; then
        local tmp_merge_p="${output_paired}.tmp.merge.bam"
        log "[ Merging paired decoy-overlap reads into output ]"
        time samtools cat -o "${tmp_merge_p}" "${output_paired}" "${bam_decoys_paired}"
        mv -f "${tmp_merge_p}" "${output_paired}"
      fi
    fi
  fi

  # --- Align unpaired to T2T ---
  if [[ ! -f "${bam_aligned_unpaired}" || ${dont_overwrite} -eq 0 ]]; then
    log "[ Aligning unpaired reads to T2T ]"
    bwa mem -t "${threads}" -T 0 "${reference}" "${fastq_u}" \
      | samtools view -@ "${threads}" -Shb -o "${bam_aligned_unpaired}"
    [[ -f "${bam_aligned_unpaired}" ]] || die "Failed to create aligned unpaired BAM."
  fi

  # --- Extract unaligned unpaired -> final output_unpaired ---
  if [[ ! -f "${output_unpaired}" || ${dont_overwrite} -eq 0 ]]; then
    log "[ Extracting unpaired unaligned reads ]"
    time samtools view -@ "${threads}" -bh "${bam_aligned_unpaired}" -e '[AS]>35' \
      -U >(samtools view -@ "${threads}" -bh -F 2048 -x SA -x OQ -x MD -o "${output_unpaired}") \
      -o /dev/null #(samtools flagstat --output-fmt tsv - > "${flagstat_aligned_unpaired}")

    if [[ -n "${decoys_to_mask}" ]]; then
      log "[ Extracting unpaired decoy-overlap reads for merge ]"
      time samtools view -@ "${threads}" -bh "${bam_aligned_unpaired}" -e '[AS]>35' "${L_ARG[@]}" \
        | samtools view -@ "${threads}" -bh -F 2048 -x SA -x OQ -x MD -o "${bam_decoys_unpaired}"

      if [[ -s "${bam_decoys_unpaired}" ]]; then
        local tmp_merge_u="${output_unpaired}.tmp.merge.bam"
        log "[ Merging unpaired decoy-overlap reads into output ]"
        time samtools cat -o "${tmp_merge_u}" "${output_unpaired}" "${bam_decoys_unpaired}"
        mv -f "${tmp_merge_u}" "${output_unpaired}"
      fi
    fi
  fi

  sleep 1
  samtools flagstat --output-fmt tsv "${output_paired}" > "${flagstat_unaligned_paired}" || true
  samtools flagstat --output-fmt tsv "${output_unpaired}" > "${flagstat_unaligned_unpaired}" || true

  # --- Post-run integrity checks ---
  bam_check_or_die "${output_paired}"   "t2tfilter: final paired"
  bam_check_or_die "${output_unpaired}" "t2tfilter: final unpaired"

  # --- Cleanup intermediates (unless requested to keep) ---
  if [[ ${keep_intermediate} -eq 0 ]]; then
    log "Removing intermediate FASTQs and aligned BAMs (use --keep-intermediate to retain):"
    for f in \
      "${fastq_r1}" "${fastq_r2}" "${fastq_u}" \
      "${bam_aligned_paired}" "${bam_aligned_unpaired}" \
      "${bam_decoys_paired}" "${bam_decoys_unpaired}"
    do
      [[ -e "$f" ]] && rm -f "$f"
    done
  fi

  log "t2tfilter done → paired(unmapped): ${output_paired} ; unpaired(unmapped): ${output_unpaired}"
}
