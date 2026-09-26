#!/usr/bin/env bash
# case_parallel.sh - integration: file-level parallel reencoding (jobs > 1).
#
# The rest of the suite runs with jobs=1, so it only exercises the sequential path
# and would keep passing if the pool were silently broken. This case is the other
# half of the contract:
#
#   1. OVERLAP      with N workers, N reencodes are genuinely in flight at once;
#                   with jobs=1 at most one ever is. Asserted by MEASURING
#                   occupancy (see probe_peak), not from wall-clock time, since a
#                   clock cannot tell 4 workers from 3.
#   2. WALL CLOCK   the same work finishes faster in parallel. A smoke test that
#                   catches a pool providing no concurrency at all; the occupancy
#                   assertions pin the degree.
#   3. COMPLETENESS every file is reencoded exactly once, each original mirrored
#                   into the backup root, and every path lands in the tracking DB
#                   exactly once - a duplicate/missing row means the sharding is
#                   wrong.
#   4. TALLY        the footer counts match the file count, i.e. no worker result
#                   record was lost or double-read.
#   5. HYGIENE      no shard, index, result or seed-list file is left behind.

set -o errexit
set -o nounset
set -o pipefail

: "${TESTS_ROOT:?}"
: "${PROD_SCRIPT:?}"
. "$TESTS_ROOT/helpers.sh"

# A library with enough files that 4 workers have something to overlap on.
FILE_COUNT=8
# Each stub reencode is held open this long: far outside process-startup noise, yet
# a jobs=1 run of FILE_COUNT files still stays well under a second.
STUB_SLEEP=0.4

SBX=''
make_sandbox SBX
register_sandbox "$SBX"
LIB="$SBX/lib"
DB="$LIB/.flac_scan_data/reencoded.db"
BAKROOT="$SBX/lib_backup"

for i in $(seq 1 "$FILE_COUNT"); do
    mkdir -p "$LIB/Album $i"
    write_file "$LIB/Album $i/track$i.flac" "orig-$i"
done

# set_jobs <n> : repoint the sandbox config at a different worker count. The script
# reads 'jobs' at run time, so each run below picks its own degree of parallelism.
set_jobs() {
    printf '{"library_path": "%s", "backup_path": "%s", "version": "1.1", "jobs": %s}\n' \
        "$LIB" "$BAKROOT" "$1" > "$SBX/flac_health_config.json"
}

# ===========================================================================
# Concurrency probe helpers (see STUB_FLAC_SLOT_DIR in tests/stub_flac)
#
# The stub hands each re-encode the lowest NUMBERED free slot it can atomically
# mkdir and records that number. A process holding slot N has proven N-1 siblings
# were in flight with it, so the highest recorded number IS the peak concurrency:
# exact, and the only assertion here that can fail a pool degraded to 2 or 3.
#
# These are defined up here rather than beside their first use because the jobs=1
# assertions below run before any of the later helper definitions.
# ===========================================================================

# count_find <dir> [find args...] : number of matches, 0 if the dir is absent.
# A missing directory means the run cleaned up MORE than expected (a pass), so it
# is reported as 0 instead of aborting: under errexit + pipefail a bare
# `find <missing dir>` exits 1, which pipefail would propagate and end the case.
count_find() {
    local dir="$1"; shift
    [ -d "$dir" ] || { echo 0; return 0; }
    find "$dir" "$@" 2>/dev/null | wc -l
}

# probe_reset : start a clean probe directory, so one run's ranks can never be read
# as another's.
probe_reset() {
    PROBE="$SBX/probe"
    rm -rf "$PROBE"
    mkdir -p "$PROBE"
}

