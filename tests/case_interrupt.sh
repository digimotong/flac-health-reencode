#!/usr/bin/env bash
# case_interrupt.sh - integration: a pooled run interrupted by a signal cleans up.
#
# WHY THIS CASE EXISTS (and why the stub suite could not skip it):
#   _pool_interrupt_cleanup exists for the signal a terminal Ctrl-C does NOT cover.
#   Ctrl-C signals the whole foreground process group, so the workers and their
#   'flac' children die on their own and the handler is never really needed. A
#   `kill -TERM <pid>`, a `systemctl stop` or a `pkill` signals ONLY the parent
#   shell; without the handler the workers keep running, keep holding shards, and
#   keep rewriting audio after the user believes the run stopped.
#
#   Until now that behaviour was covered ONLY by tests/manual/real_flac_resilience.sh
#   scenario A, which is NOT a required check (it needs real flac/metaflac and apt).
#   So the strongest user-visible guarantee in this branch was protected by a job
#   that can be ignored. This case moves the same contract into the REQUIRED suite.
#
# WHAT IS ASSERTED (the parent is signalled, never its process group):
#   1. the handler runs: 'Interrupted (signal N)' reaches the output;
#   2. the parent exits 128+signo (143 for TERM), not a stale 0;
#   3. the workers are KILLED promptly, not merely left to finish: the parent is
#      signalled in its own session (setsid), so the signal cannot reach a worker by
#      process-group membership, and the live-process count is sampled from the
#      handler's diagnostic onwards - a handler that stops killing them shows up as
#      ~12 busy samples instead of 1-2;
#   4. this run's artifacts are gone: in-library .part temps, the shard directory,
#      the dispatch index, the temp manifest and the seed work list;
#   5. the partial run log is KEPT - it is the audit trail of what the interrupt
#      cut short, and the handler documents that on purpose;
#   6. recovery: a fresh run over the same library completes with no failures,
#      which is the property that actually matters afterwards. The interrupted run
#      may have replaced audio whose DB row only ever reached a shard, so the DB is
#      allowed to be short here - the script documents that an interrupted parallel
#      run can leave files with no DB row, and option 5 then re-reencodes them
#      (safe: an existing backup is never overwritten).
#
# Signal choice: TERM (15). INT is the terminal's job-control signal and is the one
# a Ctrl-C delivers to the whole group anyway, so TERM is the case that proves the
# handler is not merely leaning on group delivery. A HUP/INT regression would still
# be caught, since all three share one registration.

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
# Sampling cadence for the survivor check. The stub reencode is held for STUB_SLEEP, so a
# handler that fails to kill the workers leaves them running for the rest of that sleep
# (~2.5s after the signal). The sampler below samples this often and stops at the first
# quiet instant, so a healthy run records 1-2 samples and a leak records ~12: the gap is
# what the assertion in section 3 turns into a pass/fail decision.
SAMPLE_INTERVAL=0.2
# Time to let the pool fork its workers and get them into the stub sleep. Kept
# short so this case stays well inside the suite's per-case ceiling.
PRE_SIGNAL_WAIT=1.5

