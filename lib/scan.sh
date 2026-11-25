# shellcheck shell=bash
# lib/scan.sh - option 1: the pooled verifier, the NDJSON report writer and its
# readers (current format and the legacy CSV), the pool-mode policy it shares with
# the reencode paths, run_reencode_pool, and scan_library. Sourced by
# flac_health_reencode.sh.

# One mode policy for every operation, so options 1/2/4/5 behave identically:
#   mode 0 - a terminal: the live single-line bar. Pooled children keep status
#            text off the screen (it goes to their log shards), and a sequential
#            run reprints the bar under each status line instead.
#   mode 1 - no terminal, jobs<=1: sequential; no bar (progress lines would only
#            add noise to an already per-file log).
#   mode 2 - no terminal, jobs>1: periodic plain "Progress:" lines while the pool
#            runs, then the per-file status lines replayed in FILE ORDER.
# Echoes the mode; $1 = worker count.
select_pool_mode() {
    local jobs="$1"
    if stdout_is_tty; then
        printf '0\n'
    elif [ "$jobs" -le 1 ]; then
        printf '1\n'
    else
        printf '2\n'
    fi
}

# Runs the reencode pool for one fully-materialised seed list and folds the
# workers' shards back into the run log and tracking DB. Shared by options 2/4/5
# so the progress rendering, per-file status routing and shard merge cannot drift
# between them. Sets POOL_PROCESSED/POOL_SUCCESS/POOL_FAIL (and POOL_WORKERS_USED,
# already consumed by the merge).
# $1 = worker count, $2 = run log, $3 = tracking DB, $4 = library root,
# $5 = backup root, $6 = NUL-separated seed list.
run_reencode_pool() {
    local jobs="$1"
    local log_file="$2"
    local db_path="$3"
    local library_dir="$4"
    local backup_root="$5"
    local seed_list="$6"
    local pool_mode

    pool_mode=$(select_pool_mode "$jobs")
    # Establish this run's operation explicitly: with 'set -u' a reset is also what
    # lets run_file_pool talk about the seams at all. A scan earlier in the session
    # would otherwise leave the scan worker in place and this run would only verify
    # each file (no backup, no DB row) while reporting every one a success.
    _pool_reset_seams
    # Bring a legacy newline-delimited tracking DB onto the NUL record format BEFORE
    # any worker appends to it: the merge below is a plain cat, so a mixed DB would be
    # born here. Idempotent, and a no-op on a fresh install.
    if ! migrate_reencoded_db "$db_path"; then
        echo "WARNING: could not convert the tracking database to its current format:" >&2
        echo "         $db_path (kept as is; the run continues)" >&2
    fi

    # Pooled workers must never echo status text over the live bar; a sequential
    # run keeps statuses on the console and lets write_status reprint the bar.
    # STATUS_TO_CONSOLE is owned by the entry and read by write_status.
    # shellcheck disable=SC2034
    if [ "$pool_mode" -eq 0 ] && [ "$jobs" -gt 1 ]; then
        STATUS_TO_CONSOLE=0
    fi
    run_file_pool "$jobs" "$log_file" "$db_path" "$library_dir" "$backup_root" \
        "$seed_list" "$pool_mode" "failed"
    # Restore statuses for the caller's own summary output; STATUS_TO_CONSOLE is
    # owned by the entry and read by write_status.
    # shellcheck disable=SC2034
    STATUS_TO_CONSOLE=1

    merge_reencode_shards "$log_file" "$db_path" "$POOL_WORKERS_USED"
    return 0
}

# Per-file body of a pooled scan: verify one file with 'flac -t'. A failing
# file's PATH (not status text) goes to this worker's own 'scan' shard in dispatch
# order, so the parent rebuilds the report in file order; one writer per file, so no
# locking is needed. $1 = file, $2 = scan shard, $3 = log shard (unused),
# $4/$5 = library/backup root (unused, kept for signature symmetry).
_scan_pool_worker() {
    local flac_file="$1"
    local scan_shard="$2"

    if flac -t "$flac_file" &>/dev/null; then
        return 0
    fi
    # The ONLY record the worker makes: the machine-readable path list the parent
    # replays. It skips the log shard deliberately, because a line there would print a
    # second copy of what the parent already emits in file order.
    #
    # NUL-terminated, not newline-terminated: a path may contain any byte but NUL, so
    # a filename with a newline in it would otherwise split into two records here -
    # before any report was written.
    printf '%s\0' "$flac_file" >> "$scan_shard"
    return 1
}