# probe_peak : the highest slot rank claimed during the run on $PROBE.
probe_peak() {
    local rank
    rank=$(cat "$PROBE"/*.rank 2>/dev/null | sort -n | tail -n1)
    echo "${rank:-0}"
}

# probe_records : how many times the stub was invoked to re-encode a file.
# Independent of output parsing, so it also pins "exactly one re-encode per file".
probe_records() {
    count_find "$PROBE" -name '*.rank'
}

# probe_slots_left : slot directories still claimed after the run. Must be 0; a
# leaked slot would inflate the NEXT run's ranking and mask a degraded pool.
probe_slots_left() {
    count_find "$PROBE" -mindepth 1 -maxdepth 1 -type d
}

# work_reset : forget which files are already reencoded and restore the library, so
# the next run does the same work as the previous one. Otherwise the second run
# would skip everything via the tracking DB and the timings would not compare.
work_reset() {
    local i
    rm -f "$DB"
    for i in $(seq 1 "$FILE_COUNT"); do
        write_file "$LIB/Album $i/track$i.flac" "orig-$i"
    done
}

# all_run <n> : reencode ALL files with <n> workers in the CURRENT shell, so the
# helper's output variables ($CURRENT_OUT etc.) survive for the assertions below.
# Must NOT be called in a command substitution, which would run in a subshell and
# leave the assertions reading an empty $CURRENT_OUT.
#
# RUN_SECS uses the bash builtin $SECONDS: whole-second granularity is coarse
# enough that process-startup jitter never matters. It does NOT pin the worker
# count -- probe_peak does that; the timing comparison is only a smoke test that a
# pool providing no concurrency fails.
RUN_SECS=0
all_run() {
    local start=$SECONDS
    set_jobs "$1"
    probe_reset
    run_script_env "$SBX" "STUB_FLAC_SLEEP=$STUB_SLEEP" \
        "STUB_FLAC_SLOT_DIR=$PROBE" -- '4' 'REENCODE ALL' ''
    RUN_SECS=$((SECONDS - start))
}

# assert_peak <expected_peak> <label> <expected_records>
# The run just executed used exactly <expected_peak> invocations at once, and the
# probe saw <expected_records> in total. This is the assertion that can fail a
# degraded pool, so it is checked with the record count that proves the probe ran.
#
# <expected_records> is a parameter rather than the $FILE_COUNT global because the
# helper serves two operations: a reencode drives one stub invocation per file,
# while a run that scans and re-encodes would see two.
assert_peak() {
    [ "$(probe_records)" -eq "$3" ] \
        || _fail "$2: probe saw $(probe_records) invocation(s), expected $3"
    [ "$(probe_peak)" -eq "$1" ] \
        || _fail "$2: peak concurrency was $(probe_peak), expected $1"
    [ "$(probe_slots_left)" -eq 0 ] \
        || _fail "$2: $(probe_slots_left) probe slot(s) left claimed"
}

# ===========================================================================
# Run 1: sequential baseline (jobs=1) -- the pinned regression anchor
# ===========================================================================
SEQ_SECS=0
# Progress marker: this case runs three script invocations and is slow by suite
# standards, so say where we are if it is ever interrupted.
echo "  .. jobs=1 baseline run (${FILE_COUNT} files)"
all_run 1
SEQ_SECS=$RUN_SECS

occur_re "Processing $FILE_COUNT file\\(s\\) with 1 worker\\(s\\)"
# Sequential runs print every status inline, in file order, with no replay step.
occur_re "SUCCESS: $LIB/Album 1/track1.flac reencoded successfully"
occur_re "SUCCESS: $LIB/Album $FILE_COUNT/track$FILE_COUNT.flac reencoded successfully"
[ "$(message_count 'SUCCESS:')" -eq "$FILE_COUNT" ] \
    || _fail "jobs=1: expected exactly $FILE_COUNT SUCCESS lines"
[ "$(captured_count 'Total files processed: ([0-9]+)')" -eq "$FILE_COUNT" ] \
    || _fail "jobs=1: processed count != $FILE_COUNT"
[ "$(captured_count 'Successful reencodes: ([0-9]+)')" -eq "$FILE_COUNT" ] \
    || _fail "jobs=1: success count != $FILE_COUNT"
[ "$(wc -l < "$DB")" -eq "$FILE_COUNT" ] \
    || _fail "jobs=1: DB should hold exactly $FILE_COUNT rows"

# Every original was mirrored, so the parallel run below starts from a known state
# and can be checked with the same backup assertions.
for i in $(seq 1 "$FILE_COUNT"); do
    file_eq "$BAKROOT/Album $i/track$i.flac" "orig-$i" \
        || _fail "jobs=1: missing/wrong backup for track$i"
done

# A sequential run must create NO shard of any kind: jobs=1 is documented to run
# fully inline and the merge is handed a worker count of 0. Shards here would mean
# the inline path started forking and the regression anchor is gone.
SHARDS_AFTER_SEQ=$(count_find "$LIB/.flac_scan_data" -type f \
    \( -name '*.result' -o -name '*_w*.log' -o -name '*_w*.db' \))
[ "$SHARDS_AFTER_SEQ" -eq 0 ] \
    || _fail "jobs=1: expected no worker shards, found $SHARDS_AFTER_SEQ"

# Peak concurrency of exactly 1 is the measured form of "runs fully inline"; the
# absence of shards above is only a proxy for it.
assert_peak 1 'jobs=1' "$FILE_COUNT"

# ===========================================================================
# Run 2: the same work with 4 workers
# ===========================================================================
work_reset
PAR_SECS=0
echo "  .. jobs=4 parallel run (${FILE_COUNT} files)"
all_run 4
PAR_SECS=$RUN_SECS

occur_re "Processing $FILE_COUNT file\\(s\\) with 4 worker\\(s\\)"

# ---- completeness: every file succeeded, exactly once ----------------------
occur_re "SUCCESS: $LIB/Album 1/track1.flac reencoded successfully"
occur_re "SUCCESS: $LIB/Album $FILE_COUNT/track$FILE_COUNT.flac reencoded successfully"
[ "$(message_count 'SUCCESS:')" -eq "$FILE_COUNT" ] \
    || _fail "jobs=4: expected exactly $FILE_COUNT SUCCESS lines"

# ---- tally ----------------------------------------------------------------
[ "$(captured_count 'Total files processed: ([0-9]+)')" -eq "$FILE_COUNT" ] \
    || _fail "jobs=4: processed count != $FILE_COUNT"
[ "$(captured_count 'Successful reencodes: ([0-9]+)')" -eq "$FILE_COUNT" ] \
    || _fail "jobs=4: success count != $FILE_COUNT"
[ "$(captured_count 'Failed reencodes: ([0-9]+)')" -eq 0 ] \
    || _fail "jobs=4: failure count != 0"

# The real file contents were replaced by the stub marker (reencoding happened), and
# each original is in the backup root at its album-relative path.
for i in $(seq 1 "$FILE_COUNT"); do
    file_eq "$LIB/Album $i/track$i.flac" 'REENCODE_OK' \
        || _fail "jobs=4: track$i was not reencoded"
    file_eq "$BAKROOT/Album $i/track$i.flac" "orig-$i" \
        || _fail "jobs=4: missing/wrong backup for track$i"
done
# ---- the log still holds the full history ----------------------------------
# Per-file statuses go to worker log shards and are folded back in by the merge, so
# the run log must contain them even though the terminal got a replay. LOG_DIR is
# the library path rather than a glob, and the glob below is guarded: an unmatched
# "*.txt" would reach `ls` literally and trip this case's errexit.
LOG_DIR="$LIB/.flac_scan_data/logs"
[ -d "$LOG_DIR" ] || _fail "jobs=4: no run log directory was created"
LOG=''
for f in "$LOG_DIR"/*.txt; do
    [ -e "$f" ] || continue
    if [ -z "$LOG" ] || [ "$f" -nt "$LOG" ]; then LOG="$f"; fi
done
[ -n "$LOG" ] || _fail "jobs=4: no run log was written"
[ "$(grep -c 'SUCCESS:' "$LOG")" -eq "$FILE_COUNT" ] \
    || _fail "jobs=4: run log should hold all $FILE_COUNT SUCCESS lines"

# ---- DB: one row per file, no duplicates -----------------------------------
[ "$(wc -l < "$DB")" -eq "$FILE_COUNT" ] \
    || _fail "jobs=4: DB should hold exactly $FILE_COUNT rows"
for i in $(seq 1 "$FILE_COUNT"); do
    db_has_path "$SBX" "$LIB/Album $i/track$i.flac"
done
# Exactly one row mentions track1: the per-worker .db shards were merged rather
# than appended to by racing writers, so no path is recorded twice.
[ "$(grep -c 'track1\.flac' "$DB")" -eq 1 ] \
    || _fail "jobs=4: track1 appears more than once in the DB"

# ---- concurrency: 4 workers really did run 4 reencodes at once --------------
# The decisive assertion: a pool that silently used 2 workers would still be
# "faster than serial", would still reencode every file once and produce a correct
# DB -- only measured occupancy distinguishes it from a working 4-worker pool.
assert_peak 4 'jobs=4' "$FILE_COUNT"

# ---- wall clock: parallel must actually be faster ---------------------------
# SMOKE TEST, the weakest assertion here, kept to pin the user-visible benefit: a
# pool providing no concurrency at all is slower than the baseline. It canNOT
# detect a pool degraded to 2-3 workers (2 workers still beat the baseline), so
# assert_peak above is what pins the degree. The bar is "strictly faster" rather
# than a ratio, so a loaded CI machine does not fail the suite.
[ "$PAR_SECS" -lt "$SEQ_SECS" ] \
    || _fail "4 workers (${PAR_SECS}s) not faster than 1 worker (${SEQ_SECS}s)"

# ---- hygiene: nothing left behind ------------------------------------------
LEFTOVER=$(count_find "$LIB/.flac_scan_data" -type f \
    \( -name '*.result' -o -name '*_w*.log' -o -name '*_w*.db' -o -name '*.index' \))
[ "$LEFTOVER" -eq 0 ] \
    || _fail "jobs=4: $LEFTOVER shard/index file(s) left behind"
# The work list is transient too: it must not survive the run.
SEEDLIST=$(count_find "$LIB/.flac_scan_data/seed" -name '*.paths')
[ "$SEEDLIST" -eq 0 ] \
    || _fail "jobs=4: $SEEDLIST seed list(s) left behind"

# ---- the log still holds the full history ----------------------------------
# Per-file statuses go to worker log shards and are folded back in by the merge, so
# the run log must contain them even though the terminal got a replay.
LOG_DIR="$LIB/.flac_scan_data/logs"
[ -d "$LOG_DIR" ] || _fail "jobs=4: no run log directory was created"
LOG=''
for f in "$LOG_DIR"/*.txt; do
    [ -e "$f" ] || continue
    if [ -z "$LOG" ] || [ "$f" -nt "$LOG" ]; then LOG="$f"; fi
done
[ -n "$LOG" ] || _fail "jobs=4: no run log was written"
[ "$(grep -c 'SUCCESS:' "$LOG")" -eq "$FILE_COUNT" ] \
    || _fail "jobs=4: run log should hold all $FILE_COUNT SUCCESS lines"
# ===========================================================================
# Run 3: FLAC_HEALTH_JOBS overrides the config; a bad value falls back
# ===========================================================================
# The env var wins over the config key: with 'jobs: 1' in the file and
# FLAC_HEALTH_JOBS=3, the run must report 3 workers.
set_jobs 1
work_reset
probe_reset
run_script_env "$SBX" 'FLAC_HEALTH_JOBS=3' "STUB_FLAC_SLEEP=$STUB_SLEEP" \
    "STUB_FLAC_SLOT_DIR=$PROBE" -- '4' 'REENCODE ALL' ''
occur_re "Processing $FILE_COUNT file\\(s\\) with 3 worker\\(s\\)"
occur_re 'Workers: 3 \(from FLAC_HEALTH_JOBS\)'
# The override really took effect: the work got done with the env's worker count.
[ "$(captured_count 'Successful reencodes: ([0-9]+)')" -eq "$FILE_COUNT" ] \
    || _fail "FLAC_HEALTH_JOBS=3: not every file was reencoded"
[ "$(message_count 'SUCCESS:')" -eq "$FILE_COUNT" ] \
    || _fail "FLAC_HEALTH_JOBS=3: expected exactly $FILE_COUNT SUCCESS lines"
# ...and it reached the POOL, not just the banner: with 'jobs: 1' in the config the
# measured occupancy must be 3. A regression that printed the env's value while
# still honoring the config's would pass every other check in this block.
assert_peak 3 'FLAC_HEALTH_JOBS=3' "$FILE_COUNT"
# A non-numeric override must not reach the pool as a worker count, which would
# break the pool's arithmetic; the run falls back and still processes everything.
set_jobs 1
work_reset
run_script_env "$SBX" 'FLAC_HEALTH_JOBS=not-a-number' -- '4' 'REENCODE ALL' ''
occur_re "Processing $FILE_COUNT file\\(s\\) with [0-9]+ worker\\(s\\)"
[ "$(captured_count 'Successful reencodes: ([0-9]+)')" -eq "$FILE_COUNT" ] \
    || _fail "bad FLAC_HEALTH_JOBS: not every file was reencoded"
[ "$(captured_count 'Successful reencodes: ([0-9]+)')" -eq "$FILE_COUNT" ] \
    || _fail "bad FLAC_HEALTH_JOBS: not every file was reencoded"

# ===========================================================================
# Run 4: the SCAN path (option 1) is pooled too -- same pool, different worker
#
# A scan reuses the reencode pool's scheduler, so it inherits the same guarantees.
# Two contract points are specific to it:
#   * it is READ-ONLY, so nothing is completed or mirrored; what matters is that
#     every file is verified exactly once (probe record count) and that occupancy
#     tracks 'jobs';
#   * its OUTPUT must not depend on the pool's completion order: errors are
#     replayed in dispatch order, so the CSV manifest that option 2 consumes is
#     identical whatever the worker count. Asserted by running the same library at
#     jobs=1 and jobs=4 and requiring the two CSVs to match byte for byte.
# ===========================================================================

# Fixture: 6 clean files plus 2 corrupt ones, so the CSV has more than one row and
# their ORDER is observable. 'corrupt' is what the stub's verify path keys on (see
# tests/stub_flac); the reencode path is never reached here.
SCAN_COUNT=8
SCAN_BAD=(3 6)
scan_fixture() {
    local i
    rm -rf "$LIB"
    mkdir -p "$LIB/Album"
    for i in $(seq 1 "$SCAN_COUNT"); do
        if [[ " ${SCAN_BAD[*]} " == *" $i "* ]]; then
            write_file "$LIB/Album/bad$i.flac" "payload-$i:CORRUPT"
        else
            write_file "$LIB/Album/ok$i.flac" "payload-$i"
        fi
    done
}

# scan_csv : the single scan report CSV from the most recent run ('' if none).
scan_csv() {
    find "$LIB/.flac_scan_data/reports" -type f -name 'flac_scan_*.csv' -print 2>/dev/null \
        | head -n1
}

# scan_run <jobs> <out_var> : run option 1 with <jobs> workers and copy the resulting
# CSV to the file named by <out_var>. Runs in the CURRENT shell (see all_run) so
# run_script_env's output variables survive.
scan_run() {
    local jobs="$1"
    local out_var="$2"
    local csv
    set_jobs "$jobs"
    scan_fixture
    probe_reset
    run_script_env "$SBX" "STUB_FLAC_TEST_SLEEP=$STUB_SLEEP" \
        "STUB_FLAC_SLOT_DIR=$PROBE" -- '1' '' ''
    csv="$(scan_csv)"
    [ -n "$csv" ] || _fail "scan at jobs=$jobs: expected a CSV report for a corrupt library"
    cp "$csv" "$SBX/scan_$out_var.csv"
    printf -v "$out_var" '%s' "$SBX/scan_$out_var.csv"
}

SCAN_SEQ_CSV=''
SCAN_PAR_CSV=''

echo "  .. jobs=1 scan run (${SCAN_COUNT} files)"
scan_run 1 SCAN_SEQ_CSV
[ "$(captured_count 'Scanned ([0-9]+) files')" -eq "$SCAN_COUNT" ] \
    || _fail "jobs=1 scan: scanned count != $SCAN_COUNT"
[ "$(message_count 'Error detected in:')" -eq "${#SCAN_BAD[@]}" ] \
    || _fail "jobs=1 scan: expected exactly ${#SCAN_BAD[@]} error lines"
# Sequential scan renders its historical plain-text bar line.
occur_re 'Progress: \[#+-*\]'
# A scan must not announce workers it is not using: the marker appears only when
# jobs > 1, so its absence here is part of the jobs=1 contract.
absent_re 'Scanning with [0-9]+ worker\(s\)'
# Read-only: the scan creates no shard and no backup.
[ "$(count_find "$LIB/.flac_scan_data" -type f \
        \( -name '*_w*.scan' -o -name '*_w*.log' -o -name '*.result' \) )" -eq 0 ] \
    || _fail "jobs=1 scan: scan left worker shards behind"
assert_peak 1 'jobs=1 scan' "$SCAN_COUNT"

echo "  .. jobs=4 scan run (${SCAN_COUNT} files)"
scan_run 4 SCAN_PAR_CSV
occur_re 'Scanning with 4 worker\(s\)'
[ "$(captured_count 'Scanned ([0-9]+) files')" -eq "$SCAN_COUNT" ] \
    || _fail "jobs=4 scan: scanned count != $SCAN_COUNT"
[ "$(message_count 'Error detected in:')" -eq "${#SCAN_BAD[@]}" ] \
    || _fail "jobs=4 scan: expected exactly ${#SCAN_BAD[@]} error lines"
[ "$(captured_count 'Found ([0-9]+) errors')" -eq "${#SCAN_BAD[@]}" ] \
    || _fail "jobs=4 scan: error tally != ${#SCAN_BAD[@]}"
# The pool is really used: 4 verifies were in flight at once.
assert_peak 4 'jobs=4 scan' "$SCAN_COUNT"

# THE ORDERING CONTRACT: the CSV is identical whether the scan ran with 1 worker or
# 4. This fails if the workers' shards are concatenated in completion order instead
# of being replayed by dispatch id, and it is checked on the file option 2 consumes.
#
# Only the DATA rows are compared: the runs happen at different times, so the
# '# Scan Report ... <timestamp>' comment legitimately differs.
tail -n +2 "$SCAN_SEQ_CSV" > "$SBX/seq_rows.txt"
tail -n +2 "$SCAN_PAR_CSV" > "$SBX/par_rows.txt"
diff -u "$SBX/seq_rows.txt" "$SBX/par_rows.txt" > "$SBX/rows.diff" 2>&1 \
    || _fail "jobs=4 scan CSV rows differ from the jobs=1 rows (order not preserved)"
# ...and the rows really are the corrupt files in the library's own order, so the
# equality above is not two identically-wrong files.
BAD_ROWS=$(grep -c '^"' "$SCAN_PAR_CSV")
[ "$BAD_ROWS" -eq "${#SCAN_BAD[@]}" ] \
    || _fail "jobs=4 scan CSV has $BAD_ROWS data row(s), expected ${#SCAN_BAD[@]}"
for n in "${SCAN_BAD[@]}"; do
    grep -Fq "\"$LIB/Album/bad$n.flac\"" "$SCAN_PAR_CSV" \
        || _fail "jobs=4 scan CSV is missing bad$n.flac"
done

# A clean library must still leave no CSV and no shards when scanned in parallel:
# the report-removal path has to run on the pooled branch too.
set_jobs 4
rm -rf "$LIB"
mkdir -p "$LIB/Album"
write_file "$LIB/Album/clean.flac" 'PRISTINE'
probe_reset
run_script_env "$SBX" -- '1' '' ''
occur_re 'No errors found'
[ -z "$(scan_csv)" ] || _fail "jobs=4 clean scan left a CSV behind"
[ "$(count_find "$LIB/.flac_scan_data" -type f \
        \( -name '*_w*.scan' -o -name '*_w*.log' -o -name '*.result' \) )" -eq 0 ] \
    || _fail "jobs=4 clean scan left worker shards behind"

echo "ok: case_parallel (scan path pooled, order preserved)"

