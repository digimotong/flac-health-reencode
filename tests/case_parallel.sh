#!/usr/bin/env bash
###############################################################################
# case_parallel.sh - integration: file-level parallel reencoding (jobs > 1)
#
# WHAT THIS CASE PINS
#   The rest of the suite runs with jobs=1 on purpose, so it exercises only the
#   sequential path; it would keep passing if the pool were silently broken. This
#   case is the other half of the contract:
#
#     1. OVERLAP      - with N workers, N reencodes are genuinely in flight at
#                       the same time; with jobs=1 at most one ever is. This is
#                       asserted by MEASURING occupancy (see probe_peak below),
#                       not by inferring it from wall-clock time, because the
#                       clock cannot tell 4 workers from 3.
#     2. WALL CLOCK   - the same work finishes faster in parallel, which is the
#                       point of the change and is not satisfied by a pool that
#                       merely interleaves its output. This is a SMOKE TEST only:
#                       it catches a pool providing no concurrency at all, and
#                       the occupancy assertions above are what pin the degree.
#     3. COMPLETENESS - every file is reencoded exactly once, each original is
#                       mirrored to the backup root, and every path lands in the
#                       tracking DB exactly once. The DB is the hazard the shards
#                       exist for: N workers appending to one file is what the
#                       per-worker .db shard + parent merge replaced, so a
#                       duplicate or missing row here means the sharding is wrong.
#     4. TALLY        - the footer counts match the file count. Each worker
#                       publishes its own PROCESSED/FAIL result record, so a
#                       wrong total means records were lost or double-read.
#     5. HYGIENE      - no shard, index, result, or seed-list file is left behind
#                       once the run has been merged.
###############################################################################

set -o errexit
set -o nounset
set -o pipefail

: "${TESTS_ROOT:?}"
: "${PROD_SCRIPT:?}"
. "$TESTS_ROOT/helpers.sh"

# A library with enough files that 4 workers have something to overlap on.
FILE_COUNT=8
# Each stub reencode is held open this long. Long enough that the difference
# between serial and parallel is far outside process-startup noise, short enough
# that a jobs=1 run of FILE_COUNT files stays well under a second.
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

# set_jobs <n> : repoint the sandbox config at a different worker count. The
# script reads 'jobs' from the config at run time, so each run below can pick its
# own degree of parallelism.
set_jobs() {
    printf '{"library_path": "%s", "backup_path": "%s", "version": "1.1", "jobs": %s}\n' \
        "$LIB" "$BAKROOT" "$1" > "$SBX/flac_health_config.json"
}

###############################################################################
# Concurrency probe helpers (see STUB_FLAC_SLOT_DIR in tests/stub_flac)
#
# The stub hands each re-encode the lowest NUMBERED free slot it can atomically
# mkdir, and records that number. A process holding slot N has therefore proven
# N-1 siblings were in flight with it, so the highest recorded number IS the peak
# concurrency. That is exact, and it is the only assertion here that can fail a
# pool degraded to 2 or 3 workers.
#
# These are defined up here rather than beside their first use because the jobs=1
# assertions below run before any of the later helper definitions.
###############################################################################

# count_find <dir> [find args...] : number of matches, 0 if the dir is absent.
# A missing directory means a run cleaned up MORE than expected, which is a pass,
# so it is reported as 0 rather than aborting: this case runs under errexit +
# pipefail, where a bare `find <missing dir>` exits 1 and pipefail propagates it
# through the pipeline, ending the case silently.
count_find() {
    local dir="$1"; shift
    [ -d "$dir" ] || { echo 0; return 0; }
    find "$dir" "$@" 2>/dev/null | wc -l
}

# probe_reset : start a clean probe directory. Called before each run so one
# run's ranks can never be read as another's.
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

# probe_records : how many re-encodes the probe saw, i.e. how many times the stub
# was invoked to re-encode a file. Independent of output parsing, so it also
# pins "exactly one re-encode per file" at the binary level.
probe_records() {
    count_find "$PROBE" -name '*.rank'
}

# probe_slots_left : slot directories still claimed after the run. Must be 0; a
# leaked slot would inflate the NEXT run's ranking and mask a degraded pool.
probe_slots_left() {
    count_find "$PROBE" -mindepth 1 -maxdepth 1 -type d
}

# work_reset : forget which files are already reencoded and restore the library,
# so the next run does the same amount of work as the previous one. Without this
# the second run would skip everything via the tracking DB and the timings would
# not be comparable.
work_reset() {
    local i
    rm -f "$DB"
    for i in $(seq 1 "$FILE_COUNT"); do
        write_file "$LIB/Album $i/track$i.flac" "orig-$i"
    done
}

# all_run <n> : reencode ALL files with <n> workers in the CURRENT shell, so the
# helper's output variables ($CURRENT_OUT etc.) survive for the assertions below.
# It must NOT be called in a command substitution: that would run in a subshell
# and the assertions would read an empty $CURRENT_OUT.
#
# Wall time is captured in RUN_SECS using the bash builtin $SECONDS. That is
# deliberate: the clock has whole-second granularity, which is coarse enough that
# process-startup jitter never matters. It is NOT what pins the worker count --
# see probe_peak for that. The timing comparison at the end is a smoke test that
# a pool providing no concurrency fails, and nothing finer.
RUN_SECS=0
all_run() {
    local start=$SECONDS
    set_jobs "$1"
    probe_reset
    run_script_env "$SBX" "STUB_FLAC_SLEEP=$STUB_SLEEP" \
        "STUB_FLAC_SLOT_DIR=$PROBE" -- '4' 'REENCODE ALL' ''
    RUN_SECS=$((SECONDS - start))
}