# The bound that turns the survivor series into a pass/fail decision, derived from the leak
# it must separate so the two cannot drift apart when STUB_SLEEP changes. It is defined here,
# after all three of its inputs, because `set -u` (nounset) applies to this file.
#
# The leak is the rest of the stub's hold AFTER the signal lands, i.e.
# (STUB_SLEEP - PRE_SIGNAL_WAIT) = 2.5s here, which the mutation test measured as 13 samples
# at a 0.2s cadence. The bound is 2/5 of that leak -> 5 samples (~1.0s of busy time), so a
# healthy run (1-2 samples) has ~3 samples of headroom while a leak overshoots by ~2.6x.
# The measured series is echoed on success at the end of section 3, so the margin is a
# number in the log rather than a claim in a comment.
#
# Integer-only arithmetic (bash has no floats): both sides are scaled to milliseconds
# (leak window *1000; interval split at the dot into whole seconds *1000 + a 3-digit
# fraction), so 2500ms and a 200ms cadence divide to 12 samples, times 2/5 -> 4, rounded
# up to the 5 above. A non-numeric interval, or a leak window of zero or less, would divide
# by zero inside $(( )) under `set -e` and abort the case before its sampler ever ran, so
# those fall back to the default explicitly.
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
# pins 'jobs' to 1 for the sequential-anchor cases (see make_sandbox), and each
# parallelism case owns its degree, so the override lives here as it does in
# case_parallel.sh.
set_jobs() {
    printf '{"library_path": "%s", "backup_path": "%s", "version": "1.1", "jobs": %s}\n' \
        "$LIB" "$BAKROOT" "$1" > "$SBX/flac_health_config.json"
}
set_jobs "$JOBS"

# start_pooled <sbx> <out> : begin a jobs=4 option-4 run in the background with the
#   stub reencode held open, and set RUN_PID to the script's PID.
#
# WHY setsid AND WHY IT IS THE WHOLE POINT OF THIS CASE:
#   A plain `cmd &` in a non-interactive shell does NOT get its own process group -
#   the workers inherit THIS shell's PGID. Signalling the script would then take the
#   workers down as a side effect of group delivery, and the case would pass even
#   with _pool_interrupt_cleanup's kills deleted, i.e. it would measure bash's job
#   control instead of the product. (Measured: script+4 workers in one session ->
#   killing the parent leaves 9 survivors; worker deaths come from the handler.)
#   setsid puts the script in a NEW session, so the ONLY way a worker can receive
#   the signal is from the handler that exists to send it. `--wait` makes the
#   background job stay alive until the script exits, so `wait` below still works.
#
# setsid is util-linux, not coreutils, so its absence is reported as SKIP (the
# established convention in run_tests.sh and the manual harness) rather than as a
# failure of the product.
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
#   guarded here rather than being left to trip this case's errexit (the same trap
#   the residue checks below avoid).
no_procs() {
    local n=0
    while IFS= read -r _line; do n=$((n + 1)); done \
        < <(pgrep -f "$1" 2>/dev/null || true)
    echo "$n"
}

# count_find <dir> [find args...] : number of matches, 0 when the dir is absent.
#   Defined here as in case_parallel.sh (helpers.sh has no equivalent): a missing
#   directory means the run cleaned up MORE than expected - a pass - so it reports 0
#   instead of aborting, because under errexit + pipefail a bare `find <missing dir>`
#   exits 1 and pipefail would propagate that and end the case.
count_find() {
    local dir="$1"; shift
    [ -d "$dir" ] || { echo 0; return 0; }
    find "$dir" "$@" 2>/dev/null | wc -l
}

# setsid is what makes this case able to tell a working handler from a missing one
# (see start_pooled). Without it the signal reaches the workers via process-group
# membership and the case would pass regardless, so SKIP rather than a false PASS.
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

# Sanity-check the construction this case depends on: the workers must NOT be in
# our process group, or the signal below would reach them directly and the process
# assertion would be vacuous. Assert the property rather than trusting setsid.
# Every command here is guarded: `grep -c` exits 1 on a zero count and `grep -qv`
# exits 1 when nothing matches - both are the answers we WANT, and under this case's
# errexit an unguarded one would silently end the case with no diagnostic.
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
# early (nothing to clean up) or the pool never forked, and the assertions below
# would be vacuous rather than failing.
[ -n "$worker_pgids" ] \
    || _fail "no workers were running when the signal was about to be sent; the interrupt would prove nothing (output:
$(tail -5 "$INTERRUPT_OUT"))"

