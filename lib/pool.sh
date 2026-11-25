# shellcheck shell=bash
# lib/pool.sh - the operation-agnostic worker pool: shard naming and merging, the
# scheduler and its seams, the run lock and the interrupt trap. Shared by the
# reencode paths (2/4/5) and the scan (1). Sourced by flac_health_reencode.sh; the
# POOL_* state and RUN_LOCK_DIR are declared in the entry.

# Directory holding a run's per-worker shards: a 'shards' dir sibling to the run
# log. Never '*.flac' and never under a scanned path, so a stray shard can never
# be mistaken for library content or a reencode temp. $1 = run log path.
shard_dir_for() {
    printf '%s/shards\n' "$(dirname "$1")"
}

# Shard path of one kind for one worker, namespaced by the run log's basename so
# two overlapping runs can never share a shard. $1 = run log, $2 = worker id,
# $3 = 'log', 'db', 'scan' or 'result'.
shard_path_for() {
    local log_file="$1"
    local worker_id="$2"
    local kind="$3"
    local ext

    # Explicit mapping, no fallthrough: a typo'd kind must not alias onto the log
    # shard, which would make several workers append to one file.
    case "$kind" in
        log)    ext="log" ;;
        # NUL-terminated reencode records (see the recording format), merged into the
        # tracking DB by a plain cat.
        db)     ext="db" ;;
        # NUL-separated paths that failed 'flac -t', read back to build the scan
        # report - hence kept distinct from 'log' (human status text) and 'db'
        # (reencode bookkeeping).
        scan)   ext="scan" ;;
        result) ext="result" ;;
        *)
            echo "shard_path_for: unknown shard kind '$kind'" >&2
            return 1
            ;;
    esac

    printf '%s/%s_w%s.%s\n' "$(dirname "$log_file")" \
        "$(basename "$log_file")" "$worker_id" "$ext"
}

# Appends a run's per-worker shards to the real run log and tracking DB, then
# removes them. Runs after every worker has finished, so the merge is
# single-threaded. A DB shard holds exactly the NUL records record_reencoded_to
# wrote, so this is a plain append that preserves a pre-existing DB (run_reencode_pool
# has already migrated any legacy DB to that same form); a failed worker still
# contributes its log shard, and a missing/empty DB shard is fine.
# $1 = run log, $2 = tracking DB, $3 = POOL_WORKERS_USED (high-water worker id;
# ids are per FILE, so this usually exceeds the job count).
merge_reencode_shards() {
    local log_file="$1"
    local db_path="$2"
    local workers="$3"
    local id db_sh log_sh

    for (( id = 0; id < workers; id++ )); do
        db_sh=$(shard_path_for "$log_file" "$id" db)
        log_sh=$(shard_path_for "$log_file" "$id" log)
        if [ -f "$db_sh" ]; then
            if [ -s "$db_sh" ]; then
                mkdir -p "$(dirname "$db_path")"
                cat "$db_sh" >> "$db_path"
            fi
            rm -f "$db_sh"
        fi
        if [ -f "$log_sh" ]; then
            if [ -s "$log_sh" ]; then
                cat "$log_sh" >> "$log_file"
            fi
            rm -f "$log_sh"
        fi
    done
    # Remove the shard directory if this run was its last user.
    rmdir "$(shard_dir_for "$log_file")" 2>/dev/null || true
}