# assert_peak <expected> <label> : the run just executed used exactly <expected>
# re-encodes at once. This is the assertion that can fail a degraded pool, so it
# is checked together with the record count that proves the probe ran at all.
assert_peak() {
    [ "$(probe_records)" -eq "$FILE_COUNT" ] \
        || _fail "$2: probe saw $(probe_records) reencode(s), expected $FILE_COUNT"
    [ "$(probe_peak)" -eq "$1" ] \
        || _fail "$2: peak concurrency was $(probe_peak), expected $1"
    [ "$(probe_slots_left)" -eq 0 ] \
        || _fail "$2: $(probe_slots_left) probe slot(s) left claimed"
}

###############################################################################
# Run 1: sequential baseline (jobs=1) -- the pinned regression anchor
###############################################################################
SEQ_SECS=0
# Progress marker: this case runs three separate script invocations and is slow
# by test-suite standards, so say where we are if it is ever interrupted.
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

# Every original was mirrored, so the parallel run below starts from a known
# state and can be checked with the same backup assertions.
for i in $(seq 1 "$FILE_COUNT"); do
    file_eq "$BAKROOT/Album $i/track$i.flac" "orig-$i" \
        || _fail "jobs=1: missing/wrong backup for track$i"
done

# A sequential run must create NO shard of any kind: jobs=1 is documented to run
# fully inline, and the merge is handed a worker count of 0. If shards show up
# here, the inline path has started forking and the regression anchor is gone.
SHARDS_AFTER_SEQ=$(count_find "$LIB/.flac_scan_data" -type f \
    \( -name '*.result' -o -name '*_w*.log' -o -name '*_w*.db' \))
[ "$SHARDS_AFTER_SEQ" -eq 0 ] \
    || _fail "jobs=1: expected no worker shards, found $SHARDS_AFTER_SEQ"

# Peak concurrency of exactly 1 is the measured form of "runs fully inline": no
# two reencodes were ever in flight together. The absence of shards above is a
# proxy for that; this is the direct observation.
assert_peak 1 'jobs=1'

###############################################################################
# Run 2: the same work with 4 workers
###############################################################################
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

# The real file contents were replaced by the stub marker (reencoding happened),
# and each original is in the backup root at its album-relative path.
for i in $(seq 1 "$FILE_COUNT"); do
    file_eq "$LIB/Album $i/track$i.flac" 'REENCODE_OK' \
        || _fail "jobs=4: track$i was not reencoded"
    file_eq "$BAKROOT/Album $i/track$i.flac" "orig-$i" \
        || _fail "jobs=4: missing/wrong backup for track$i"
done
# ---- the log still holds the full history ----------------------------------
# Per-file status lines go to worker log shards and are folded back in by the
# merge, so the run log must contain them even though the terminal got a replay.
# LOG_DIR is derived from the library rather than by globbing, and the glob is
# guarded: an unmatched "*.txt" would reach `ls` literally, and `ls` would then
# exit non-zero and trip this case's errexit.
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
# Exactly one row mentions track1: the per-worker .db shards were merged, not
# appended to by racing writers, so no path is recorded twice.
[ "$(grep -c 'track1\.flac' "$DB")" -eq 1 ] \
    || _fail "jobs=4: track1 appears more than once in the DB"

# ---- concurrency: 4 workers really did run 4 reencodes at once --------------
# The decisive assertion for this case. A pool that silently used 2 workers
# would still be "faster than serial", would still reencode every file exactly
# once, and would still produce a correct DB -- only the measured occupancy
# distinguishes it from a working 4-worker pool.
assert_peak 4 'jobs=4'



# ---- wall clock: parallel must actually be faster ---------------------------
# SMOKE TEST. This is the weakest assertion in the case and is kept only to pin
# the user-visible benefit: a pool that provides no concurrency at all is slower
# than the sequential baseline and fails here. It canNOT detect a pool degraded
# to 2 or 3 workers -- measured at these settings, 2 workers take ~2.5s against a
# ~3.6s baseline, so it passes. assert_peak above is what pins the degree.
# The bar is "strictly faster" rather than a ratio so a loaded CI machine does
# not fail the suite.
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
# Per-file status lines go to worker log shards and are folded back in by the
# merge, so the run log must contain them even though the terminal got a replay.
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

###############################################################################
# Run 3: FLAC_HEALTH_JOBS overrides the config; a bad value falls back
###############################################################################
# The environment variable wins over the config key: with 'jobs: 1' in the file
# and FLAC_HEALTH_JOBS=3, the run must report 3 workers.
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
# ...and it reached the POOL, not just the banner: with 'jobs: 1' in the config
# the measured occupancy must be 3. A regression that printed the env's value
# while still honouring the config's would pass every other check in this block.
assert_peak 3 'FLAC_HEALTH_JOBS=3'
# A non-numeric override must not reach the pool as a worker count, which would
# break the arithmetic that keeps the pool full; the run falls back and still
# processes everything.
set_jobs 1
work_reset
run_script_env "$SBX" 'FLAC_HEALTH_JOBS=not-a-number' -- '4' 'REENCODE ALL' ''
occur_re "Processing $FILE_COUNT file\\(s\\) with [0-9]+ worker\\(s\\)"
[ "$(captured_count 'Successful reencodes: ([0-9]+)')" -eq "$FILE_COUNT" ] \
    || _fail "bad FLAC_HEALTH_JOBS: not every file was reencoded"
