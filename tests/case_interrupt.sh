#!/usr/bin/env bash
# case_interrupt.sh - integration: a pooled run interrupted by a signal cleans up.
#
# Signals the PARENT alone, which is the case _pool_interrupt_cleanup exists for: a
# terminal Ctrl-C signals the whole foreground group, but a `kill -TERM`, `systemctl
# stop` or `pkill` reaches only the shell, so without the handler the workers keep
# running and keep rewriting audio. Covered otherwise only by the non-required
# tests/manual/real_flac_resilience.sh scenario A.
#
# Asserts: 1) the handler's diagnostic appears; 2) the parent exits 143 (128+TERM);
# 3) the workers are killed promptly, not left to finish (checked against a sampled
# process count); 4) this run's .part temps, shards, index, temp manifest and seed
# list are gone; 5) the partial run log is KEPT; 6) a fresh run over the same library
# completes with no failures. The DB may legitimately be short: an interrupted file
# can be replaced while its DB row is still only in a shard.
#
# TERM (15) is the signal under test because INT is what Ctrl-C delivers to the whole
# group anyway; all three share one registration, so an INT/HUP regression is caught too.

set -o errexit
set -o nounset
set -o pipefail

: "${TESTS_ROOT:?}"
: "${PROD_SCRIPT:?}"
. "$TESTS_ROOT/helpers.sh"

# Enough files that 4 workers are genuinely mid-encode when the signal lands, and a
# stub reencode long enough that the signal cannot arrive after they all finished
# (which would leave nothing to clean up and make this case pass vacuously).
FILE_COUNT=8
JOBS=4
STUB_SLEEP=4
# Sampling cadence for the survivor check (see section 3).
SAMPLE_INTERVAL=0.2
# Time to let the pool fork its workers and get them into the stub sleep.
PRE_SIGNAL_WAIT=1.5

# Upper bound on the busy samples a healthy run may record. Derived from the leak it
# must separate, so the two cannot drift apart when STUB_SLEEP changes: the leak is the
# rest of the stub's hold after the signal, (STUB_SLEEP - PRE_SIGNAL_WAIT) = 2.5s, and
# the bound is 2/5 of it (~1.0s). Healthy runs record 1-2.
#
# Integer-only arithmetic (bash has no floats): the leak window and the cadence are both
# scaled to milliseconds, and a non-numeric input or a non-positive leak falls back to the
# default rather than dividing by zero inside $(( )) under `set -e`.
MAX_BUSY_SAMPLES=5
if [[ "$STUB_SLEEP" =~ ^[0-9]+$ && "$PRE_SIGNAL_WAIT" =~ ^[0-9]+(\.[0-9]+)?$ && "$SAMPLE_INTERVAL" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    # Leak window in milliseconds.
    leak_secs="${PRE_SIGNAL_WAIT%%.*}"
    leak_frac="${PRE_SIGNAL_WAIT#*.}"
    [ "$leak_frac" = "$PRE_SIGNAL_WAIT" ] && leak_frac=""
    case "${#leak_frac}" in
        0) leak_frac="000" ;;
        1) leak_frac="${leak_frac}00" ;;
        2) leak_frac="${leak_frac}0" ;;
        *) leak_frac="${leak_frac:0:3}" ;;
    esac
    leak_ms=$(( STUB_SLEEP * 1000 - leak_secs * 1000 - leak_frac ))
    # Sample cadence in milliseconds (same split, so 0.2 -> 200).
    interval_secs="${SAMPLE_INTERVAL%%.*}"
    interval_frac="${SAMPLE_INTERVAL#*.}"
    [ "$interval_frac" = "$SAMPLE_INTERVAL" ] && interval_frac=""
    case "${#interval_frac}" in
        0) interval_frac="000" ;;
        1) interval_frac="${interval_frac}00" ;;
        2) interval_frac="${interval_frac}0" ;;
        *) interval_frac="${interval_frac:0:3}" ;;
    esac
    interval_ms=$(( interval_secs * 1000 + interval_frac ))
    if [ "$leak_ms" -gt 0 ] && [ "$interval_ms" -gt 0 ]; then
        # 2/5 of the leak in samples, rounded UP so the bound never sits below a
        # half-sample boundary and turns a healthy near-miss into a failure.
        MAX_BUSY_SAMPLES=$(( (leak_ms * 2 + interval_ms * 5 - 1) / (interval_ms * 5) ))
    fi
fi
[ "$MAX_BUSY_SAMPLES" -ge 2 ] || MAX_BUSY_SAMPLES=2