# The shared worker pool behind all four per-file paths (reencodes 2/4/5 and the
# scan 1). Reads NUL-separated paths from the file at $6 and keeps up to $1
# workers busy, calling POOL_WORKER_FN for each file. Operation-agnostic: the
# caller supplies the worker (see _pool_setup_state), so the scan reuses this
# scheduler rather than duplicating the backpressure/pid/shard machinery.
#
# 'wait -n' rather than a wave/barrier pool: a file rescued with
# --decode-through-errors can take an order of magnitude longer than a healthy
# one, and waves would idle the other workers for the rest of every batch.
# Results travel over a pid->worker-id WORKER_EXIT map (guards against pid
# reuse), the per-worker shards and a dispatch-ordered index; the parent tallies
# completions by sweeping pids with 'kill -0', so it never consumes a status it
# could not read.
#
# $1 = worker count (1 = strictly sequential, no children)
# $2 = run log (shard naming derives from it)
# $3 = per-worker result channel (the tracking DB for reencodes)
# $4 = library root, $5 = backup root
# $6 = NUL-separated input list (fully written before the call)
# $7 = output mode: 0 = live bar on a terminal, 1 = sequential statuses only
#      (no terminal), 2 = pooled without a terminal: plain progress lines plus a
#      replay of the per-file statuses in file order
# $8 = label for the bar's counter (e.g. 'Failed')
# Sets POOL_PROCESSED, POOL_SUCCESS, POOL_FAIL, POOL_MODE, POOL_WORKERS_USED.
# Owns the run's progress display: calls progress_begin before the work and
# progress_end (which lands on the final 100%) once every file has been counted,
# so a caller's summary never shares a row with the bar.
run_file_pool() {
    local jobs="$1"
    local log_file="$2"
    local result_channel="$3"
    local library_dir="${4%/}"
    local backup_root="${5%/}"
    local list_path="$6"
    local label="${8:-Failed}"

    POOL_MODE="$7"
    POOL_PROCESSED=0
    POOL_SUCCESS=0
    POOL_FAIL=0
    # High-water mark published before the tally, for callers that read their own
    # shards back (the scan).
    POOL_WORKERS_USED=0
    # Seams defaulting to a reencode; the scan overrides all three and
    # run_reencode_pool resets them (see _pool_reset_seams), because the menu loop
    # reuses this process and a stale scan seam would silently turn a reencode
    # into a verification.
    POOL_WORKER_FN="${POOL_WORKER_FN:-_reencode_pool_worker}"
    POOL_CHANNEL_KIND="${POOL_CHANNEL_KIND:-db}"
    # Empty for a reencode: its channel goes straight into $3 (the real DB) on the
    # sequential path.
    POOL_SEQ_CHANNEL_PREFIX="${POOL_SEQ_CHANNEL_PREFIX:-}"

    # jobs=1: no children and no shards, equivalent to the pre-parallel behavior.
    # The channel is resolved per FILE via _pool_seq_channel, so ids climb exactly
    # as in the dispatch loop and a caller replaying shards by id stays correct.
    if [ "$jobs" -le 1 ]; then
        local flac_file total_files seq_channel quiet=0
        # Mode 1 is a captured sequential run: no bar, and no plain progress lines
        # either (its per-file status lines already describe every step).
        [ "$POOL_MODE" -eq 1 ] && quiet=1
        total_files=$(_count_nul_list "$list_path")
        progress_begin "$total_files" "$label" "$quiet"
        while IFS= read -r -d '' flac_file; do
            seq_channel="$(_pool_seq_channel "$POOL_PROCESSED" "$result_channel" "$log_file")"
            if _pool_call_worker "$flac_file" "$seq_channel" "$log_file" "$library_dir" "$backup_root"; then
                POOL_SUCCESS=$((POOL_SUCCESS + 1))
            else
                POOL_FAIL=$((POOL_FAIL + 1))
            fi
            POOL_PROCESSED=$((POOL_PROCESSED + 1))
            # Advance only when a file COMPLETED, so the bar tracks finished work
            # rather than work that has merely been started.
            progress_update "$POOL_PROCESSED" "$POOL_FAIL"
        done < "$list_path"
        progress_end
        return 0
    fi

    _pool_setup_state "$jobs" "$log_file" "$list_path"
    # Up-front count so the bar starts from a real denominator (the dispatch loop
    # is bounded by the same figure). A pooled run always reports progress: a
    # terminal gets the live bar, anything else gets plain periodic lines.
    progress_begin "$(_count_nul_list "$list_path")" "$label" 0
    _pool_dispatch_loop "$list_path" "$jobs" "$log_file" "$result_channel" \
        "$library_dir" "$backup_root" "$label"
    _pool_drain "$label"

    # Tally any worker result the sweep did not consume BEFORE replaying per-file
    # lines, or the replay would appear ahead of the summary it accompanies.
    _pool_tally_results
    # Every file is now counted, so land the bar on N/N and end its line before
    # anything else is printed.
    progress_end
    if [ "$POOL_MODE" -eq 2 ]; then
        _pool_replay_status_lines
    fi
    # Publish before releasing the per-run state: this is how many shards the run
    # created, and ids are allocated per FILE, not per worker slot. Read by the
    # caller (lib/scan.sh / lib/reencode.sh), not within this module.
    # shellcheck disable=SC2034
    POOL_WORKERS_USED="$POOL_NEXT_ID"
    _pool_cleanup_state
    # The run is over, so restore the default signal behavior before returning to
    # the menu (a Ctrl-C there should end the script, not run the pool sweep).
    _pool_disarm_interrupt_trap
    return 0
}

# Counts the NUL-separated records in a file. $1 = file path.
_count_nul_list() {
    local count=0
    while IFS= read -r -d '' _rec <&4; do
        count=$((count + 1))
    done 4< "$1"
    printf '%s\n' "$count"
}