# Verifies a NUL-separated list with 'flac -t', up to 'jobs' at a time, reusing
# run_file_pool with the scan worker plugged into its seam.
# Output contract (the same either way): failing paths are reported after the run
# in FILE ORDER, and POOL_PROCESSED/POOL_ERRORS are left for the caller's summary.
# A file whose worker could not even be forked is reported separately
# (POOL_UNTESTED) rather than counted as clean or corrupt.
# $1 = worker count, $2 = NUL-separated list, $3 = run log (names the shard dir),
# $4 = library root.
# Sets POOL_PROCESSED, POOL_ERRORS, POOL_UNTESTED, and SCAN_FAILURES_FILE: a
# NUL-separated list of the failing paths in file order (the caller owns and removes
# that temp file). There is deliberately no joined-in-a-variable form of that list: a
# path list in a shell variable is newline- or NUL-lossy.
run_scan_pool() {
    local jobs="$1"
    local list_path="$2"
    local log_file="$3"
    local library_dir="${4%/}"
    local mode

    # A scan has no per-file status text of its own to hide: it prints its errors
    # from the shards, in order, after the run. The same mode policy as the reencode
    # paths: a terminal gets the live bar (0); a captured sequential run emits no
    # bar (1); a captured pooled run gets periodic plain progress lines and the
    # replayed per-file lines (2).
    if stdout_is_tty; then
        mode=0
    elif [ "$jobs" -le 1 ]; then
        mode=1
    else
        mode=2
    fi

    # The pool seams are read by run_file_pool in lib/pool.sh, not in this module.
    # shellcheck disable=SC2034
    POOL_WORKER_FN="_scan_pool_worker"
    # shellcheck disable=SC2034
    POOL_CHANNEL_KIND="scan"
    # A PER-FILE failure list, so even the sequential path needs one shard per
    # file (named from the run-log basename, like the pooled path).
    # shellcheck disable=SC2034
    POOL_SEQ_CHANNEL_PREFIX="$(basename "$log_file")"
    # Collected into a temp file, not a variable, because a path may contain any
    # byte but NUL and a newline-containing path would look like two entries.
    SCAN_FAILURES_FILE="$(mktemp "${TMPDIR:-/tmp}/flac_scan_fail.XXXXXX")"
    run_file_pool "$jobs" "$log_file" "" "$library_dir" "" \
        "$list_path" "$mode" "Errors"
    # Leave the process on the documented (reencode) seams: these are globals that
    # outlive the call, and the next operation in this same menu session must not
    # inherit the scan worker. Also releases them for 'set -u' readers below.
    _pool_reset_seams

    # Collect the failure lists: ids match dispatch order, so replaying them in
    # ascending order reproduces sequential report order. run_file_pool stops at
    # POOL_WORKERS_USED on the pooled path and at the processed count on the
    # sequential one (POOL_WORKERS_USED is 0 there), so unify the two bounds.
    local bound="$POOL_WORKERS_USED"
    [ "$bound" -gt 0 ] || bound="$POOL_PROCESSED"

    # Concatenating NUL records is order-preserving and cannot glue two paths
    # together, so this stays a plain cat even though the shards hold NULs.
    local id shard
    for (( id = 0; id < bound; id++ )); do
        shard="$(shard_path_for "$log_file" "$id" scan)"
        if [ -s "$shard" ]; then
            cat "$shard"
            rm -f "$shard"
        fi
    done > "$SCAN_FAILURES_FILE"

    POOL_ERRORS=0
    if [ -s "$SCAN_FAILURES_FILE" ]; then
        POOL_ERRORS=$(_count_nul_list "$SCAN_FAILURES_FILE")
    fi
    # A failed fork is a pool failure with no path behind it; surface it so the
    # summary never implies those files were verified.
    POOL_UNTESTED=$((POOL_FAIL - POOL_ERRORS))
    [ "$POOL_UNTESTED" -lt 0 ] && POOL_UNTESTED=0

    # Report the errors in file order. The caller has already cleared its bar.
    # The list is NUL-separated, so a filename with a newline is printed as ONE line
    # carrying that newline, never as two bogus entries.
    if [ "$POOL_ERRORS" -gt 0 ]; then
        local err_path
        while IFS= read -r -d '' err_path; do
            if stdout_is_tty; then
                printf '%b%s\n' "${RED}Error detected in:${NC} " "$err_path"
            else
                echo "Error detected in: $err_path"
            fi
        done < "$SCAN_FAILURES_FILE"
    fi
    return 0
}