SBX=''
make_sandbox SBX
register_sandbox "$SBX"
LIB="$SBX/lib"
BAKROOT="$SBX/lib_backup"

mkdir -p "$LIB/Album"
for i in $(seq 1 "$FILE_COUNT"); do
    write_file "$LIB/Album/track$i.flac" "orig-$i"
done

# set_jobs <n> : repoint the sandbox config at a different worker count. helpers.sh
# pins 'jobs' to 1 for the sequential-anchor cases, so each parallelism case owns its
# degree.
set_jobs() {
    printf '{"library_path": "%s", "backup_path": "%s", "version": "1.1", "jobs": %s}\n' \
        "$LIB" "$BAKROOT" "$1" > "$SBX/flac_health_config.json"
}
set_jobs "$JOBS"

# start_pooled <sbx> <out> : begin a jobs=4 option-4 run in the background with the
#   stub reencode held open, and set RUN_PID to the script's PID.
#
# It runs under setsid, and that is the whole point of this case: a plain `cmd &` in a
# non-interactive shell does NOT get its own process group, so the workers would
# inherit THIS shell's PGID and signalling the script would take them down as a side
# effect of group delivery - the case would pass even with the handler's kills deleted.
# setsid puts the script in a new session, so the handler is the ONLY way a worker can
# receive the signal. `--wait` keeps the background job alive until the script exits,
# so `wait` below still works. setsid is util-linux, so its absence is a SKIP.
RUN_PID=''
start_pooled() {
    local sbx="$1" out="$2"
    printf '%s\n' '4' 'REENCODE ALL' '' > "$sbx/interrupt.in"
    setsid --wait env "STUB_FLAC_SLEEP=$STUB_SLEEP" PATH="$sbx/bin:$PATH_PRE" \
        bash "$sbx/flac_health_reencode.sh" < "$sbx/interrupt.in" > "$out" 2>&1 &
    RUN_PID=$!
}

# no_procs <sbx> : count processes whose command line mentions the sandbox.
#   pgrep exits 1 when it matches nothing - which is the PASS condition - so it is
#   guarded here rather than being left to trip this case's errexit.
no_procs() {
    local n=0
    while IFS= read -r _line; do n=$((n + 1)); done \
        < <(pgrep -f "$1" 2>/dev/null || true)
    echo "$n"
}

# count_find <dir> [find args...] : number of matches, 0 when the dir is absent.
#   A missing directory means the run cleaned up MORE than expected - a pass - and
#   under errexit + pipefail a bare `find <missing dir>` would exit 1 and end the case.
count_find() {
    local dir="$1"; shift
    [ -d "$dir" ] || { echo 0; return 0; }
    find "$dir" "$@" 2>/dev/null | wc -l
}

# setsid is what makes this case able to tell a working handler from a missing one
# (see start_pooled), so SKIP rather than a false PASS without it.
command -v setsid >/dev/null 2>&1 \
    || { echo "SKIP: setsid (util-linux) not available; cannot signal the parent alone"
         exit 0; }

# ===========================================================================
# Interrupt a jobs=4 option-4 run while the workers are mid-encode
# ===========================================================================
INTERRUPT_OUT="$SBX/interrupt.log"
echo "  .. jobs=$JOBS run interrupted after ${PRE_SIGNAL_WAIT}s (${FILE_COUNT} files)"
start_pooled "$SBX" "$INTERRUPT_OUT"
parent_pid="$RUN_PID"

# Confirm the pool really started before signalling, so "it finished first" can
# never be mistaken for "the interrupt worked". Bounded, so a run that never reports
# still gets signalled and the assertions below explain what happened.
waited=0
while [ "$waited" -lt 40 ]; do
    grep -q 'Processing' "$INTERRUPT_OUT" 2>/dev/null && break
    sleep 0.05
    waited=$((waited + 1))
done
grep -q 'Processing' "$INTERRUPT_OUT" \
    || _fail "the run never started the pool; output:
$(cat "$INTERRUPT_OUT")"
sleep "$PRE_SIGNAL_WAIT"

# Sanity-check the construction this case depends on: the workers must NOT be in our
# process group, or the signal below would reach them directly and the process
# assertion would be vacuous. Every command here is guarded, because `grep -c` exits 1
# on a zero count and `grep -qv` exits 1 when nothing matches - both are the answers we
# WANT, and under errexit an unguarded one would end the case with no diagnostic.
own_pgid="$(ps -o pgid= -p "$parent_pid" 2>/dev/null | tr -d ' ' || true)"
[ -n "$own_pgid" ] \
    || _fail "could not read the script's process group; it may have exited already"