# Writes one scan report as NDJSON (JSON Lines): a header record, then one 'error'
# record per failing path IN THE GIVEN ORDER. Every record carries "type", so a
# reader can filter without parsing the whole document.
#
#   {"type":"header","generated":"2026-11-24T12:00:00Z","files":1234,"errors":2}
#   {"type":"error","filepath":"/m/Music/Artist/Album/A, B.flac"}
#
# jq is the encoder, so commas, double quotes, backslashes and newlines in a path are
# escaped per RFC 8259 instead of being pasted into a delimiter-based format. The
# input is the NUL-separated failure list, read with 'read -r -d ''', so a path can
# contain any byte but NUL and is never split. Costs one fork per RECORD, i.e. per
# failure, never per file scanned.
# $1 = NUL-separated failure list, $2 = output report path, $3 = files scanned,
# $4 = number of failures.
write_scan_report() {
    local list_path="$1"
    local out_path="$2"
    local files="$3"
    local errors="$4"
    local flac_file

    jq -c -n --arg generated "$(date -u +%FT%TZ)" \
        --argjson files "$files" --argjson errors "$errors" \
        '{type: "header", generated: $generated, files: $files, errors: $errors}' \
        > "$out_path" || return 1

    while IFS= read -r -d '' flac_file; do
        jq -c -n --arg filepath "$flac_file" \
            '{type: "error", filepath: $filepath}' >> "$out_path" || return 1
    done < "$list_path"
    return 0
}

# Prints the newest flac_scan_* report in a reports directory, ".ndjson" or the
# legacy ".csv". Empty when there is none. Prints nothing and succeeds when the
# directory does not exist yet (nothing has been scanned), rather than failing under
# 'set -e' the way a bare find on a missing directory would.
#
# -maxdepth 1: reports sit directly in the reports directory, so a stray
# flac_scan_* file in a SUBdirectory (found by recursing) must never be mistaken for
# the newest report.
#
# Newest BY MODIFICATION TIME, chosen in the shell: a find -printf '%T@ %p' is GNU
# only, and a name sort would pick the wrong report as soon as two runs share a
# second. The NUL list keeps a space-containing report name intact.
# $1 = reports directory.
find_latest_scan_report() {
    local report_dir="$1"
    local report latest=''
    local -a reports=()

    [ -d "$report_dir" ] || return 0
    while IFS= read -r -d '' report; do
        reports+=("$report")
    done < <(find "$report_dir" -maxdepth 1 -type f \
                 \( -iname 'flac_scan_*.ndjson' -o -iname 'flac_scan_*.csv' \) \
                 -print0 2>/dev/null)

    for report in "${reports[@]}"; do
        # 'a -nt b' is false while 'latest' is empty ('' is not a readable file), so
        # the first candidate always becomes the baseline.
        if [ -z "$latest" ] || [ "$report" -nt "$latest" ]; then
            latest="$report"
        fi
    done

    [ -n "$latest" ] || return 0
    printf '%s\n' "$latest"
}

# Splits a LEGACY CSV report line into LEGACY_REPORT_PATH and prints the path.
#
# Prints rather than assigning only, so it is directly unit-testable; callers that
# must avoid a fork per row read the global instead.
# A path is the whole line with exactly ONE leading/trailing quote pair removed:
# 'IFS=, read' truncated "A, B.flac" at the comma, and the blanket '"'-strip that
# replaced it corrupted a filename with a quote in it. A bare "filepath" header, a
# '# Scan Report ...' comment and a blank line all yield themselves, so the caller's
# existing header/comment filters still see them.
# $1 = one line from a legacy report.
parse_legacy_report_row() {
    local line="$1"
    case "$line" in
        '"'*'"') LEGACY_REPORT_PATH="${line#\"}"; LEGACY_REPORT_PATH="${LEGACY_REPORT_PATH%\"}" ;;
        *)       LEGACY_REPORT_PATH="$line" ;;
    esac
    printf '%s\n' "$LEGACY_REPORT_PATH"
}

# Converts a scan report into the NUL-separated path list the reencode pool reads.
# One pass, in report order. KNOWS the two report formats:
#   * NDJSON: 'select(.type == "error")' keeps just the failure records, whatever
#     else the file holds (header, future record types), and jq -j emits the path
#     followed by a real NUL - so a comma, quote, backslash or newline inside the
#     name comes back exactly as it went in.
#   * legacy CSV (reports written by older versions, kept working, never deleted):
#     unwrapped line by line by parse_legacy_report_row. Rows are filtered by the
#     CALLER, so the legacy path keeps the same rules it always had.
# Returns 1 (having written nothing useful) when the report cannot be read.
# $1 = report path, $2 = output NUL list.
scan_report_to_nul_list() {
    local report="$1"
    local out_path="$2"
    local line

    : > "$out_path" || return 1
    case "$report" in
        *.ndjson|*.NDJSON)
            jq -j 'select(.type == "error") | .filepath, "\u0000"' "$report" \
                > "$out_path" || return 1
            ;;
        *)
            while IFS= read -r line || [ -n "$line" ]; do
                parse_legacy_report_row "$line" >/dev/null
                printf '%s\0' "$LEGACY_REPORT_PATH" >> "$out_path"
            done < "$report" || return 1
            ;;
    esac
    return 0
}

