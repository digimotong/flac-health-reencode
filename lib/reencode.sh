# shellcheck shell=bash
# lib/reencode.sh - the reencode side: the per-file reencode (backup, encode,
# replace, record), options 2/4/5, and the library/backup/worker configuration menu.
# Sourced by flac_health_reencode.sh.

# Core single-file reencode: back the original up into the mirrored backup tree,
# run flac with --verify --compression-level-0 --decode-through-errors
# --preserve-modtime, then replace the original with the reencoded temp on
# success. Status lines go to $3 and to the console per STATUS_TO_CONSOLE.
# Parallel-safe: both write targets are PARAMETERS, and the pool hands each
# worker its own log/DB shard, so no two workers append to one file.
# $1 = FLAC file, $2 = tracking file (DB, or this worker's DB shard),
# $3 = log file (run log, or this worker's log shard),
# $4 = library root, $5 = backup root. 0 on success, 1 on failure.
reencode_one_file() {
    local flac_file="$1"
    local db_path="$2"
    local log_file="$3"
    local library_dir="${4%/}"
    local backup_root="${5%/}"

    local temp_file backup_target

    # The temp sits beside the original so the final 'mv' stays on one filesystem.
    # See temp_path_for_file for the naming (and the long-basename fallback).
    if ! temp_file=$(temp_path_for_file "$flac_file"); then
        write_status "FAILURE: Could not derive a temp file name for $flac_file" "$log_file"
        return 1
    fi

    # flac (without -f) refuses to write an existing output, so clear any
    # leftover temp from an interrupted run. The name is the script's own. A
    # failure here is only a diagnostic: flac refuses the existing output anyway,
    # and a name it cannot unlink must not abort the run with a raw 'rm' error.
    rm -f "$temp_file" 2>/dev/null || true

    # A file outside the library root (possible for a row in a hand-edited or
    # older scan report) has nowhere to be backed up, so it is refused rather than
    # re-encoded unprotected.
    backup_target="$(get_backup_target "$library_dir" "$backup_root" "$flac_file")"
    if [ -z "$backup_target" ]; then
        write_status "WARNING: $flac_file is not under the library ($library_dir); cannot back it up. Skipping reencode." "$log_file"
        return 1
    fi

    # Reencode the file using the specified FLAC parameters.
    #
    # flac >= 1.5 refuses a FLAC->FLAC re-encode when the input's STREAMINFO MD5
    # disagrees with the audio it decodes to ("MD5sum of input is different from
    # MD5sum of output"). That is exactly the damaged-input case
    # --decode-through-errors exists for, so on those files the new check would
    # turn every repair into a failure. Upstream disables the comparison whenever a
    # non-zero --until is given, so: encode normally first (keeping the check, and
    # its corruption warning, for healthy files) and retry ONCE with
    # --until=<total samples>, which is the whole file and encodes the same range.
    local total_samples=''
    if ! flac --verify --compression-level-0 --decode-through-errors --preserve-modtime --silent -o "$temp_file" "$flac_file"; then
        total_samples=$(metaflac --show-total-samples "$flac_file" 2>/dev/null || true)
        rm -f "$temp_file"
        if ! [[ "$total_samples" =~ ^[0-9]+$ ]] || [ "$total_samples" -eq 0 ] \
            || ! flac --verify --compression-level-0 --decode-through-errors --preserve-modtime --silent \
                    --until="$total_samples" -o "$temp_file" "$flac_file"; then
            write_status "FAILURE: Reencoding failed for $flac_file" "$log_file"
            [ -f "$temp_file" ] && rm "$temp_file"
            return 1
        fi
        # Log-only (not console): the retry is a cost worth explaining in the audit
        # trail, but it is not an error and would otherwise scroll past unnoticed.
        echo "Note: damaged input; re-encoded with --until=$total_samples after flac refused the plain re-encode (MD5 check): $flac_file" >> "$log_file"
    fi

    # mkdir -p builds the whole relative chain, so a fresh backup root needs no
    # pre-created skeleton.
    if ! mkdir -p "$(dirname "$backup_target")"; then
        write_status "WARNING: Failed to create backup directory for $flac_file. Skipping reencode for this file." "$log_file"
        rm -f "$temp_file"
        return 1
    fi

    if [ -e "$backup_target" ]; then
        # A backup already exists (e.g. a re-run over the same report, or a file
        # that is already a reencoded version). Keep the EXISTING backup so the
        # pristine original is never overwritten; the reencode still proceeds.
        echo "Backup already exists (keeping original): $backup_target" >> "$log_file"
    elif ! cp -p "$flac_file" "$backup_target"; then
        # -p keeps timestamps/permissions, so the backup is a faithful snapshot.
        write_status "WARNING: Failed to backup $flac_file. Skipping reencode for this file." "$log_file"
        rm -f "$temp_file"
        return 1
    else
        echo "Backup created for: $flac_file -> $backup_target" >> "$log_file"
    fi

    # The temp was created by flac with the umask's permissions and this process's
    # owner, and --preserve-modtime only restores the timestamp, so 'mv' would
    # otherwise hand the library a file with different mode/owner than the original
    # (a strict umask can drop a media server's read access). The BACKUP is faithful
    # (cp -p); make the replacement faithful too, before it takes the original's
    # place. Best-effort: a chown the user is not allowed to make is normal (the file
    # is already theirs) and must not fail the reencode, but a chmod failure is worth
    # a log line because the file then differs from its neighbours.
    if ! chmod --reference="$flac_file" "$temp_file" 2>/dev/null; then
        echo "WARNING: could not copy the original permissions onto the reencoded file: $flac_file" >> "$log_file"
    fi
    chown --reference="$flac_file" "$temp_file" 2>/dev/null || true

    # Replace the original file with the reencoded version.
    if ! mv "$temp_file" "$flac_file"; then
        write_status "FAILURE: Could not overwrite $flac_file with the reencoded file." "$log_file"
        rm -f "$temp_file"
        return 1
    fi

    write_status "SUCCESS: $flac_file reencoded successfully." "$log_file"
    if ! record_reencoded_to "$db_path" "$flac_file"; then
        # Reencode succeeded but recording failed (should be extremely rare).
        write_status "WARNING: Reencode succeeded but could not record '$flac_file' in the tracking database." "$log_file"
    fi
    return 0
}