[ "$own_pgid" != "$$" ] \
    || _fail "the script is still in this case's process group ($$); setsid did not isolate it"
worker_pgids="$(ps -o pgid= --ppid "$parent_pid" 2>/dev/null | tr -d ' ' | sort -u || true)"
if printf '%s\n' "$worker_pgids" | grep -qx "$$"; then
    _fail "worker(s) share this case's process group ($$); the interrupt signal would reach them directly and the process assertion would prove nothing"
fi
# At least one worker must exist at signal time, otherwise the run either finished
# early (nothing to clean up) or the pool never forked, and the assertions below would
# be vacuous rather than failing.
[ -n "$worker_pgids" ] \
    || _fail "no workers were running when the signal was about to be sent; the interrupt would prove nothing (output:
$(tail -5 "$INTERRUPT_OUT"))"

# Start the survivor sampler BEFORE the signal, so it observes the whole window in which
# a non-killed worker would still be running. It records the sandbox process count once
# per SAMPLE_INTERVAL, beginning at the handler's diagnostic - samples taken before that
# legitimately see the parent plus every worker the pool is meant to be running - and
# stops at the first quiet instant, or when a generous bound expires.
#
# Sampling rather than one check after `wait` is necessary: the interrupt path is a
# graceful drain, so orphaned workers die the moment the parent exits, and a post-`wait`
# check therefore sees zero even on a leak. Stopping the sampler at `wait` is wrong for
# the mirror-image reason - a healthy run could record one non-quiet sample and fail.
# The series' length is thus how long the sandbox stayed busy after the handler
# announced itself, which is exactly the interval a missing kill turns into a leak.
SAMPLE_FILE="$SBX/survivors.samples"
: > "$SAMPLE_FILE"
(
    while ! grep -q 'Interrupted (signal' "$INTERRUPT_OUT" 2>/dev/null; do
        sleep "$SAMPLE_INTERVAL"
    done
    tries=0
    while [ "$tries" -lt 60 ]; do
        n="$(no_procs "$SBX")"
        printf '%s\n' "$n" >> "$SAMPLE_FILE"
        [ "$n" -eq 0 ] && break
        tries=$((tries + 1))
        sleep "$SAMPLE_INTERVAL"
    done
) 2>/dev/null &
sampler_pid=$!

# Signal the script ALONE - not a process group. This is the `kill -TERM <pid>` /
# `systemctl stop` / `pkill` case, and the only one the handler exists for.
kill -TERM "$parent_pid" 2>/dev/null || true

# `wait` is expected to fail: the handler exits 128+signo on purpose.
if wait "$parent_pid" 2>/dev/null; then
    status=0
else
    status=$?
fi

# The sampler is deliberately NOT stopped here: it is self-terminating and its bound is
# small, so waiting for it is short - and it is the only way to observe the moment the
# orphans of a broken handler disappear, which is after the parent has exited. Killing it
# now would freeze the series at a single non-quiet sample on a healthy run.
wait "$sampler_pid" 2>/dev/null || true

# ---- 1. the handler ran and said what happened -----------------------------
grep -q 'Interrupted (signal 15): stopping workers' "$INTERRUPT_OUT" \
    || _fail "the interrupt handler printed no diagnostic (expected 'Interrupted (signal 15)'); output:
$(tail -20 "$INTERRUPT_OUT")"

# ---- 2. exit status = 128 + SIGTERM ----------------------------------------
[ "$status" -eq 143 ] \
    || _fail "expected the handler to exit 143 (128+SIGTERM), got $status; output:
$(tail -20 "$INTERRUPT_OUT")"

# ---- 3. the workers were STOPPED, not merely left to finish ----------------
# The series' LENGTH is how long the sandbox stayed busy after the handler's diagnostic:
# a working handler stops the workers within a sample or two, while a handler that never
# kills them leaves the stub's remaining 2.5s of work running (measured as 13 samples at
# this cadence). MAX_BUSY_SAMPLES is derived from that same leak, so the bound sits far
# from both. The series is echoed on success as well as failure, so the margin is a
# number in the log rather than a claim here.
#
# Mutation-tested: neutering BOTH worker kills is caught ("stayed busy for 13 samples") -
# the leak is visible precisely because the handler's `trap '' INT TERM HUP` stops the
# workers reacting to the propagated signal, so they must be killed explicitly. Removing
# the re-entrancy disarm alone survives, correctly: it disables no kill and has no
# observable effect without a second signal.
samples="$(cat "$SAMPLE_FILE" 2>/dev/null || true)"
sample_count="$(printf '%s\n' "$samples" | grep -c '[0-9]' || true)"
[ "${sample_count:-0}" -ge 1 ] \
    || _fail "the survivor sampler recorded nothing; the interrupt window was never observed"