# Serialises whole runs (scan, reencode 2/4/5) so two copies started at once cannot
# share a run log, seed list or shard directory, or delete each other's temp files:
# those names are timestamped to the SECOND and the per-file temp is derived from the
# file itself (see temp_path_for_file), so same-second runs would overlap.
#
# The lock is a LOCK DIRECTORY created with 'mkdir' - atomic on every filesystem this
# script supports - holding the owner's pid. A lock FILE plus flock(1) was the obvious
# alternative, but a lock is held for as long as any process keeps the fd open, and a
# script fd holding it is inherited by every child: a worker, or a grandchild a worker
# spawns, would keep the library locked after this process had exited (observed as a
# re-run refusing the lock the moment the previous run finished).
#
# A lock whose owner is gone (killed -9, machine rebooted) is broken automatically:
# the owner's pid file is compared against the live process table. That process also
# exports RUN_LOCK_DIR, so the EXIT trap can remove the lock on a normal exit and on a
# signal handler's exit; a run that dies without a trap leaves a stale lock that the
# next run breaks in one read.
# Returns 0 when the lock is held (RUN_LOCK_DIR set), or 1 with the reason on stdout.
# A no-op returning 0 when 'ps' is unavailable, since liveness can then not be judged.
# $1 = library root.
acquire_run_lock() {
    local library_dir="$1"
    local lock_dir owner_pid=''

    RUN_LOCK_DIR=''
    command -v ps >/dev/null 2>&1 || return 0
    # Key the lock on the RESOLVED library, so two spellings or a symlinked route to
    # the same library ('/mnt/music', '/mnt/music/', '/media/music -> /mnt/music')
    # collide exactly as they should. canonical_dir returns 1 when the directory is
    # unusable, which leaves the lock inside the spelling the caller gave.
    library_dir="$(canonical_dir "$library_dir")" || library_dir="${1%/}"
    lock_dir="${library_dir}/.flac_scan_data/lock"

    mkdir -p "$(dirname "$lock_dir")" 2>/dev/null || return 0

    if mkdir "$lock_dir" 2>/dev/null; then
        printf '%s\n' "$$" > "$lock_dir/pid"
        RUN_LOCK_DIR="$lock_dir"
        return 0
    fi

    # Somebody else's lock. Two runs start together, so the owner may not have written
    # its pid yet: treat an unreadable pid as live, never as stale.
    owner_pid=$(cat "$lock_dir/pid" 2>/dev/null) || owner_pid=''
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
        # A stale lock from a run that died without its trap. Break it ONCE and retry;
        # two runs breaking it at the same time both fail and both report busy, which
        # is safe (a retried manual run succeeds).
        rm -rf "$lock_dir" 2>/dev/null || true
        if mkdir "$lock_dir" 2>/dev/null; then
            printf '%s\n' "$$" > "$lock_dir/pid"
            RUN_LOCK_DIR="$lock_dir"
            return 0
        fi
    fi

    echo "Error: Another copy of this script is already working on '$library_dir'."
    echo "Wait for it to finish (or stop it) and try again - two runs at once would"
    echo "overwrite each other's log, work list and temp files."
    return 1
}

# Removes this process's run lock, if it holds one. Safe to call any number of times:
# the EXIT trap of the menu loop calls it, and a signal handler ends the process with
# an explicit exit that runs it too.
release_run_lock() {
    if [ -n "${RUN_LOCK_DIR:-}" ] && [ -d "$RUN_LOCK_DIR" ]; then
        rm -rf "$RUN_LOCK_DIR" 2>/dev/null || true
        RUN_LOCK_DIR=''
    fi
    return 0
}

# Creates the shard directory and the parent's in-flight state for one pooled run:
# the dispatch index (file order, so the replay is deterministic) and the
# pid -> worker-id map. $1 = worker count, $2 = run log path, $3 = the run's
# NUL-separated work list (kept so the interrupt handler can remove it).
_pool_setup_state() {
    # shellcheck disable=SC2034  # pool-wide state read by _pool_dispatch_loop
    # and _pool_sweep_finished below, like POOL_PIDS.
    POOL_JOBS="$1"
    POOL_LOG_FILE="$2"
    POOL_SHARD_DIR="$(shard_dir_for "$POOL_LOG_FILE")"
    POOL_INDEX="${POOL_SHARD_DIR}/$(basename "$POOL_LOG_FILE").index"
    # Temp manifest for the interrupt handler. Lives in the shard dir, so it is
    # namespaced by the run log like every other shard.
    POOL_TEMP_LIST="${POOL_SHARD_DIR}/$(basename "$POOL_LOG_FILE").temps"
    # shellcheck disable=SC2034  # read by _pool_interrupt_cleanup
    POOL_SEED_LIST="${3:-}"
    POOL_NEXT_ID=0
    POOL_PIDS=()
    mkdir -p "$POOL_SHARD_DIR"
    : > "$POOL_INDEX"
    : > "$POOL_TEMP_LIST"
    declare -gA POOL_WORKER_EXIT=()
    _pool_install_interrupt_trap
    return 0
}