# Prompts for a library directory, then scans it recursively with 'flac -t',
# skipping the script's own internal paths (FLAC_INTERNAL_PATH_GLOBS). Failing
# files are recorded as an NDJSON report under the library's .flac_scan_data (see
# write_scan_report), which is what option 2 reads back.
scan_library() {
    config=$(load_config)
    library_path=$(echo "$config" | jq -r '.library_path')

    if [ -z "$library_path" ] || [ "$library_path" == "null" ]; then
        read -rp "Enter the full path to your music library directory: " library_path
        save_config "$library_path"
    fi

    library_dir="$library_path"

    # Validate the directory.
    if [ ! -d "$library_dir" ]; then
        echo "Error: The directory '$library_dir' does not exist."
        read -rp "Press Enter to return to main menu..."
        return 0
    fi

    # Create scan data directory structure
    scan_data_dir="${library_dir}/.flac_scan_data"
    mkdir -p "${scan_data_dir}/reports" "${scan_data_dir}/logs"

    # One run per library at a time (see acquire_run_lock). A scan writes a log and a
    # report, so overlapping it with another run in the same second would overwrite
    # the other run's files.
    if ! acquire_run_lock "$library_dir"; then
        read -rp "Press Enter to return to main menu..."
        return 0
    fi

    # Same timestamp for both, so a run's report and summary log pair up. The report
    # is the machine-readable manifest for option 2 and exists only when errors do;
    # the summary log is written on EVERY scan so each run leaves an audit record.
    timestamp=$(date +%F_%H-%M-%S)
    report_output="${scan_data_dir}/reports/flac_scan_${timestamp}.ndjson"
    scan_log="${scan_data_dir}/logs/scan_log_${timestamp}.txt"

    echo "Scanning FLAC files in: $library_dir"
    echo "Counting FLAC files..."

    # Materialise the list ONCE, NUL-separated, for both the count and the pool:
    # walking the tree twice (count, then scan) doubled the metadata cost and let
    # the two walks disagree, so the progress denominator could differ from the
    # number of files actually tested.
    scan_list_file="$(mktemp "${TMPDIR:-/tmp}/flac_scan_list.XXXXXX")"
    find_real_flac_files "$library_dir" -print0 > "$scan_list_file"
    total_files=$(_count_nul_list "$scan_list_file")
    echo "Found $total_files FLAC files to scan"

    error_count=0
    start_time=$(date +%s)

    # jobs=1 is strictly sequential (no children); jobs>1 runs the pool, whose
    # worker ids match dispatch order, so the errors it reports afterwards come out
    # in the same file order either way.
    jobs="$(get_jobs)"
    if [ "$jobs" -gt 1 ]; then
        echo ""
        echo "Scanning with $jobs worker(s)..."
        echo ""
    fi
    # The progress display (live bar, or plain lines when captured) is owned by the
    # pool: it starts on the 0% state and ends on the final N/N line, so the error
    # list and summary below start on a clean row.
    run_scan_pool "$jobs" "$scan_list_file" "$scan_log" "$library_dir"
    processed_count="$POOL_PROCESSED"

    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Build the report from the pool's NUL-separated failure list, in the same order
    # the sequential loop used, so option 2 consumes either run identically. Only
    # written when failures exist, so a clean scan leaves no manifest behind.
    if [ "$POOL_ERRORS" -gt 0 ]; then
        if ! write_scan_report "$SCAN_FAILURES_FILE" "$report_output" \
                "$total_files" "$POOL_ERRORS"; then
            echo "WARNING: Could not write the scan report to '$report_output'."
            rm -f "$report_output"
            report_output=''
        fi
        error_count="$POOL_ERRORS"
    fi

    rm -f "$scan_list_file" "$SCAN_FAILURES_FILE"

    # The report only exists when errors were found (and could be written); with no
    # report option 2 has nothing to act on, which is what the summary says.
    if [ "$error_count" -gt 0 ] && [ -n "$report_output" ]; then
        if stdout_is_tty; then
            printf '%b\n' "${GREEN}Scan complete.${NC}"
            printf "Scanned ${YELLOW}%d${NC} files in ${YELLOW}%d${NC} seconds\n" "$processed_count" "$duration"
            printf "Found ${RED}%d${NC} errors\n" "$error_count"
            printf "Report generated: ${YELLOW}%s${NC}\n" "$report_output"
        else
            echo "Scan complete."
            echo "Scanned $processed_count files in $duration seconds"
            echo "Found $error_count errors"
            echo "Report generated: $report_output"
        fi
        report_line="$report_output"
    else
        rm -f "$report_output"
        if stdout_is_tty; then
            printf '%b\n' "${GREEN}Scan complete.${NC}"
            printf "Scanned ${YELLOW}%d${NC} files in ${YELLOW}%d${NC} seconds\n" "$processed_count" "$duration"
            printf '%b\n' "${GREEN}No errors found.${NC}"
        else
            echo "Scan complete."
            echo "Scanned $processed_count files in $duration seconds"
            echo "No errors found."
        fi
        report_line="(none - no errors found)"
    fi

    # Files a worker could not even be started for were neither verified nor
    # reported, so say so explicitly instead of leaving them out of every count
    # (POOL_UNTESTED was computed upstream but never shown before).
    if [ "${POOL_UNTESTED:-0}" -gt 0 ]; then
        echo "WARNING: $POOL_UNTESTED file(s) could not be tested (worker could not start); they are NOT included in the counts above."
        echo "Check free memory / process limits and re-run the scan."
    fi

    # Every scan, clean or not, leaves a human-readable audit trail alongside the
    # reports/logs the reencode flows use.
    {
        echo "# Scan Summary: $(date -u +%FT%TZ)"
        echo "Library: $library_dir"
        echo "Files scanned: $processed_count"
        echo "Errors found: $error_count"
        echo "Duration: ${duration}s"
        echo "Report: $report_line"
    } > "$scan_log"

    echo "Scan summary saved to: $scan_log"
    release_run_lock
    read -rp "Press Enter to return to main menu..."
}