first_zero="$(printf '%s\n' "$samples" | grep '[0-9]' | awk '$1 == 0 { print NR; exit }')"
[ -n "$first_zero" ] \
    || _fail "the sandbox never went quiet after the handler's diagnostic; the workers were never stopped (observed counts: $(printf '%s ' "$samples"))"
[ "$first_zero" -le "$MAX_BUSY_SAMPLES" ] \
    || _fail "the sandbox stayed busy for $first_zero samples after the handler's diagnostic before going quiet; the workers were left to finish on their own rather than stopped (observed counts: $(printf '%s ' "$samples"))"
# The series must end at that quiet instant and never go live again: a sample after it
# would mean work resumed after the sweep.
tail_after_zero="$(printf '%s\n' "$samples" | grep '[0-9]' | tail -n +"$((first_zero + 1))" | grep -v '^0$' || true)"
[ -z "$tail_after_zero" ] \
    || _fail "processes reappeared after the sweep (counts: $(printf '%s ' "$tail_after_zero"))"
# And nothing may survive once the parent has fully exited.
[ "$(no_procs "$SBX")" -eq 0 ] \
    || _fail "$(no_procs "$SBX") process(es) survived the interrupt entirely"
# Echo the measured series even on success: a value approaching the bound is the early
# warning a pass/fail bit cannot give.
echo "  .. workers stopped after $first_zero of ${MAX_BUSY_SAMPLES} allowed busy samples (series: $(printf '%s ' "$samples"))"

# ---- 4. this run's artifacts are all gone ----------------------------------
PART_COUNT=$(count_find "$LIB" -name '*.part')
[ "$PART_COUNT" -eq 0 ] \
    || _fail "$PART_COUNT in-library .part temp(s) survived the interrupt"
SHARD_DIRS=$(count_find "$LIB/.flac_scan_data" -type d -name shards)
[ "$SHARD_DIRS" -eq 0 ] \
    || _fail "the shards/ directory survived the interrupt"
INDEX_COUNT=$(count_find "$LIB/.flac_scan_data" -name '*.index')
[ "$INDEX_COUNT" -eq 0 ] \
    || _fail "$INDEX_COUNT dispatch index file(s) survived the interrupt"
TEMPS_COUNT=$(count_find "$LIB/.flac_scan_data" -name '*.temps')
[ "$TEMPS_COUNT" -eq 0 ] \
    || _fail "$TEMPS_COUNT temp manifest(s) survived the interrupt"
SEED_COUNT=$(count_find "$LIB/.flac_scan_data" -name '*.paths')
[ "$SEED_COUNT" -eq 0 ] \
    || _fail "$SEED_COUNT seed work list(s) survived the interrupt"

# ---- 5. the partial run log is KEPT on purpose -----------------------------
LOG_DIR="$LIB/.flac_scan_data/logs"
[ "$(count_find "$LOG_DIR" -name '*.txt')" -ge 1 ] \
    || _fail "the partial run log was deleted; it is the audit trail of the interrupt"

# ---- 6. recovery: a fresh run finishes the job -----------------------------
echo "  .. recovery run (${FILE_COUNT} files)"
run_script_env "$SBX" "STUB_FLAC_SLEEP=0.05" -- '4' 'REENCODE ALL' ''
occur_re "Processing $FILE_COUNT file\\(s\\) with $JOBS worker\\(s\\)"
[ "$(captured_count 'Failed reencodes: ([0-9]+)')" -eq 0 ] \
    || _fail "the recovery run reported failures"
[ "$(captured_count 'Successful reencodes: ([0-9]+)')" -eq "$FILE_COUNT" ] \
    || _fail "the recovery run did not reencode all $FILE_COUNT files"
# Every file is the reencoded marker now, and every original is in the backup root.
for i in $(seq 1 "$FILE_COUNT"); do
    file_eq "$LIB/Album/track$i.flac" 'REENCODE_OK' \
        || _fail "recovery: track$i was not reencoded"
    file_eq "$BAKROOT/Album/track$i.flac" "orig-$i" \
        || _fail "recovery: missing/wrong backup for track$i"
done
[ "$(count_find "$LIB" -name '*.part')" -eq 0 ] \
    || _fail "the recovery run left .part temp(s) behind"

echo "ok: case_interrupt (SIGTERM to the parent alone: workers killed, artifacts swept, library recovers)"