# Arms the INT/TERM/HUP trap for the duration of a pooled run. Each trap passes its
# OWN signal number to the shared handler, so the reported signal and the derived
# 128+signo exit status stay correct (a single shared global would report whichever
# signal was registered last). Installed here rather than at script scope so the
# interactive menu is unaffected and sourced unit tests inherit no handler.
_pool_install_interrupt_trap() {
    trap '_pool_interrupt_cleanup 2' INT
    trap '_pool_interrupt_cleanup 15' TERM
    trap '_pool_interrupt_cleanup 1' HUP
    return 0
}

# Restores the default INT/TERM/HUP behavior once the pooled run has completed.
# Idempotent, so calling it on a path where no trap was armed is harmless.
_pool_disarm_interrupt_trap() {
    trap - INT TERM HUP
    # shellcheck disable=SC2034  # latched for re-entrancy by the armed traps
    POOL_INTERRUPT_ARMED=0
    # shellcheck disable=SC2034  # read by _pool_interrupt_cleanup
    POOL_SEED_LIST=''
    return 0
}

# Resolves the result channel on the SEQUENTIAL (jobs=1) path. A reencode caller
# passes its real DB as $3 and keeps writing straight into it, so a jobs=1 run is
# shard-free. An operation whose channel is inherently per file (the scan's failure
# list) sets POOL_SEQ_CHANNEL_PREFIX instead, giving every file its own shard named
# by id, matching the pooled path.
# $1 = worker id (== dispatch index), $2 = the caller's channel ($3 of the pool),
# $3 = run log path.
_pool_seq_channel() {
    local worker_id="$1"
    local caller_channel="$2"
    local log_file="$3"

    if [ -n "${POOL_SEQ_CHANNEL_PREFIX:-}" ]; then
        printf '%s/%s_w%s.%s\n' "$(dirname "$log_file")" \
            "$POOL_SEQ_CHANNEL_PREFIX" "$worker_id" "$POOL_CHANNEL_KIND"
        return 0
    fi
    printf '%s\n' "$caller_channel"
}

# Restores the pool's operation seams to their reencode defaults: the worker to run
# per file, the kind of result channel it writes, and whether the sequential path
# gives each file its own shard.
#
# These are PROCESS globals and run_file_pool only fills in a default when one is
# UNSET, while the menu loop reuses one process for every operation. run_scan_pool
# sets all three, so without this a scan earlier in the SAME session left the scan
# worker plugged in, and the next reencode (options 2/4/5) only verified each file
# with 'flac -t': every file counted as a success, no backup was written and the
# tracking DB never grew - a silent no-op that looked like a clean run.
# Idempotent, so both a reencode (before its run) and a scan (after its run) can
# call it; call it as a plain command, never inside $(...).
_pool_reset_seams() {
    POOL_WORKER_FN="_reencode_pool_worker"
    POOL_CHANNEL_KIND="db"
    POOL_SEQ_CHANNEL_PREFIX=""
    return 0
}

# Invokes the configured per-file worker: the one place that decides WHICH
# operation runs, so a new pooled operation only adds a worker and points
# POOL_WORKER_FN at it. $1 = file, $2 = result channel, $3 = log shard,
# $4 = library root, $5 = backup root.
_pool_call_worker() {
    "${POOL_WORKER_FN:-_reencode_pool_worker}" "$@"
}

# Per-file body of a reencode run. Returns the per-file status.
_reencode_pool_worker() {
    reencode_one_file "$1" "$2" "$3" "$4" "$5"
}