# Reads the newest scan report from the library, confirms with the user, then
# re-encodes each file it lists. Accepts the NDJSON reports scan_library writes and
# the legacy CSV reports older versions wrote (any user's old reports are left in
# place). Filters out the 'filepath' header, '#' comments, and any path in the
# script's own internal area (older/exported reports may contain them).
# The backup root is resolved once (resolve_backup_path) and each file is
# mirrored into it, originals never living inside the library.
reencode_library() {
    config=$(load_config)
    library_path=$(echo "$config" | jq -r '.library_path')

    if [ -z "$library_path" ] || [ "$library_path" == "null" ]; then
        read -rp "Enter the directory containing your FLAC scan reports (typically your music library): " library_path
        save_config "$library_path"
    fi

    library_dir="$library_path"

    if [ ! -d "$library_dir" ]; then
        echo "Error: The directory '$library_dir' does not exist."
        read -rp "Press Enter to return to main menu..."
        return 0
    fi

    # Locate the newest report (.ndjson, or a legacy .csv) by modification time.
    scan_data_dir="${library_dir}/.flac_scan_data/reports"
    latest_report=$(find_latest_scan_report "$scan_data_dir")

    if [ -z "$latest_report" ]; then
        echo "No scan report found in '$library_dir'. Please run a scan first."
        release_run_lock
        read -rp "Press Enter to return to main menu..."
        return 0
    fi

    echo "Latest scan report found: $latest_report"
    read -rp "Type 'Y' to confirm using this report for reencoding: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "User did not confirm. Aborting reencoding process."
        release_run_lock
        read -rp "Press Enter to return to main menu..."
        return 0
    fi

    # Resolve, then create/validate, the backup root before touching any file: a
    # failure here (unsafe location, unwritable export) aborts rather than
    # re-encoding anything unprotected. The split exists only so callers that
    # merely DISPLAY a path create nothing; here the user already confirmed.
    backup_root=""
    if ! backup_root=$(resolve_backup_path "$library_dir"); then
        read -rp "Press Enter to return to main menu..."
        return 0
    fi
    if ! ensure_backup_root "$backup_root"; then
        read -rp "Press Enter to return to main menu..."
        return 0
    fi

    # One run per library at a time (see acquire_run_lock): the log, work list and
    # shard names are second-resolution, so a second concurrent run would overwrite
    # this run's files.
    if ! acquire_run_lock "$library_dir"; then
        read -rp "Press Enter to return to main menu..."
        return 0
    fi

    # Create scan data directory if needed
    scan_data_dir="${library_dir}/.flac_scan_data"
    mkdir -p "${scan_data_dir}/logs"

    # Tracking database for successfully reencoded files.
    db_path=$(get_reencoded_db_path "$library_dir")

    # Worker count for this run (see get_jobs and the header's pool notes).
    jobs="$(get_jobs)"

    # Run log for the reencoding process.
    log_file="${scan_data_dir}/logs/reencode_log_$(date +%F_%H-%M-%S).txt"
    {
        echo "Reencoding started at $(date)"
        echo "Library: $library_dir"
        echo "Backups: $backup_root"
        echo "Report: $latest_report"
        echo "Workers: $jobs"
        echo ""
    } > "$log_file"

    # Discovery pass: turn the report into a NUL-separated path list (one pass, see
    # scan_report_to_nul_list), then build the filtered, DEDUPLICATED work list from
    # it, keeping the report's own order. A hand-edited or merged report can repeat a
    # path, and two workers must never race the same file, so duplicates are reported
    # and dropped.
    local filter_log="${log_file}.filter.log"
    local flac_file
    seed_dir="${scan_data_dir}/seed"
    # '$$' as well as the log basename: a second run in the same second would
    # otherwise truncate this run's work list (the run lock prevents that too, but a
    # unique name keeps the file safe on its own).
    seed_list="${seed_dir}/$(basename "$log_file").$$.paths"
    mkdir -p "$seed_dir"
    : > "$seed_list"

    # The report's raw rows, NUL-separated, before the filters below. Kept in a file
    # (never a variable or $(...)) so a path with any byte but NUL survives intact.
    report_rows="$(mktemp "${TMPDIR:-/tmp}/flac_report_rows.XXXXXX")"
    if ! scan_report_to_nul_list "$latest_report" "$report_rows"; then
        echo "Error: Could not read the scan report '$latest_report'."
        echo "Error: Could not read the scan report '$latest_report'." >> "$log_file"
        rm -f "$report_rows" "$filter_log" "$seed_list"
        rmdir "$seed_dir" 2>/dev/null || true
        release_run_lock
        read -rp "Press Enter to return to main menu..."
        return 0
    fi

    total_files=0
    success_count=0
    fail_count=0
    duplicate_count=0
    declare -A SEEN_LIST=()
    while IFS= read -r -d '' flac_file; do
        # Skip the legacy report's header row and scan_library's '# Scan Report: ...'
        # row (an NDJSON report has neither, but a legacy CSV does).
        if [[ "$flac_file" == "filepath" ]] || [[ "$flac_file" == \#* ]]; then
            continue
        fi

        # Never re-encode rows pointing into the script's internal area.
        if is_internal_flac_path "$flac_file"; then
            printf '%s\n' "Skipping internal/backup path: $flac_file" >> "$filter_log"
            continue
        fi

        # A path outside the library has no home in the mirrored backup tree, so
        # skip it loudly rather than re-encoding it unprotected.
        if ! get_backup_target "$library_dir" "$backup_root" "$flac_file" >/dev/null; then
            printf '%s\n' "Skipping path outside the library: $flac_file" >> "$filter_log"
            continue
        fi

        if [[ -n "${SEEN_LIST[$flac_file]+x}" ]]; then
            duplicate_count=$((duplicate_count + 1))
            continue
        fi
        SEEN_LIST["$flac_file"]=1

        total_files=$((total_files + 1))
        printf '%s\0' "$flac_file" >> "$seed_list"
    done < "$report_rows"

    unset SEEN_LIST
    rm -f "$report_rows"
    [ -s "$filter_log" ] && cat "$filter_log"
    rm -f "$filter_log"
    if [ "$duplicate_count" -gt 0 ]; then
        echo "Ignored $duplicate_count duplicate row(s) in the report."
        printf '%s\n' "Ignored $duplicate_count duplicate row(s) in the report." >> "$log_file"
    fi

    if [ "$total_files" -eq 0 ]; then
        echo "No files to process - nothing to do."
        echo "No files to process - nothing to do." >> "$log_file"
        rm -f "$seed_list"
        rmdir "$seed_dir" 2>/dev/null || true
        release_run_lock
        read -rp "Press Enter to return to main menu..."
        return 0
    fi

    # The work list is fully materialised before the pool starts, so a worker's
    # temp file can never be picked up mid-run.
    echo ""
    echo "Processing $total_files file(s) with $jobs worker(s)..."
    echo ""
    # Progress display, status routing and the shard merge are shared with options
    # 4/5 (see run_reencode_pool), so all long-running options render identically.
    run_reencode_pool "$jobs" "$log_file" "$db_path" "$library_dir" "$backup_root" \
        "$seed_list"
    success_count=$POOL_SUCCESS
    fail_count=$POOL_FAIL

    # Discard the work list (the shards were already folded back by the helper).
    rm -f "$seed_list"
    rmdir "$seed_dir" 2>/dev/null || true

    echo "Reencoding complete at $(date)" | tee -a "$log_file"
    # The pool's own count, as options 4/5 report - not the seed count, which would
    # hide any file the pool never actually processed.
    echo "Total files processed: $POOL_PROCESSED" | tee -a "$log_file"
    echo "Successful reencodes: $success_count" | tee -a "$log_file"
    echo "Failed reencodes: $fail_count" | tee -a "$log_file"
    echo "Backups stored in: $backup_root" | tee -a "$log_file"
    echo "Detailed log saved as: $log_file"
    release_run_lock
    read -rp "Press Enter to return to main menu..."
}

# Re-encodes EVERY real FLAC file in the library, after a prominent warning and
# an explicit confirmation. Each original is mirrored into the backup directory
# first. Internal paths are excluded from both the count and the processed set.
reencode_all_files() {
    config=$(load_config)
    library_path=$(echo "$config" | jq -r '.library_path')

    if [ -z "$library_path" ] || [ "$library_path" == "null" ]; then
        read -rp "Enter the full path to your music library directory: " library_path
        save_config "$library_path"
    fi

    library_dir="$library_path"

    if [ ! -d "$library_dir" ]; then
        echo "Error: The directory '$library_dir' does not exist."
        read -rp "Press Enter to return to main menu..."
        return 0
    fi

    # find_real_flac_files skips the internal paths, consistent with
    # reencode_new_files.
    echo "Counting FLAC files..."
    total_files=$(find_real_flac_files "$library_dir" | wc -l)

    if [ "$total_files" -eq 0 ]; then
        echo "No FLAC files found in '$library_dir'."
        read -rp "Press Enter to return to main menu..."
        return
    fi

    # Resolve only, so the warning can name the concrete destination and a
    # cancelled warning leaves no stray directory; the mkdir happens after the
    # confirmation. '--no-prompt' because a question here would come before the
    # warning that justifies it, and would swallow the 'REENCODE ALL' answer.
    backup_root=""
    if ! backup_root=$(resolve_backup_path "$library_dir" --no-prompt); then
        read -rp "Press Enter to return to main menu..."
        return
    fi
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!                              WARNING                                   !!"
    echo "!!                                                                        !!"
    echo "!!  You are about to reencode ALL $total_files FLAC files in:          !!"
    echo "!!  $library_dir"
    echo "!!                                                                        !!"
    echo "!!  This will:                                                            !!"
    echo "!!    - Reencode every FLAC file (not just corrupted ones)                !!"
    echo "!!    - Mirror each original into:                                        !!"
    echo "!!      $backup_root"
    echo "!!    - Replace each original with the reencoded version                  !!"
    echo "!!                                                                        !!"
    echo "!!  This process can take a VERY LONG TIME for large libraries.           !!"
    echo "!!  Make sure you have enough disk space for backups.                     !!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
    read -rp "Type 'REENCODE ALL' to confirm: " confirm
    if [ "$confirm" != "REENCODE ALL" ]; then
        echo "Reencode cancelled."
        release_run_lock
        read -rp "Press Enter to return to main menu..."
        return
    fi

    # The user has committed: create and write-probe the destination, still before
    # any file is touched, so an unwritable export aborts before audio is rewritten.
    if ! ensure_backup_root "$backup_root"; then
        read -rp "Press Enter to return to main menu..."
        return
    fi

    # One run per library at a time (see acquire_run_lock): the log, work list and
    # shard names are second-resolution, so a second concurrent run would overwrite
    # this run's files.
    if ! acquire_run_lock "$library_dir"; then
        read -rp "Press Enter to return to main menu..."
        return 0
    fi

    # Create scan data directory and log file
    scan_data_dir="${library_dir}/.flac_scan_data"
    mkdir -p "${scan_data_dir}/logs"

    # Tracking database for successfully reencoded files.
    db_path=$(get_reencoded_db_path "$library_dir")

    # Worker count for this run (see get_jobs / the Parallel Reencodes notes).
    jobs="$(get_jobs)"

    log_file="${scan_data_dir}/logs/reencode_all_log_$(date +%F_%H-%M-%S).txt"
    {
        echo "Full library reencode started at $(date)"
        echo "Library: $library_dir"
        echo "Backups: $backup_root"
        echo "Total files to process: $total_files"
        echo "Workers: $jobs"
        echo ""
    } > "$log_file"

    echo ""
    echo "Starting reencode of all $total_files FLAC files..."
    echo ""

    start_time=$(date +%s)

    # Materialise the work list FIRST: find_real_flac_files excludes the script's
    # own paths, but not a temp file written into a library directory during the
    # run, and a live "find | pool" pipe could hand such a temp to a worker.
    seed_dir="${scan_data_dir}/seed"
    # '$$' as well as the log basename: a second run in the same second would
    # otherwise truncate this run's work list (the run lock prevents that too, but a
    # unique name keeps the file safe on its own).
    seed_list="${seed_dir}/$(basename "$log_file").$$.paths"
    mkdir -p "$seed_dir"
    find_real_flac_files "$library_dir" -print0 > "$seed_list"

    echo "Processing $total_files file(s) with $jobs worker(s)..."
    # Same progress display, status routing and shard merge as options 2/5.
    run_reencode_pool "$jobs" "$log_file" "$db_path" "$library_dir" "$backup_root" \
        "$seed_list"
    processed_count=$POOL_PROCESSED
    success_count=$POOL_SUCCESS
    fail_count=$POOL_FAIL

    # Discard the work list (the shards were already folded back by the helper).
    rm -f "$seed_list"
    rmdir "$seed_dir" 2>/dev/null || true

    end_time=$(date +%s)
    duration=$((end_time - start_time))

    echo ""
    echo "Reencode complete at $(date)" | tee -a "$log_file"
    echo "Total files processed: $processed_count" | tee -a "$log_file"
    echo "Successful reencodes: $success_count" | tee -a "$log_file"
    echo "Failed reencodes: $fail_count" | tee -a "$log_file"
    echo "Backups stored in: $backup_root" | tee -a "$log_file"
    echo "Duration: ${duration} seconds" | tee -a "$log_file"
    echo "Detailed log saved as: $log_file"
    release_run_lock
    read -rp "Press Enter to return to main menu..."
}

# Re-encodes only the files absent from the tracking DB, so newly added or
# re-downloaded albums (detected by MD5+size) are processed and everything else
# is skipped. Each original is mirrored into the backup directory first.
reencode_new_files() {
    config=$(load_config)
    library_path=$(echo "$config" | jq -r '.library_path')

    if [ -z "$library_path" ] || [ "$library_path" == "null" ]; then
        read -rp "Enter the full path to your music library directory: " library_path
        save_config "$library_path"
    fi

    library_dir="$library_path"

    if [ ! -d "$library_dir" ]; then
        echo "Error: The directory '$library_dir' does not exist."
        read -rp "Press Enter to return to main menu..."
        return 0
    fi

    # The backup directory is deliberately NOT resolved here: resolve_backup_path
    # may PROMPT, which would interrupt the flow and swallow a line of stdin meant
    # for the confirmation below. It runs after the confirmation instead, still
    # before any file is touched.

    # Create scan data directory and determine tracking DB path.
    scan_data_dir="${library_dir}/.flac_scan_data"
    mkdir -p "${scan_data_dir}/logs"

    # One run per library at a time (see acquire_run_lock): the log, work list and
    # shard names are second-resolution, so a second concurrent run would overwrite
    # this run's files.
    if ! acquire_run_lock "$library_dir"; then
        read -rp "Press Enter to return to main menu..."
        return 0
    fi

    db_path=$(get_reencoded_db_path "$library_dir")
    # Must be a plain command, not $(), so the global REENCODED_SET is populated
    # in THIS shell rather than a discarded subshell.
    load_reencoded_set "$db_path"
    db_entries=${#REENCODED_SET[@]}

    # Worker count for this run (see get_jobs and the header's pool notes).
    jobs="$(get_jobs)"

    # find_real_flac_files skips the internal paths, keeping incremental reencodes
    # accurate.
    echo "Counting FLAC files..."
    total_files=$(find_real_flac_files "$library_dir" | wc -l)

    if [ "$total_files" -eq 0 ]; then
        echo "No FLAC files found in '$library_dir'."
        read -rp "Press Enter to return to main menu..."
        return
    fi

    # Discovery pass: gather files absent from the tracking DB. Fingerprinting every
    # file takes a while on a large library (three child processes per file), so a
    # counter is printed every 1000 files - on stderr to a terminal only, so a piped
    # run's captured output is unchanged.
    echo "Checking which FLAC files have never been reencoded ($db_entries entry/entries in '$db_path')..."
    new_files=()
    skipped_count=0
    checked_count=0
    while IFS= read -r -d '' flac_file; do
        checked_count=$((checked_count + 1))
        if stdout_is_tty && [ $((checked_count % 1000)) -eq 0 ]; then
            printf '\r  checked %d of %d file(s)...\033[K' "$checked_count" "$total_files" >&2
        fi
        # Guard on the exit status, not on a non-empty string: an unreadable or
        # corrupt fingerprint makes get_file_fingerprint return 1, and the file is
        # then treated as new below.
        if fp=$(get_file_fingerprint "$flac_file"); then
            read -r md5 size _mtime _rest <<< "$fp"
            key="${md5}|${size}"
            if [[ -n "${REENCODED_SET[$key]+x}" ]]; then
                skipped_count=$((skipped_count + 1))
                continue
            fi
        fi
        # No fingerprint, or an unknown MD5+size: treat as new.
        new_files+=("$flac_file")
    done < <(find_real_flac_files "$library_dir" -print0)

    new_count=${#new_files[@]}
    # End the counter line, so what follows starts on a clean row.
    if stdout_is_tty && [ "$checked_count" -ge 1000 ]; then
        printf '\r\033[K' >&2
    fi

    if [ "$new_count" -eq 0 ]; then
        echo ""
        if stdout_is_tty; then
            printf '%b\n' "${GREEN}All $total_files FLAC files have already been reencoded.${NC}"
        else
            echo "All $total_files FLAC files have already been reencoded."
        fi
        echo "Nothing to do. If you added new music, run this option again after adding files."
        release_run_lock
        read -rp "Press Enter to return to main menu..."
        return
    fi

    # Preview + confirmation (destructive-op style, consistent with the script).
    echo ""
    if stdout_is_tty; then
        echo "Found ${YELLOW}${new_count}${NC} new FLAC file(s) out of $total_files total that have never been reencoded."
    else
        echo "Found $new_count new FLAC file(s) out of $total_files total that have never been reencoded."
    fi
    echo "Each will be reencoded with --verify and its original mirrored into the backup directory."
    read -rp "Reencode these ${new_count} file(s)? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Reencode cancelled."
        read -rp "Press Enter to return to main menu..."
        return
    fi

    # Like reencode_all_files: resolve, then create/validate, now that the user
    # committed. Still before any file is touched, so an unsafe or unwritable
    # destination aborts rather than after audio has been rewritten.
    backup_root=""
    if ! backup_root=$(resolve_backup_path "$library_dir"); then
        read -rp "Press Enter to return to main menu..."
        return
    fi
    echo "Backups will be written to: $backup_root"

    if ! ensure_backup_root "$backup_root"; then
        read -rp "Press Enter to return to main menu..."
        return
    fi

    # Create log file.
    log_file="${scan_data_dir}/logs/reencode_new_log_$(date +%F_%H-%M-%S).txt"
    {
        echo "New-file reencode started at $(date)"
        echo "Library: $library_dir"
        echo "Backups: $backup_root"
        echo "Total FLAC files found: $total_files"
        echo "Already reencoded (skipped): $skipped_count"
        echo "New files to process: $new_count"
        echo "Workers: $jobs"
        echo ""
    } > "$log_file"

    echo ""
    echo "Starting reencode of $new_count new FLAC files..."
    echo ""

    start_time=$(date +%s)

    # The list was classified in the discovery pass above, so a temp file a worker
    # creates can never be picked up as "new" mid-run. Serialise it NUL-separated.
    seed_dir="${scan_data_dir}/seed"
    # '$$' as well as the log basename: a second run in the same second would
    # otherwise truncate this run's work list (the run lock prevents that too, but a
    # unique name keeps the file safe on its own).
    seed_list="${seed_dir}/$(basename "$log_file").$$.paths"
    mkdir -p "$seed_dir"
    : > "$seed_list"
    for flac_file in "${new_files[@]}"; do
        printf '%s\0' "$flac_file" >> "$seed_list"
    done

    echo "Processing $new_count file(s) with $jobs worker(s)..."
    # Same progress display, status routing and shard merge as options 2/4.
    run_reencode_pool "$jobs" "$log_file" "$db_path" "$library_dir" "$backup_root" \
        "$seed_list"
    processed_count=$POOL_PROCESSED
    success_count=$POOL_SUCCESS
    fail_count=$POOL_FAIL

    # Discard the work list (the shards were already folded back by the helper).
    rm -f "$seed_list"
    rmdir "$seed_dir" 2>/dev/null || true

    end_time=$(date +%s)
    duration=$((end_time - start_time))

    echo ""
    echo "Reencode complete at $(date)" | tee -a "$log_file"
    echo "Total FLAC files in library: $total_files" | tee -a "$log_file"
    echo "Already reencoded (skipped): $skipped_count" | tee -a "$log_file"
    echo "New files found: $new_count" | tee -a "$log_file"
    echo "New files processed: $processed_count" | tee -a "$log_file"
    echo "Successful reencodes: $success_count" | tee -a "$log_file"
    echo "Failed reencodes: $fail_count" | tee -a "$log_file"
    echo "Backups stored in: $backup_root" | tee -a "$log_file"
    echo "Duration: ${duration} seconds" | tee -a "$log_file"
    echo "Detailed log saved as: $log_file"
    release_run_lock
    read -rp "Press Enter to return to main menu..."
}

# Sets or updates the library path and the backup directory. A blank answer keeps
# the current value, so the two can be edited independently (save_config leaves
# an omitted key alone). The backup candidate is validated here, at the keyboard,
# rather than at the start of a long re-encode run.
set_paths() {
    config=$(load_config)
    current_path=$(echo "$config" | jq -r '.library_path')
    current_backup=$(echo "$config" | jq -r '.backup_path // empty')

    if [ -z "$current_path" ] || [ "$current_path" == "null" ]; then
        echo "No library path is currently configured."
    else
        echo "Current library path: $current_path"
    fi
    if [ -n "$current_backup" ]; then
        echo "Current backup directory: $current_backup"
    else
        echo "No backup directory is currently configured (will be derived as '<library>_backup')."
    fi
    echo "Current reencode workers: $(get_jobs) (0 uses the default)"

    read -rp "Enter new library path (leave blank to keep current): " new_path
    if [ -z "$new_path" ]; then
        new_path="$current_path"
        if [ -n "$current_path" ] && [ "$current_path" != "null" ]; then
            echo "Library path remains unchanged."
        fi
    fi

    read -rp "Enter new backup directory (leave blank to keep current): " new_backup
    if [ -z "$new_backup" ]; then
        # Blank keeps the current value; when nothing was configured either, offer
        # the derived sibling that would actually be used.
        if [ -z "$current_backup" ] && [ -n "$new_path" ] && [ "$new_path" != "null" ]; then
            new_backup="$(derive_backup_path "${new_path%/}")"
            echo "Using derived backup directory: $new_backup"
        else
            new_backup="$current_backup"
        fi
    fi
    new_backup="$(printf '%s' "$new_backup" | sed 's:/$::')"

    # Blank (or 0) clears the key so get_jobs() re-derives it. A non-numeric
    # answer is refused rather than written: a junk value in the config would be
    # silently ignored at run time and the user would never learn that.
    read -rp "Enter reencode workers (leave blank or 0 for default): " new_jobs
    new_jobs="${new_jobs// /}"
    case "$new_jobs" in
        ''|0) new_jobs='default' ;;
        *[!0-9]*)
            echo "Error: '$new_jobs' is not a positive number of workers."
            # 'return 0', never 1: under 'set -o errexit' a 1 here propagates out of
            # main_menu and ENDS the script, right after telling the user to press
            # Enter to go back to the menu. Options 2/4/5 all return 0 on their
            # error paths for the same reason.
            read -rp "Press Enter to return to main menu..."
            return 0
            ;;
    esac

    if [ -z "$new_path" ] || [ "$new_path" == "null" ]; then
        echo "Error: A library path is required."
        read -rp "Press Enter to return to main menu..."
        return 0
    fi

    # The library may be entered for the first time here, so check it exists to
    # give the user an actionable error message.
    if [ ! -d "$new_path" ]; then
        echo "Error: The directory '$new_path' does not exist."
        read -rp "Press Enter to return to main menu..."
        return 0
    fi

    if [ -n "$new_backup" ] && ! validate_backup_root "$new_path" "$new_backup"; then
        echo "Backup directory not changed."
        read -rp "Press Enter to return to main menu..."
        return 0
    fi

    save_config "$new_path" "$new_backup" "$new_jobs"
    echo "Library path updated to: $new_path"
    if [ -n "$new_backup" ]; then
        echo "Backup directory updated to: $new_backup"
    else
        echo "Backup directory will be derived on the next re-encode: $(derive_backup_path "${new_path%/}")"
    fi
    if [ -n "$new_jobs" ] && [ "$new_jobs" != 'default' ]; then
        echo "Reencode workers updated to: $new_jobs"
    else
        echo "Reencode workers reset to the default ($(get_jobs))."
    fi
    read -rp "Press Enter to return to main menu..."
}
