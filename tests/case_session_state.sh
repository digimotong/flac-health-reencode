#!/usr/bin/env bash
# case_session_state.sh - integration: one menu session, several operations.
#
# The menu loop reuses ONE script process, and the pool's operation seams
# (POOL_WORKER_FN / POOL_CHANNEL_KIND / POOL_SEQ_CHANNEL_PREFIX) are process
# globals. run_scan_pool sets all three and run_file_pool only defaults an UNSET
# seam, so before the fix a scan followed by a reencode in the SAME session left
# the scan worker plugged in: every file was merely re-verified with 'flac -t',
# counted as a successful reencode, and no backup or tracking-DB row was written.
# That is exactly what a real option-1-then-option-5 session does.
#
# Each fixture is a corrupt file (so a scan produces a report for option 2) plus a
# healthy one, then the operations are chained through ONE run. The assertions are
# the reencode contract, not the scan's: a stale seam satisfies every "success"
# count in the summary while breaking all of these.
#
#   A. '1' then '5'    (sequential, jobs=1 - both jobs' SEQUENTIAL paths, where the
#                      stale seam makes the scan's worker run instead of the reencode)
#   B. '1' then '5'    (pooled, jobs=4 - the reported failure)
#   C. '1' then '2'    (reencode the problems the scan just found)
#   D. '1' then '4'    (reencode ALL)

set -o errexit
set -o nounset
set -o pipefail

: "${TESTS_ROOT:?}"
: "${PROD_SCRIPT:?}"
. "$TESTS_ROOT/helpers.sh"

# set_jobs <sbx> <n> : rewrite the sandbox config with a worker count, as
# case_progress.sh does (make_sandbox pins jobs=1 for the sequential anchors).
set_jobs() {
    printf '{"library_path": "%s", "backup_path": "%s", "version": "1.1", "jobs": %s}\n' \
        "$1/lib" "$1/lib_backup" "$2" > "$1/flac_health_config.json"
}

# newest_reencode_log <library> : the most recent reencode_*_log_*.txt, or ''.
# Compared as a "newest file" rather than "the only file" because a session that
# runs several reencodes writes one log per operation.
newest_reencode_log() {
    find "$1/.flac_scan_data/logs" -type f -name 'reencode*_log_*.txt' -print 2>/dev/null \
        | sort | tail -n1
}

# assert_reencoded <sbx> <expected-tally-line> : the shared contract of this case.
# Every file was replaced by the stub's marker, every ORIGINAL was mirrored outside
# the library at its album-relative path, the DB gained a row per file, and the
# newest reencode log carries the per-file trail reencode_one_file writes (a scan
# worker writes none of it). Together these cannot be satisfied by a verification.
# $1 = sandbox root, $2 = this operation's expected tally line,
# $3 = how many files this operation was supposed to re-encode.
assert_reencoded() {
    local sbx="$1"
    local tally="$2"
    local want="${3:-2}"
    local lib="$sbx/lib"
    local log

    occur_re "$tally"

    file_eq "$lib/Album/broken.flac" "$RE_MARKER" \
        || _fail "$sbx: broken.flac was not re-encoded"
    if [ "$want" -eq 2 ]; then
        file_eq "$lib/Album/good.flac" "$RE_MARKER" \
            || _fail "$sbx: good.flac was not re-encoded"
    fi

    # The pristine originals, mirrored OUTSIDE the library.
    file_eq "$sbx/lib_backup/Album/broken.flac" 'bad-payload:CORRUPT' \
        || _fail "$sbx: no mirrored backup of broken.flac"
    if [ "$want" -eq 2 ]; then
        file_eq "$sbx/lib_backup/Album/good.flac" 'clean-audio' \
            || _fail "$sbx: no mirrored backup of good.flac (the stale-seam symptom)"
    fi

    [ -f "$lib/.flac_scan_data/reencoded.db" ] \
        || _fail "$sbx: the tracking DB was never written"
    [ "$(grep -cv '^#' "$lib/.flac_scan_data/reencoded.db")" -eq "$want" ] \
        || _fail "$sbx: tracking DB should hold exactly $want row(s)"
    db_has_path "$sbx" "$lib/Album/broken.flac"
    if [ "$want" -eq 2 ]; then
        db_has_path "$sbx" "$lib/Album/good.flac"
    fi

    log="$(newest_reencode_log "$lib")"
    [ -n "$log" ] || _fail "$sbx: no reencode run log was written"
    [ "$(grep -c 'Backup created for:' "$log")" -eq "$want" ] \
        || _fail "$sbx: reencode log has no backup trail (a verify-only run)"
    [ "$(grep -c 'SUCCESS: .* reencoded successfully' "$log")" -eq "$want" ] \
        || _fail "$sbx: reencode log has no success trail"
}