# Forks one worker for one file. A FAILED fork counts as a file failure rather than
# aborting: one momentary resource shortage must not kill a multi-hour run.
# $1 = worker id, $2 = file, $3 = run log, $4 = library root, $5 = backup root.
_pool_start_worker() {
    local worker_id="$1"
    local flac_file="$2"
    local log_file="$3"
    local library_dir="$4"
    local backup_root="$5"
    local pid

    # Record the temp this file will use BEFORE forking, so the interrupt handler can
    # sweep it even if the signal lands mid-write. Appending to the run's manifest
    # (rather than a blanket find -delete) keeps a running sibling's live temp out of
    # the sweep. A scan worker writes no temp, so its entry is skipped. The name comes
    # from the same helper reencode_one_file uses, so the sweep can never miss a temp.
    if [ "${POOL_CHANNEL_KIND:-db}" = 'db' ] && [ -n "$POOL_TEMP_LIST" ]; then
        local temp_path
        # Missing the manifest entry is not fatal: the worker re-derives the same
        # name and removes its own temp on every failure path.
        if temp_path=$(temp_path_for_file "$flac_file"); then
            printf '%s\n' "$temp_path" >> "$POOL_TEMP_LIST"
        fi
    fi

    (
        # Shards are LOCAL to the child and passed explicitly, so no shared global
        # decides where a worker writes. The channel kind picks the DB shard
        # (reencode) or the failure list (scan) via the same helper.
        local log_shard result_shard rc
        log_shard="$(shard_path_for "$log_file" "$worker_id" log)"
        result_shard="$(shard_path_for "$log_file" "$worker_id" result)"
        local result_channel
        result_channel="$(shard_path_for "$log_file" "$worker_id" "$POOL_CHANNEL_KIND")"
        # Statuses must never reach the screen while the parent owns the bar line.
        # STATUS_TO_CONSOLE is owned by the entry and read by write_status.
        # shellcheck disable=SC2034
        STATUS_TO_CONSOLE=0
        # A child must never draw progress either: it would interleave its own
        # carriage returns with the parent's single-line bar.
        # shellcheck disable=SC2034
        PROGRESS_ACTIVE=0
        # shellcheck disable=SC2034
        PROGRESS_DRAW_LIVE=0
        if _pool_call_worker "$flac_file" "$result_channel" "$log_shard" \
                "$library_dir" "$backup_root"; then
            rc=0
        else
            rc=1
        fi
        # One record per file, so the parent's sum is an exact file count.
        printf 'PROCESSED=1\nFAIL=%s\n' "$rc" > "$result_shard"
        exit "$rc"
    ) &
    pid=$!
    # A failed fork leaves $! empty (or with a pid that cannot be tracked): report it
    # so the caller counts the file as a FAILURE. Without this the id simply never
    # produced a result shard and the file vanished from every tally, which is how a
    # lost file used to look like a clean run.
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        return 1
    fi
    # shellcheck disable=SC2034  # read by _pool_sweep_finished (same script scope)
    POOL_WORKER_EXIT["$pid"]="$worker_id"
    POOL_PIDS+=("$pid")
    return 0
}

# Drops every already-exited pid from the in-flight list and reports how many are
# still running (POOL_RUNNING). 'kill -0' is portable and, unlike 'wait -n',
# never consumes a status this function could not report.
#
# This is also where a run's completions are COUNTED: a pid that has exited maps
# to its worker id, whose result shard is consumed, so the tallies and the
# progress bar advance as each file finishes rather than when the whole pool
# drains.
_pool_sweep_finished() {
    local remaining=() p worker_id
    for p in "${POOL_PIDS[@]}"; do
        if kill -0 "$p" 2>/dev/null; then
            remaining+=("$p")
        else
            worker_id="${POOL_WORKER_EXIT[$p]:-}"
            if [ -n "$worker_id" ]; then
                _pool_consume_result "$worker_id"
            fi
            unset 'POOL_WORKER_EXIT[$p]'
        fi
    done
    # Guarded for bash 4.3, where expanding an EMPTY array under 'set -u' is an
    # error (4.4 fixed that): this assignment runs on every sweep, including the
    # one that empties the pool.
    if [ "${#remaining[@]}" -gt 0 ]; then
        POOL_PIDS=("${remaining[@]}")
    else
        POOL_PIDS=()
    fi
    POOL_RUNNING=${#POOL_PIDS[@]}
    return 0
}

# Consumes one worker's result record and folds it into the run tally. Keyed by
# worker id (not pid) and deleting the record as it reads it, so a sweep that
# sees the same id twice cannot double-count it; a pid-reuse rebind simply finds
# no record and counts nothing.
# $1 = worker id.
_pool_consume_result() {
    local worker_id="$1"
    local result_file key value counted=0

    result_file="$(shard_path_for "$POOL_LOG_FILE" "$worker_id" result)"
    [ -s "$result_file" ] || return 0
    while IFS='=' read -r key value; do
        case "$key" in
            PROCESSED)
                POOL_PROCESSED=$((POOL_PROCESSED + ${value:-0}))
                counted=1
                ;;
            FAIL)
                POOL_FAIL=$((POOL_FAIL + ${value:-0}))
                ;;
        esac
    done < "$result_file"
    rm -f "$result_file"
    if [ "$counted" = '1' ]; then
        POOL_SUCCESS=$((POOL_PROCESSED - POOL_FAIL))
    fi
    return 0
}

# Feeds the list to the pool, keeping POOL_JOBS workers in flight. Every dispatched
# path is appended to the index (so a replay keeps file order), and completions are
# swept (and counted, and drawn) before each start so finished pids do not pile up
# and the bar advances while the pool keeps working.
# $1 = NUL-separated list, $2 = worker count, $3 = run log,
# $4 = result channel, $5 = library root, $6 = backup root, $7 = bar label.
_pool_dispatch_loop() {
    local list_path="$1"
    local jobs="$2"
    local log_file="$3"
    local result_channel="$4"
    local library_dir="$5"
    local backup_root="$6"
    local flac_file total_files

    total_files=$(_count_nul_list "$list_path")

    exec 3< "$list_path"
    while IFS= read -r -d '' flac_file <&3; do
        printf '%s\n' "$flac_file" >> "$POOL_INDEX"

        # Backpressure: block on ANY worker finishing, then sweep (counting and
        # drawing every completion), so a freed slot is refilled immediately
        # instead of after the whole batch.
        while :; do
            _pool_sweep_finished
            progress_update "$POOL_PROCESSED" "$POOL_FAIL"
            [ "$POOL_RUNNING" -lt "$jobs" ] && break
            wait -n "${POOL_PIDS[@]}" 2>/dev/null || true
        done

        if ! _pool_start_worker "$POOL_NEXT_ID" "$flac_file" "$log_file" \
                "$library_dir" "$backup_root"; then
            # A failed fork is a completed (failed) file with no result record.
            POOL_FAIL=$((POOL_FAIL + 1))
            POOL_PROCESSED=$((POOL_PROCESSED + 1))
            POOL_SUCCESS=$((POOL_PROCESSED - POOL_FAIL))
            progress_update "$POOL_PROCESSED" "$POOL_FAIL"
        fi
        POOL_NEXT_ID=$((POOL_NEXT_ID + 1))
    done
    exec 3<&-
    return 0
}

