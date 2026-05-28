cmd_classify() {
  local input_paired="" input_unpaired=""
  local classifiers="kraken"           # comma/space-separated: kraken, metaphlan, sylph
  local threads=""
  local sample_id=""
  local dont_overwrite=0
  local keep_intermediate=0
  local PICARD_JAR="${PICARD_JAR:-}"

  # DB/config (env fallbacks)
  local kraken_index="${KRAKEN_INDEX:-}"
  local metaphlan_index="${METAPHLAN_INDEX:-}"      # e.g., mpa_vJun23_CHOCOPhlAnSGB_202403
  local bowtie2_index="${BOWTIE2_INDEX:-}"         # dir containing bowtie2 index files

  # Sylph (explicit only; no env fallback; no -d)
  local -a sylph_indexes=()                        # repeat --sylph-index <file.syldb>
  local -a sylph_taxonomies=()                     # repeat --sylph-taxonomy <NAME>

  # Explicit output overrides
  local k2_out_paired="" k2_rep_paired=""
  local k2_out_unpaired="" k2_rep_unpaired=""
  local mpa_out="" bowtie2out_mpa=""
  local sylph_prof_paired="" sylph_prof_unpaired=""
  local sylph_tax_paired=""  sylph_tax_unpaired=""

  # Extra args passthrough
  local kraken_args=""
  local metaphlan_args=""
  local sylph_args=""
  local java_mem=""

  # 1) OUTDIR defaults up front (user can still override via --outdir)
  : "${OUTDIR:=./pst2t_out}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      # Inputs (explicit; otherwise inferred from --outdir + --sample-id/base)
      --input-paired)            input_paired="${2:-}"; shift 2 ;;
      --input-unpaired)          input_unpaired="${2:-}"; shift 2 ;;

      # Classifier choice
      --classifiers)             classifiers="${2:-}"; shift 2 ;;

      # Outputs (explicit; otherwise inferred)
      --kraken-out-paired)       k2_out_paired="${2:-}"; shift 2 ;;
      --kraken-report-paired)    k2_rep_paired="${2:-}"; shift 2 ;;
      --kraken-out-unpaired)     k2_out_unpaired="${2:-}"; shift 2 ;;
      --kraken-report-unpaired)  k2_rep_unpaired="${2:-}"; shift 2 ;;
      --metaphlan-report)        mpa_out="${2:-}"; shift 2 ;;
      --metaphlan-bowtie2out)    bowtie2out_mpa="${2:-}"; shift 2 ;;
      --sylph-profile-paired)    sylph_prof_paired="${2:-}"; shift 2 ;;
      --sylph-profile-unpaired)  sylph_prof_unpaired="${2:-}"; shift 2 ;;
      --sylph-report-paired)   sylph_tax_paired="${2:-}"; shift 2 ;;
      --sylph-report-unpaired) sylph_tax_unpaired="${2:-}"; shift 2 ;;

      # Indices / args
      --kraken-index)            kraken_index="${2:-}"; shift 2 ;;
      --metaphlan-index)         metaphlan_index="${2:-}"; shift 2 ;;
      --bowtie2-index)           bowtie2_index="${2:-}"; shift 2 ;;
      --kraken-args)             kraken_args="${2:-}"; shift 2 ;;
      --metaphlan-args)          metaphlan_args="${2:-}"; shift 2 ;;

      # Sylph explicit flags (repeatable)
      --sylph-index)             sylph_indexes+=("${2:-}"); shift 2 ;;
      --sylph-taxonomy)          sylph_taxonomies+=("${2:-}"); shift 2 ;;
      --sylph-args)              sylph_args="${2:-}"; shift 2 ;;

      # Resources / behavior
      --threads)                 threads="${2:-}"; shift 2 ;;
      --sample-id)               sample_id="${2:-}"; shift 2 ;;
      --outdir)                  OUTDIR="${2:?--outdir requires a directory path}"; shift 2; _set_outdirs ;;
      --dont-overwrite)          dont_overwrite=1; shift ;;
      --keep-intermediate)       keep_intermediate=1; shift ;;
      --picard-jar)              PICARD_JAR="${2:-}"; shift 2 ;;
      --java-mem)               java_mem="${2:-}"; shift 2 ;;

      -h|--help)
        cat <<'HLP'