# Start the survivor sampler BEFORE the signal, so it observes the whole window in
# which a non-killed worker would still be running. It writes the number of
# sandbox processes it sees, once per SAMPLE_INTERVAL, and is read after the parent
# has exited.
#
# WHY SAMPLING INSTEAD OF ONE CHECK AFTER `wait`: the parent's interrupt path is a
# graceful drain (the dispatch loop's poll gate makes TERM flag a shutdown, so the
# parent does not exit until its in-flight workers report). Measured with the worker
# kills removed: all 9 processes are STILL ALIVE at every sample while the parent is
# alive, and only vanish once the parent exits - so a check placed after `wait` sees
# zero even on the leak. Timing the sampler to overlap the drain is what makes this
# assertion able to tell the two cases apart.
SAMPLE_FILE="$SBX/survivors.samples"
: > "$SAMPLE_FILE"
# The sampler starts RECORDING at the handler's diagnostic ('Interrupted (signal N):
# stopping workers...') because samples taken before it legitimately see the parent plus
# every worker the pool is meant to be running - those are not leaks.
#
# It then records until it observes a quiet (zero-process) instant, or until a generous
# bound expires, whichever comes first. Two earlier designs were wrong and are recorded
# here because the reasoning is not obvious:
#   * one check after `wait` sees zero even on a leak: the interrupt path is a graceful
#     drain, and the orphaned workers die the moment the parent exits;
#   * a sampler killed as soon as `wait` returned could record a single non-quiet sample
#     on a HEALTHY run (the parent exits within the same tick as its diagnostic), which
#     fails a correct script.
# Self-terminating on the first quiet instant avoids both: the recorded series shows how
# long the sandbox stayed busy AFTER the handler announced itself, which is exactly the
# interval a missing kill turns into the stub's remaining sleep (~2.5s at 0.2s sampling
# = ~12 samples, versus 0-1 for a working handler).
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

# The sampler is deliberately NOT stopped here. It is self-terminating (it exits on its
# first quiet sample) and its bound is small, so waiting for it is both short and the
# only way to observe the moment the orphans of a broken handler disappear - which is
# after the parent has exited. Killing it at this point instead would freeze the series
# at a single non-quiet sample on a healthy run, failing a correct script.
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
# THE CORE ASSERTION. The sampler records the number of live sandbox processes once per
# SAMPLE_INTERVAL, starting at the handler's diagnostic, and stops at the first quiet
# instant. So the LENGTH of that series is how long the sandbox stayed busy after the
# handler announced it was stopping the workers:
#   * a working handler kills them within a sample or two;
#   * a handler that does not kill them leaves them running for the rest of the stub's
#     sleep: STUB_SLEEP=4 with the signal at PRE_SIGNAL_WAIT=1.5 leaves 2.5s, which the
#     mutation test below measured as 13 samples.
# The bound below is MAX_BUSY_SAMPLES, derived from that same 2.5s leak (see its definition
# at the top), so it sits far from both - and the series is echoed at the end of this
# section whether it passes or fails, so the margin is a measured number in the log rather
# than a claim in a comment, and a near-miss is diagnosable either way.
#
# MUTATION-TESTED (each mutant applied to the production script, this case re-run):
#   * both worker kills neutered  -> CAUGHT ("stayed busy for 13 samples"); the leak is
#     visible precisely BECAUSE the handler's `trap '' INT TERM HUP` stops the workers
#     from reacting to the propagated signal, so they must be killed explicitly;
#   * the re-entrancy disarm removed on its own -> SURVIVES, and correctly so: it disables
#     no kill, and with no second signal arriving it has no observable effect. Recorded
#     here so a future reader does not mistake it for a hole in this case;
#   * the earlier, single-post-`wait` check that this replaced did NOT catch the killed-kill
#     mutant at all - hence the sampling.
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
# The measured margin, on SUCCESS as well as failure: how long the sandbox stayed busy
# after the handler's diagnostic, against the bound. A healthy run is 1-2 of 5; a numeric
# value approaching the bound is the early warning a pass/fail bit cannot give.
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