# count_find <dir> [find args...] : number of matches, 0 when the dir is absent.
#   A missing directory means the run cleaned up MORE than expected - a pass - and
#   under errexit + pipefail a bare `find <missing dir>` would exit 1 and end the case.
count_find() {
    local dir="$1"; shift
    [ -d "$dir" ] || { echo 0; return 0; }
    find "$dir" "$@" 2>/dev/null | wc -l
}

# make_session_sandbox <var> <jobs> : sandbox with one corrupt and one healthy
# album file, configured with <jobs> workers. Registers it for cleanup.
#
# The sandbox root is created into a local named `_sbx` (NOT `sbx`): make_sandbox
# assigns through the name it is given, so a `local sbx` would shadow it.
make_session_sandbox() {
    local var="$1" jobs="$2" _sbx
    make_sandbox _sbx
    register_sandbox "$_sbx"
    mkdir -p "$_sbx/lib/Album"
    # CORRUPT makes the stub's `flac -t` fail, so the scan files a report for it.
    write_file "$_sbx/lib/Album/broken.flac" 'bad-payload:CORRUPT'
    write_file "$_sbx/lib/Album/good.flac" 'clean-audio'   # distinct fingerprint
    set_jobs "$_sbx" "$jobs"
    printf -v "$var" '%s' "$_sbx"
}

# ===========================================================================
# A. Scan, then reencode NEW (sequential path), in ONE session.
# ===========================================================================
SBX1=''
make_session_sandbox SBX1 1

# '1' scan + Enter, '5' + confirm, then leave the menu.
run_script "$SBX1" '1' '' '5' 'y' '' 'q'
occur_re 'Scan complete\.'
occur_re 'Found 1 errors'
# The exact symptom: with the scan worker still plugged in, the corrupt file fails
# its verify and the healthy one is "re-encoded" without any backup or DB row.
absent_re 'Failed reencodes: 1'
assert_reencoded "$SBX1" 'Successful reencodes: 2'
# The scan's own bookkeeping is untouched by the fix: its report still exists.
[ -n "$(find "$SBX1/lib/.flac_scan_data/reports" -type f -name 'flac_scan_*.ndjson' -print -quit)" ] \
    || _fail "A: the scan should still have produced a report"

echo "ok: session_state (scan then option 5, sequential)"

# ===========================================================================
# B. Scan, then reencode NEW (pooled - the reported failure), in ONE session.
# ===========================================================================
SBX2=''
make_session_sandbox SBX2 4

run_script_env "$SBX2" "STUB_FLAC_SLEEP=0.02" "STUB_FLAC_TEST_SLEEP=0.02" -- \
    '1' '' '5' 'y' '' 'q'
occur_re 'Scanning with 4 worker\(s\)'
occur_re 'Found 1 errors'
assert_reencoded "$SBX2" 'Successful reencodes: 2'
# A stale 'scan' seam also wrote the pool's per-file channel into the run's shard
# directory; after the run none of it may be left behind.
[ "$(count_find "$SBX2/lib/.flac_scan_data" -type f \
        \( -name '*_w*.scan' -o -name '*_w*.log' -o -name '*.result' \) )" -eq 0 ] \
    || _fail "B: a reencode left worker shards behind"

echo "ok: session_state (scan then option 5, pooled)"

# ===========================================================================
# C. Scan, then reencode the PROBLEMS (option 2), in ONE session.
# ===========================================================================
SBX3=''
make_session_sandbox SBX3 1

run_script "$SBX3" '1' '' '2' 'Y' '' 'q'
occur_re 'Scan complete\.'
# Option 2 acts on the report the scan just wrote: exactly the one corrupt file.
occur_re 'Total files processed: 1'
assert_reencoded "$SBX3" 'Successful reencodes: 1' 1
# The healthy file was not in the report, so it is untouched and not backed up.
file_eq "$SBX3/lib/Album/good.flac" 'clean-audio' \
    || _fail "C: option 2 must only touch files the scan flagged"
miss "$SBX3/lib_backup/Album/good.flac"

echo "ok: session_state (scan then option 2)"

# ===========================================================================
# D. Scan, then reencode ALL (option 4), in ONE session.
# ===========================================================================
SBX4=''
make_session_sandbox SBX4 1

run_script "$SBX4" '1' '' '4' 'REENCODE ALL' '' 'q'
occur_re 'Scan complete\.'
assert_reencoded "$SBX4" 'Successful reencodes: 2'

echo "ok: session_state (scan then option 4)"