Usage: pathseq-t2t classify [ARGS]

Core options:
  [--outdir <dir>]                 Root output directory (default: ./pst2t_out)
  [--sample-id <string>]           Sample ID used for default input/output naming
  [--input-paired <bam>]           T2T-filtered paired BAM (if omitted, inferred when --sample-id is provided)
  [--input-unpaired <bam>]         T2T-filtered unpaired BAM (if omitted, inferred when --sample-id is provided)

Classifier choice:
  [--classifiers "kraken,metaphlan,sylph"]    Comma/space-separated list of classifiers to run (default: kraken)

Outputs (override defaults if desired):
  [--kraken-out-paired <txt>]       Kraken2 paired output (default: <outdir>/classification_stats/<ID>.paired.kraken.output.txt)
  [--kraken-report-paired <txt>]    Kraken2 paired report (default: <outdir>/classification_stats/<ID>.paired.kraken.report.txt)
  [--kraken-out-unpaired <txt>]     Kraken2 unpaired output (default: <outdir>/classification_stats/<ID>.unpaired.kraken.output.txt)
  [--kraken-report-unpaired <txt>]  Kraken2 unpaired report (default: <outdir>/classification_stats/<ID>.unpaired.kraken.report.txt)
  [--metaphlan-report <txt>]        MetaPhlAn report (default: <outdir>/classification_stats/<ID>.metaphlan.report.txt)
  [--metaphlan-bowtie2out <bz2>]    MetaPhlAn bowtie2 out (default: <outdir>/classification_stats/<ID>.metaphlan.bowtie2.bz2)
  [--sylph-profile-paired <path>]   Sylph paired profile artifact (default: <outdir>/classification_stats/<ID>.paired.sylph.profile)
  [--sylph-profile-unpaired <path>] Sylph unpaired profile artifact (default: <outdir>/classification_stats/<ID>.unpaired.sylph.profile)
  [--sylph-report-paired <txt>]   Sylph paired taxonomy table (default: <outdir>/classification_stats/<ID>.paired.taxonomy.txt)
  [--sylph-report-unpaired <txt>] Sylph unpaired taxonomy table (default: <outdir>/classification_stats/<ID>.unpaired.taxonomy.txt)

Databases / indices:
  [--kraken-index <dir>]           Kraken2 DB directory (or $KRAKEN_INDEX)
  [--metaphlan-index <name>]       MetaPhlAn index name (or $METAPHLAN_INDEX)
  [--bowtie2-index <dir>]          Directory containing MetaPhlAn bowtie2 index (or $BOWTIE2_INDEX)

Sylph (explicit; required when selected):
  --sylph-index    <file.syldb>    (repeatable) Exact Sylph DB file(s) to use (e.g., gtdb-r226-c200-dbv1.syldb)
  --sylph-taxonomy <NAME>          (repeatable) One or more of:
                                   FungiRefSeq-latest, FungiRefSeq-2024-07-25,
                                   GTDB_r214, GTDB_r220, GTDB_r226, IMGVR_4.1,
                                   UHGV_default, UHGV_ictv, OceanDNA, SoilSMAG,
                                   TaraEukaryoticSMAG, GlobDB_r226
  --sylph-args "<args>"            Extra args passed to 'sylph profile'

Performance / env:
  [--threads <int>]                CPU threads (default: auto-detect)
  [--kraken-args "<args>"]         Extra args passed to Kraken2
  [--metaphlan-args "<args>"]      Extra args passed to MetaPhlAn
  [--picard-jar </path/picard.jar>]
  [--java-mem <mem>]               Java heap for Picard SamToFastq (e.g., 8g, 16g)
  [--dont-overwrite]               Skip a classifier if all its expected outputs already exist
  [--keep-intermediate]            Keep intermediate FASTQs (default: remove)

Required:
  - If --sample-id is provided, missing input/output paths are filled from defaults.
  - If --sample-id is omitted, provide explicit --input-paired and --input-unpaired.
  - If --sample-id is omitted, classifier outputs must be explicitly provided for selected classifiers.
  - If running Kraken (default): provide --kraken-index or set \$KRAKEN_INDEX.
  - If running MetaPhlAn: provide --metaphlan-index and --bowtie2-index (or corresponding env vars).
  - If running Sylph: provide one or more --sylph-index and --sylph-taxonomy values.