# Waits for the last in-flight workers, sweeping (and counting, and drawing) each
# completion as it lands. The non-blocking first sweep means an already-empty pool
# returns immediately. No final render is needed here: the caller's progress_end
# draws the closing N/N once the tally is complete.
_pool_drain() {
    while :; do
        _pool_sweep_finished
        progress_update "$POOL_PROCESSED" "$POOL_FAIL"
        [ "$POOL_RUNNING" -eq 0 ] && break
        wait -n "${POOL_PIDS[@]}" 2>/dev/null || true
    done
    return 0
}

# Reads any KEY=VALUE records a sweep did not consume (a worker that exited
# between the last sweep and the drain's exit, or a fork-failure rundown) and
# updates POOL_PROCESSED/POOL_SUCCESS/POOL_FAIL. Normally a no-op safety net: the
# per-exit sweep already consumed every record. One record per file, written by
# the worker, so each outcome is counted exactly once; files are removed as they
# are read, making this idempotent.
_pool_tally_results() {
    local shard result_file key value

    # Ids are handed out per FILE, not per worker slot (8 files on 4 workers own
    # shards w0..w7), hence the high-water id rather than the job count.
    for (( shard = 0; shard < POOL_NEXT_ID; shard++ )); do
        result_file="$(shard_path_for "$POOL_LOG_FILE" "$shard" result)"
        [ -s "$result_file" ] || continue
        while IFS='=' read -r key value; do
            case "$key" in
                PROCESSED) POOL_PROCESSED=$((POOL_PROCESSED + ${value:-0})) ;;
                FAIL)      POOL_FAIL=$((POOL_FAIL + ${value:-0})) ;;
            esac
        done < "$result_file"
        rm -f "$result_file"
    done
    # Derived, never tracked separately: every file ends as a success or a failure,
    # which stays consistent even if a worker died before recording.
    POOL_SUCCESS=$((POOL_PROCESSED - POOL_FAIL))
    return 0
}

# On a captured (non-tty) pooled run, prints the per-file SUCCESS/FAILURE lines in
# FILE ORDER at the end: during the run they went only to the workers' log shards,
# so this gives a piped run the same feedback a sequential one has without
# interleaving worker output.
#
# Order comes from the ids themselves: worker ids are allocated in DISPATCH order
# (i.e. file order) and each id owns exactly one log shard, so replaying shard 0..N-1
# and appending each shard's lines once reproduces file order without ever opening
# the dispatch index. That also keeps this O(number of files): the previous version
# nested a grep of every shard per file, which is O(N^2) process launches and
# minutes-to-hours of dead time on a captured run of a real library - and for a
# scan, whose worker writes no log shard at all, it was pure waste.
_pool_replay_status_lines() {
    local id shard_path

    for (( id = 0; id < POOL_NEXT_ID; id++ )); do
        shard_path="$(shard_path_for "$POOL_LOG_FILE" "$id" log)"
        [ -s "$shard_path" ] || continue
        cat "$shard_path"
    done
    return 0
}

# Releases the parent's per-run pool state (index, pid map, counters) so a later run
# in the same invocation cannot see stale entries, and removes the shard directory
# (idempotent; a no-op while another run's shards exist). POOL_NEXT_ID is left alone:
# on the sequential path it is still 0, which tells the caller there are no shards
# to merge.
_pool_cleanup_state() {
    rm -f "$POOL_INDEX" 2>/dev/null || true
    rm -f "$POOL_TEMP_LIST" 2>/dev/null || true
    POOL_PIDS=()
    POOL_RUNNING=0
    rmdir "$POOL_SHARD_DIR" 2>/dev/null || true
    return 0
}

# SIGINT/SIGTERM/SIGHUP handler, armed only while a pooled run is in flight. A
# terminal Ctrl-C signals the whole foreground group, but `kill -TERM`,
# `systemctl stop` or `pkill` signals ONLY this shell - without this handler the
# forked workers survive the parent, holding shards that will never be merged and
# able to rewrite audio after the user believes the run stopped.
#
# Kills each worker and its 'flac' child, then removes this run's temps, shards,
# index, temp manifest and seed list; the run log is kept as the audit trail. It
# deliberately does NOT merge shards into the run log or the tracking DB: the
# normal merge is all-or-nothing, so an interrupted file may already be replaced
# while its DB row is still only in a shard. Option 5 re-reencodes those, which is
# safe because an existing backup is never overwritten.
_pool_interrupt_cleanup() {
    local signo="${1:-0}"
    # Disarm first: a second signal (or a TERM sent to a worker) must not re-enter.
    # shellcheck disable=SC2034  # latched for re-entrancy by the armed traps
    POOL_INTERRUPT_ARMED=1
    trap '' INT TERM HUP

    local p

    # Wipe the live bar first: the message below must start on its own row rather
    # than be appended to a half-drawn progress line.
    progress_clear
    # The PROGRESS_* state is owned by the entry and read by lib/progress.sh.
    # shellcheck disable=SC2034
    PROGRESS_ACTIVE=0
    # shellcheck disable=SC2034
    PROGRESS_DRAW_LIVE=0

    printf '\nInterrupted (signal %s): stopping workers...\n' "$signo" >&2

    # Kill each worker AND its 'flac' grandchild: killing only the worker leaves a
    # 'flac' still writing to the temp, and pkill -P covers the depth. Both calls are
    # best-effort (pkill is procps, not coreutils, and may be absent; a worker may
    # have exited between the sweep and the kill).
    for p in "${POOL_PIDS[@]}"; do
        if command -v pkill >/dev/null 2>&1; then
            pkill -TERM -P "$p" 2>/dev/null || true
        fi
        kill -TERM "$p" 2>/dev/null || true
    done
    wait 2>/dev/null || true

    # Remove the temps this run dispatched. The parent writes the manifest at dispatch
    # time, so it names exactly this run's temps - never a concurrent run's live file
    # (unlike a blanket find -delete over the library).
    if [ -n "${POOL_TEMP_LIST:-}" ] && [ -f "$POOL_TEMP_LIST" ]; then
        while IFS= read -r p; do
            if [ -n "$p" ]; then
                rm -f "$p" 2>/dev/null || true
            fi
        done < "$POOL_TEMP_LIST"
        rm -f "$POOL_TEMP_LIST" 2>/dev/null || true
    fi
    # Remove every OTHER artifact of this run. Shards are named
    # '<log basename>_w<N>.<ext>' beside the run log, so the run log's basename is the
    # namespace: a CONCURRENT run has its own timestamped log basename and is
    # therefore untouched.
    if [ -n "${POOL_LOG_FILE:-}" ]; then
        local log_base log_dir
        log_base="$(basename "$POOL_LOG_FILE")"
        log_dir="$(dirname "$POOL_LOG_FILE")"
        rm -f "${log_dir}/${log_base}"_w* \
              "${log_dir}/${log_base}".index \
              "${log_dir}/${log_base}".temps \
              2>/dev/null || true
    fi
    # This run's NUL-separated work list is transient, so a leftover serves no purpose.
    if [ -n "${POOL_SEED_LIST:-}" ]; then
        rm -f "$POOL_SEED_LIST" 2>/dev/null || true
    fi
    # Every OTHER seed list in the seed directory belongs to an earlier run that was
    # killed (the run lock serialises concurrent ones, so no live run can be using
    # them): those files are transient too, so clear them instead of letting each
    # interrupted run leave one behind.
    if [ -n "${POOL_SEED_LIST:-}" ] && [ -d "$(dirname "$POOL_SEED_LIST")" ]; then
        rm -f "$(dirname "$POOL_SEED_LIST")"/*.paths 2>/dev/null || true
    fi
    # A 'shards' sibling directory holds this run's shards when the run log lives
    # outside the library; remove it if this run created it. rm -rf (not rmdir) so a
    # killed worker's leftovers inside cannot strand it.
    #
    # Guarded: a kill -9 of this process releases the run lock at once, so a re-run
    # can begin while this handler is still running. Deleting the live run's shard
    # dir would destroy its dispatch index and temp manifest, so only a directory
    # that holds nothing but THIS run's shards (prefixed with the log's basename) is
    # removed; files are already gone, so an empty dir is removed too.
    if [ -n "${POOL_SHARD_DIR:-}" ] && [ -d "$POOL_SHARD_DIR" ]; then
        local foreign=''
        if [ -n "${POOL_LOG_FILE:-}" ]; then
            foreign=$(find "$POOL_SHARD_DIR" -mindepth 1 -maxdepth 1 \
                          ! -name "$(basename "$POOL_LOG_FILE")*" -print -quit 2>/dev/null) || foreign=''
        else
            foreign='unknown'
        fi
        if [ -z "$foreign" ]; then
            rm -rf "$POOL_SHARD_DIR" 2>/dev/null || true
        fi
    fi

    exit "$((128 + signo))"
}