HLP
        return 0 ;;
      --) shift; break ;;
      -*) die "Unknown option for classify: $1" ;;
      *)  die "Unexpected argument to classify: $1" ;;
    esac
  done

  _require_picard


  # ---- Decide which classifiers to run (comma/space separated) ----
  local run_kraken=0 run_metaphlan=0 run_sylph=0
  local c
  log "classifiers=[$classifiers]"
  {
    # Delimiters: comma, space, tab, newline
    local IFS=$', \t\n'
    for c in $classifiers; do
      case "${c,,}" in
        "" ) ;;  # ignore empties
        kraken)    run_kraken=1 ;;
        metaphlan) run_metaphlan=1 ;;
        sylph)     run_sylph=1 ;;
        *) die "Invalid classifier '${c}'. Use 'kraken', 'metaphlan', or 'sylph' (comma/space-separated)." ;;
      esac
    done
  }

  (( run_kraken + run_metaphlan + run_sylph > 0 )) || die "No valid classifiers requested. Use --classifiers 'kraken,metaphlan,sylph'."

  # ---- Conditional tool + index checks
  if (( run_kraken )); then
    _require_kraken2
    if declare -f _require_kraken2_index >/dev/null; then
      _require_kraken2_index "${kraken_index:-}"
    else
      [[ -n "${kraken_index:-}" ]] || die "--kraken-index (or \$KRAKEN_INDEX) is required to run Kraken2."
      [[ -d "${kraken_index}"   ]] || die "Kraken2 index directory not found: ${kraken_index}"
    fi
  fi

  if (( run_metaphlan )); then
    _require_metaphlan4
    if declare -f _require_metaphlan4_index >/dev/null; then
      _require_metaphlan4_index "${metaphlan_index:-}" "${bowtie2_index:-}"
    else
      [[ -n "${metaphlan_index:-}" ]] || die "--metaphlan-index (or \$METAPHLAN_INDEX) is required to run MetaPhlAn."
      [[ -n "${bowtie2_index:-}"  ]] || die "--bowtie2-index (or \$BOWTIE2_INDEX) is required to run MetaPhlAn."
    fi
  fi

  if (( run_sylph )); then
    _require_sylph_090
    _require_sylph_tax

    # Require explicit inputs for Sylph
    (( ${#sylph_indexes[@]} > 0 ))     || die "When using Sylph, provide at least one --sylph-index <file.syldb>."
    (( ${#sylph_taxonomies[@]} > 0 ))  || die "When using Sylph, provide at least one --sylph-taxonomy <NAME>."

    # Warn on unequal counts (still proceed)
    if (( ${#sylph_indexes[@]} != ${#sylph_taxonomies[@]} )); then
      log "WARNING: number of --sylph-index (${#sylph_indexes[@]}) ≠ number of --sylph-taxonomy (${#sylph_taxonomies[@]}).
Proceeding with all provided indexes and taxonomy tags."
    fi
  fi

  local -a kraken_args_ary=() metaphlan_args_ary=() sylph_args_ary=()
  _split_cli_args "${kraken_args}" kraken_args_ary
  _split_cli_args "${metaphlan_args}" metaphlan_args_ary
  _split_cli_args "${sylph_args}" sylph_args_ary

  # Auto threads
  if [[ -z "${threads}" ]]; then
    if command -v nproc >/dev/null 2>&1; then
      threads="$(nproc)"
    elif [[ "$OSTYPE" == "darwin"* ]] && command -v sysctl >/dev/null 2>&1; then
      threads="$(sysctl -n hw.ncpu)"
    else
      threads="8"
    fi
  fi

  # Ensure OUTDIR subfolders
  if declare -F _set_outdirs >/dev/null; then
    _set_outdirs
  else
    OUTDIR_BAMS="${OUTDIR}/bams"
    OUTDIR_CLASSIFY="${OUTDIR}/classification_stats"
    OUTDIR_FILTER="${OUTDIR}/filter_stats"
    OUTDIR_RESULTS="${OUTDIR}/results"
  fi
  mkdir -p "${OUTDIR_RESULTS}" "${OUTDIR_BAMS}" "${OUTDIR_FILTER}" "${OUTDIR_CLASSIFY}"

  # Sample/base naming policy:
  # - with --sample-id: fill missing paths from defaults
  # - without --sample-id: require explicit inputs and selected-classifier outputs
  local sample_base=""
  if [[ -n "${sample_id}" ]]; then
    sample_base="${sample_id}"
    [[ -n "${input_paired}"   ]] || input_paired="${OUTDIR_BAMS}/${sample_base}.t2tfilt_paired.bam"
    [[ -n "${input_unpaired}" ]] || input_unpaired="${OUTDIR_BAMS}/${sample_base}.t2tfilt_unpaired.bam"

    [[ -n "${k2_out_paired}"     ]] || k2_out_paired="${OUTDIR_CLASSIFY}/${sample_base}.paired.kraken.output.txt"
    [[ -n "${k2_rep_paired}"     ]] || k2_rep_paired="${OUTDIR_CLASSIFY}/${sample_base}.paired.kraken.report.txt"
    [[ -n "${k2_out_unpaired}"   ]] || k2_out_unpaired="${OUTDIR_CLASSIFY}/${sample_base}.unpaired.kraken.output.txt"
    [[ -n "${k2_rep_unpaired}"   ]] || k2_rep_unpaired="${OUTDIR_CLASSIFY}/${sample_base}.unpaired.kraken.report.txt"
    [[ -n "${mpa_out}"           ]] || mpa_out="${OUTDIR_CLASSIFY}/${sample_base}.metaphlan.report.txt"
    [[ -n "${bowtie2out_mpa}"    ]] || bowtie2out_mpa="${OUTDIR_CLASSIFY}/${sample_base}.metaphlan.bowtie2.bz2"
    [[ -n "${sylph_prof_paired}" ]] || sylph_prof_paired="${OUTDIR_CLASSIFY}/${sample_base}.paired.sylph.profile.txt"
    [[ -n "${sylph_prof_unpaired}" ]] || sylph_prof_unpaired="${OUTDIR_CLASSIFY}/${sample_base}.unpaired.sylph.profile.txt"
    [[ -n "${sylph_tax_paired}"  ]] || sylph_tax_paired="${OUTDIR_CLASSIFY}/${sample_base}.paired.sylph.report.txt"
    [[ -n "${sylph_tax_unpaired}" ]] || sylph_tax_unpaired="${OUTDIR_CLASSIFY}/${sample_base}.unpaired.sylph.report.txt"
  else
    require_nonempty "${input_paired}" "--input-paired (required when --sample-id is not provided)"
    require_nonempty "${input_unpaired}" "--input-unpaired (required when --sample-id is not provided)"
    sample_base="explicit"

    if (( run_kraken )); then
      require_nonempty "${k2_out_paired}" "--kraken-out-paired (required when running Kraken without --sample-id)"
      require_nonempty "${k2_rep_paired}" "--kraken-report-paired (required when running Kraken without --sample-id)"
      require_nonempty "${k2_out_unpaired}" "--kraken-out-unpaired (required when running Kraken without --sample-id)"
      require_nonempty "${k2_rep_unpaired}" "--kraken-report-unpaired (required when running Kraken without --sample-id)"
    fi
    if (( run_metaphlan )); then
      require_nonempty "${mpa_out}" "--metaphlan-report (required when running MetaPhlAn without --sample-id)"
      require_nonempty "${bowtie2out_mpa}" "--metaphlan-bowtie2out (required when running MetaPhlAn without --sample-id)"
    fi
    if (( run_sylph )); then
      require_nonempty "${sylph_prof_paired}" "--sylph-profile-paired (required when running Sylph without --sample-id)"
      require_nonempty "${sylph_prof_unpaired}" "--sylph-profile-unpaired (required when running Sylph without --sample-id)"
      require_nonempty "${sylph_tax_paired}" "--sylph-report-paired (required when running Sylph without --sample-id)"
      require_nonempty "${sylph_tax_unpaired}" "--sylph-report-unpaired (required when running Sylph without --sample-id)"
    fi
  fi

  # Validate inputs (unaligned BAMs → use -u mode checks)
    # Validate inputs (unaligned BAMs → use -u mode checks)
  require_file "${input_paired}"
  ubam_check_or_die "${input_paired}" "classify: input paired"

  require_file "${input_unpaired}"
  ubam_check_or_die "${input_unpaired}" "classify: input unpaired"
  local have_unpaired=1

  # FASTQ intermediates (paired/unpaired + merged for metaphlan)
  local run_tag
  run_tag="${sample_id:-explicit.$$}"
  local fastq_r1="${OUTDIR_BAMS}/${run_tag}.classify.R1.fq.gz"
  local fastq_r2="${OUTDIR_BAMS}/${run_tag}.classify.R2.fq.gz"
  local fastq_fu="${OUTDIR_BAMS}/${run_tag}.classify.FU.fq.gz"
  local fastq_mrg="${OUTDIR_BAMS}/${run_tag}.metaphlan.merged.fq.gz"

  ensure_parent_dir "${k2_out_paired}";    ensure_parent_dir "${k2_rep_paired}"
  ensure_parent_dir "${k2_out_unpaired}";  ensure_parent_dir "${k2_rep_unpaired}"
  ensure_parent_dir "${mpa_out}";          ensure_parent_dir "${bowtie2out_mpa}"
  ensure_parent_dir "${sylph_prof_paired}"; ensure_parent_dir "${sylph_prof_unpaired}"
  ensure_parent_dir "${sylph_tax_paired}";  ensure_parent_dir "${sylph_tax_unpaired}"

  # Build JVM opts once
  local _JAVA_OPTS=""
  [[ -n "${java_mem}" ]] && _JAVA_OPTS="-Xmx${java_mem}" # -Xms${java_mem} 

  # Convert BAMs -> FASTQ (paired)
  # Convert BAMs -> FASTQ (paired)
  if [[ ! -f "${fastq_r1}" || ! -f "${fastq_r2}" || ${dont_overwrite} -eq 0 ]]; then
    log "Converting unmapped paired BAM to FASTQs"
    if [[ -n "${PICARD_JAR}" ]]; then
      if ! time java ${_JAVA_OPTS} -jar "${PICARD_JAR}" SamToFastq \
        --INPUT "${input_paired}" \
        --FASTQ "${fastq_r1}" \
        --SECOND_END_FASTQ "${fastq_r2}" \
        --VALIDATION_STRINGENCY LENIENT ; then
        log "ERROR: Picard SamToFastq (paired) failed; cleaning up partial FASTQs."
        rm -f "${fastq_r1}" "${fastq_r2}"
        die "Failed to create paired FASTQs from ${input_paired}"
      fi
    else
      if ! env JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-} ${_JAVA_OPTS}" \
        time picard SamToFastq \
        --INPUT "${input_paired}" \
        --FASTQ "${fastq_r1}" \
        --SECOND_END_FASTQ "${fastq_r2}" \
        --VALIDATION_STRINGENCY LENIENT ; then
        log "ERROR: Picard SamToFastq (paired) failed; cleaning up partial FASTQs."
        rm -f "${fastq_r1}" "${fastq_r2}"
        die "Failed to create paired FASTQs from ${input_paired}"
      fi
    fi

    # Defensive: ensure outputs truly exist; otherwise clean and die
    if [[ ! -f "${fastq_r1}" || ! -f "${fastq_r2}" ]]; then
      log "ERROR: Paired FASTQs not found after SamToFastq; cleaning up."
      rm -f "${fastq_r1}" "${fastq_r2}"
      die "Failed to create paired FASTQs."
    fi
  fi


  # Convert BAM -> FASTQ (unpaired) or create empty FASTQ if no unpaired BAM
  # Convert BAM -> FASTQ (unpaired) or create dummy empty FASTQ if no unpaired BAM
  if [[ ${have_unpaired} -eq 0 ]]; then
    log "Creating empty unpaired FASTQ (no unpaired BAM)"
    : | gzip -c > "${fastq_fu}"
  else
    if [[ ! -f "${fastq_fu}" || ${dont_overwrite} -eq 0 ]]; then
      log "Converting unmapped unpaired BAM to FASTQ"
      if [[ -n "${PICARD_JAR}" ]]; then
        if ! time java ${_JAVA_OPTS} -jar "${PICARD_JAR}" SamToFastq \
          --INPUT "${input_unpaired}" \
          --FASTQ "${fastq_fu}" \
          -VALIDATION_STRINGENCY SILENT ; then
          log "ERROR: Picard SamToFastq (unpaired) failed; cleaning up partial FASTQ."
          rm -f "${fastq_fu}"
          die "Failed to create unpaired FASTQ from ${input_unpaired}"
        fi
      else
        if ! env JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-} ${_JAVA_OPTS}" \
          time picard SamToFastq \
          --INPUT "${input_unpaired}" \
          --FASTQ "${fastq_fu}" \
          -VALIDATION_STRINGENCY SILENT ; then
          log "ERROR: Picard SamToFastq (unpaired) failed; cleaning up partial FASTQ."
          rm -f "${fastq_fu}"
          die "Failed to create unpaired FASTQ from ${input_unpaired}"
        fi
      fi

      # Defensive: ensure output truly exists; otherwise clean and die
      if [[ ! -f "${fastq_fu}" ]]; then
        log "ERROR: Unpaired FASTQ not found after SamToFastq; cleaning up."
        rm -f "${fastq_fu}"
        die "Failed to create unpaired FASTQ."
      fi
    fi
  fi



  # ---------- Run Kraken2 ----------
  if [[ ${run_kraken} -eq 1 ]]; then
    log "[ Starting Kraken2 Classification ]"
    if [[ ${dont_overwrite} -eq 1 && -f "${k2_out_paired}" && -f "${k2_rep_paired}" && -f "${k2_out_unpaired}" && -f "${k2_rep_unpaired}" ]]; then
      log "classify (--dont-overwrite): Kraken outputs exist; skipping."
    else
      log "[ Classifying paired reads with Kraken2 ]"
      log_cmd kraken2 "${fastq_r1}" "${fastq_r2}" \
        --paired \
        --report-minimizer-data \
        --db "${kraken_index}" \
        --report "${k2_rep_paired}" \
        --output "${k2_out_paired}" \
        --confidence 0.15 \
        --threads "${threads}" \
        "${kraken_args_ary[@]}"

      log "[ Classifying unpaired reads with Kraken2 ]"
      if [[ -s "${fastq_fu}" ]]; then
        log_cmd kraken2 "${fastq_fu}" \
          --report-minimizer-data \
          --db "${kraken_index}" \
          --report "${k2_rep_unpaired}" \
          --output "${k2_out_unpaired}" \
          --confidence 0.15 \
          --threads "${threads}" \
          "${kraken_args_ary[@]}"
      fi
    fi
  fi

  if [[ ${run_metaphlan} -eq 1 ]]; then
    log "[ Starting MetaPhlAn Classification ]"

    # --- helper: safe decompressed line count (immune to set -e + pipefail) ---
    _gz_lines() {
      local f="$1"
      [[ -f "$f" ]] || { echo 0; return; }
      { zcat -- "$f" 2>/dev/null || true; } | wc -l | awk '{print $1}'
    }

    # Warn per-file if empty (after decompression)
    local lines_r1 lines_r2 lines_fu
    lines_r1="$(_gz_lines "${fastq_r1}")"
    lines_r2="$(_gz_lines "${fastq_r2}")"
    lines_fu="$(_gz_lines "${fastq_fu}")"
    [[ "${lines_r1}" == "0" ]] && log "WARNING: ${fastq_r1} decompresses to 0 lines."
    [[ "${lines_r2}" == "0" ]] && log "WARNING: ${fastq_r2} decompresses to 0 lines."
    [[ "${lines_fu}" == "0" ]] && log "WARNING: ${fastq_fu} decompresses to 0 lines."

    # Build/refresh merged FASTQ unless keeping existing outputs as-is
    if [[ ! -f "${fastq_mrg}" || ${dont_overwrite} -eq 0 ]]; then
      log "[ Merging FASTQs for MetaPhlAn ]"
      {
        zcat -- "${fastq_r1}" 2>/dev/null || true
        zcat -- "${fastq_r2}" 2>/dev/null || true
        zcat -- "${fastq_fu}" 2>/dev/null || true
      } | gzip -c > "${fastq_mrg}"
    fi

    if [[ ${dont_overwrite} -eq 1 && -f "${mpa_out}" && -f "${bowtie2out_mpa}" ]]; then
      log "classify (--dont-overwrite): MetaPhlAn outputs exist; skipping."
    else
      # If merged FASTQ has zero lines, skip MetaPhlAn and write placeholders
      local mrg_lines
      mrg_lines="$(_gz_lines "${fastq_mrg}")"
      if [[ "${mrg_lines}" == "0" ]]; then
        log "MetaPhlAn: merged FASTQ has zero lines; writing placeholder outputs and skipping."
        {
          printf "#sample_id\t%s\n" "${sample_id:-${sample_base:-unknown_sample}}"
          printf "#reads processed: 0\n"
          printf "#estimated_reads_mapped_to_known_clades: 0\n"
        } > "${mpa_out}"
        : > "${bowtie2out_mpa}"
      else
        log "[ Executing MetaPhlAn ]"
        log_cmd metaphlan "${fastq_mrg}" \
          --nproc "${threads}" \
          --read_min_len 60 \
          --input_type fastq \
          --index "${metaphlan_index}" \
          --db_dir "${bowtie2_index}" \
          -t rel_ab_w_read_stats \
          --mapout "${bowtie2out_mpa}" \
          "${metaphlan_args_ary[@]}" \
          > "${mpa_out}"
      fi
    fi
  fi




  # ---------- Run Sylph ----------
  if [[ ${run_sylph} -eq 1 ]]; then
    # Tool checks
    log "[ Starting Sylph Classification ]"
    _require_sylph_090
    _require_sylph_tax
    log "Sylph DBs: ${sylph_indexes[*]} ; Taxonomies: ${sylph_taxonomies[*]}"

    # Require explicit indexes + taxonomy tags
    (( ${#sylph_indexes[@]} > 0 ))    || die "When using Sylph, provide at least one --sylph-index <file.syldb>."
    (( ${#sylph_taxonomies[@]} > 0 )) || die "When using Sylph, provide at least one --sylph-taxonomy <NAME>."

    # Validate index files and warn on unequal counts
    local p
    for p in "${sylph_indexes[@]}"; do
      require_file "$p"
      [[ "${p##*.}" == "syldb" ]] || log "WARNING: Sylph index does not end with .syldb: ${p}"
    done
    if (( ${#sylph_indexes[@]} != ${#sylph_taxonomies[@]} )); then
      log "WARNING: number of --sylph-index (${#sylph_indexes[@]}) ≠ number of --sylph-taxonomy (${#sylph_taxonomies[@]}).
Proceeding with all provided indexes and taxonomy tags."
    fi

    # Skip if outputs exist and --dont-overwrite set
    if [[ ${dont_overwrite} -eq 1 && -f "${sylph_tax_paired}" && ( ! -s "${fastq_fu}" || -f "${sylph_tax_unpaired}" ) ]]; then
      log "classify (--dont-overwrite): Sylph outputs exist; skipping."
    else
      log "[ Classifying paired reads with Sylph ]"
      log_cmd sylph profile \
        "${sylph_indexes[@]}" \
        -1 "${fastq_r1}" \
        -2 "${fastq_r2}" \
        -t "${threads}" \
        --estimate-read-counts \
        --estimate-unknown \
        "${sylph_args_ary[@]}" \
        -o "${sylph_prof_paired}"

      log "[ Generating paired Sylph taxonomy output ]"
      local sylph_tax_prefix="${OUTDIR_CLASSIFY}/taxprof."

      # If the profile has only a header (≤1 line), skip sylph-tax and write a header-only taxonomy file
      if [[ $(wc -l < "${sylph_prof_paired}") -le 1 ]]; then
        log "Sylph profile (paired) contains no taxa."
        # Join taxonomy tags as: ['A', 'B', ...]
        local _tax_joined=""
        if (( ${#sylph_taxonomies[@]} > 0 )); then
          local _t
          for _t in "${sylph_taxonomies[@]}"; do
            [[ -n "${_tax_joined}" ]] && _tax_joined+=", "
            _tax_joined+="'${_t}'"
          done
        fi
        {
          printf "#SampleID\t%s\tTaxonomies_used:[%s]\n" "${fastq_r1}" "${_tax_joined}"
          printf "clade_name\trelative_abundance\tsequence_abundance\tANI (if strain-level)\tCoverage (if strain-level)\n"
        } > "${sylph_tax_paired}"
      else
        # Normal path: generate taxonomy via sylph-tax
        log_cmd sylph-tax taxprof "${sylph_prof_paired}" -t "${sylph_taxonomies[@]}" -o "${sylph_tax_prefix}"
        local produced_p="${OUTDIR_CLASSIFY}/taxprof.$(basename "${fastq_r1}").sylphmpa"
        [[ -f "${produced_p}" ]] || die "Sylph taxonomy (paired) not produced as expected."
        mv -f "${produced_p}" "${sylph_tax_paired}"
      fi

      if [[ -s "${fastq_fu}" ]]; then
        log "[ Classifying unpaired reads with Sylph ]"
        log_cmd sylph profile \
          "${sylph_indexes[@]}" \
          -r "${fastq_fu}" \
          -t "${threads}" \
          --estimate-read-counts \
          --estimate-unknown \
          "${sylph_args_ary[@]}" \
          -o "${sylph_prof_unpaired}"

        log "[ Generating unpaired Sylph taxonomy output ]"

        # If the profile has only a header (≤1 line), skip sylph-tax and write a header-only taxonomy file
        if [[ $(wc -l < "${sylph_prof_unpaired}") -le 1 ]]; then
          log "Sylph profile (unpaired) contains no taxa."
          # Join taxonomy tags as: ['A', 'B', ...]
          local _tax_joined=""
          if (( ${#sylph_taxonomies[@]} > 0 )); then
            local _t
            for _t in "${sylph_taxonomies[@]}"; do
              [[ -n "${_tax_joined}" ]] && _tax_joined+=", "
              _tax_joined+="'${_t}'"
            done
          fi
          {
            printf "#SampleID\t%s\tTaxonomies_used:[%s]\n" "${fastq_fu}" "${_tax_joined}"
            printf "clade_name\trelative_abundance\tsequence_abundance\tANI (if strain-level)\tCoverage (if strain-level)\n"
          } > "${sylph_tax_unpaired}"
        else
          # Normal path: generate taxonomy via sylph-tax
          log_cmd sylph-tax taxprof "${sylph_prof_unpaired}" -t "${sylph_taxonomies[@]}" -o "${sylph_tax_prefix}"
          local produced_u="${OUTDIR_CLASSIFY}/taxprof.$(basename "${fastq_fu}").sylphmpa"
          [[ -f "${produced_u}" ]] || die "Sylph taxonomy (unpaired) not produced as expected."
          mv -f "${produced_u}" "${sylph_tax_unpaired}"
        fi
      fi
    fi
  fi

  # ---------- Cleanup intermediates (default: remove) ----------
  if [[ ${keep_intermediate} -eq 0 ]]; then
    log "Removing intermediate FASTQs (use --keep-intermediate to retain):"
    for f in "${fastq_r1}" "${fastq_r2}" "${fastq_fu}" "${fastq_mrg}" ; do
      [[ -e "$f" ]] && rm -f "$f"
    done
  fi

  {
    local msg="classify done (classifiers=${classifiers})"
    if [[ ${run_kraken} -eq 1 ]]; then
      msg+=" → kraken2 reports: ${k2_rep_paired}, ${k2_rep_unpaired}"
    fi
    if [[ ${run_metaphlan} -eq 1 ]]; then
      msg+=" → metaphlan report: ${mpa_out}"
    fi
    if [[ ${run_sylph} -eq 1 ]]; then
      msg+=" → sylph taxonomy: ${sylph_tax_paired}"
      [[ -s "${fastq_fu}" ]] && msg+=", ${sylph_tax_unpaired}"
    fi
    log "${msg}"
  }
}
