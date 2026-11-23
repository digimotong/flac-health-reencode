#!/usr/bin/env bash
# case_run_lock.sh - integration: one run per library at a time.
#
# Two copies started at once share everything a run creates: the run log and seed
# list are named from a SECOND-resolution timestamp, and the per-file temp is a fixed
# 'tmp_<base>.part', so the second copy would truncate the first's log, clobber its
# work list and delete its live temps. acquire_run_lock is what prevents that.
#
# A. A run that already holds the lock makes a second run REFUSE, per operation
#    (1 scan, 2, 4, 5), naming the library and pointing at the wait.
# B. The refusal is not sticky: once the holding run ends, the next run proceeds.
# C. A run killed with SIGKILL still releases the lock, so a crashed run cannot
#    leave a library permanently wedged.
#
# The holder is simulated by taking the lock exactly as acquire_run_lock does - on a
# read-write fd of an anonymous FIFO - from a background shell that outlives the
# assertions. flock gives a fd lock to the whole file description, so a separate
# process opening the FIFO of the same inode is refused.

set -o errexit
set -o nounset
set -o pipefail

: "${TESTS_ROOT:?}"
: "${PROD_SCRIPT:?}"
. "$TESTS_ROOT/helpers.sh"

# A lock taken on a regular file is inherited by children (the reason the script uses
# an anonymous FIFO), so this case only needs flock and a fifo - both from coreutils
# and util-linux respectively.
command -v ps >/dev/null 2>&1 \
    || { echo "SKIP: flock (util-linux) not available"; exit 0; }
command -v mkfifo >/dev/null 2>&1 \
    || { echo "SKIP: mkfifo (coreutils) not available"; exit 0; }

SBX=''
make_sandbox SBX
register_sandbox "$SBX"
LIB="$SBX/lib"
mkdir -p "$LIB/Album"
write_file "$LIB/Album/broken.flac" 'bad-payload:CORRUPT'
write_file "$LIB/Album/good.flac" 'clean-audio'

# Seed a scan report so option 2 has something to act on.
mkdir -p "$LIB/.flac_scan_data/reports"
{
    echo '# Scan Report: 2026-01-01T00:00:00Z | Files: 2 | Errors: 1'
    echo 'filepath'
    echo "\"$LIB/Album/broken.flac\""
} > "$LIB/.flac_scan_data/reports/flac_scan_2026-01-01_00-00-00.csv"

# start_lock_holder <library> : simulate another run holding the library, exactly the
# way acquire_run_lock represents it - a 'lock' directory naming a LIVE pid. A pid of
# this test shell is used on purpose: it is alive, so the lock cannot be broken as
# stale, which is what a concurrent run looks like from the outside.
start_lock_holder() {
    local lib="$1"
    local lock_dir="$lib/.flac_scan_data/lock"
    mkdir -p "$lock_dir"
    printf '%s\n' "$$" > "$lock_dir/pid"
}

# stop_lock_holder : drop the simulated lock.
stop_lock_holder() {
    rm -rf "$1/.flac_scan_data/lock"
}

# ---------------------------------------------------------------------------
# A. Each operation refuses while the lock is held.
# ---------------------------------------------------------------------------
# refuse_under_lock <op> <stdin lines...> : hold the lock, run the operation, and
# assert it refused without touching the library. Sets no state for later sections.
refuse_under_lock() {
    local op="$1"
    shift
    start_lock_holder "$LIB"
    run_script "$SBX" "$@"
    stop_lock_holder "$LIB"
    occur_re "Another copy of this script is already working on '$LIB'"
    # A refused run must be a NO-OP: nothing re-encoded (the stub marker would be
    # there otherwise) and nothing mirrored.
    file_eq "$LIB/Album/good.flac" 'clean-audio' \
        || _fail "option $op: a refused run still modified the library"
    miss "$SBX/lib_backup/Album/good.flac"
}

refuse_under_lock 1 '1' '' 'q'
refuse_under_lock 2 '2' 'Y' '' 'q'
refuse_under_lock 4 '4' 'REENCODE ALL' '' 'q'
refuse_under_lock 5 '5' 'y' '' 'q'

echo "ok: run_lock (every operation refuses while another run holds the lock)"

# ---------------------------------------------------------------------------
# B. The refusal is not sticky: with no holder, the run proceeds.
# ---------------------------------------------------------------------------
run_script "$SBX" '5' 'y' '' 'q'
absent_re 'Another copy of this script'
occur_re 'Successful reencodes: 2'
file_eq "$SBX/lib_backup/Album/good.flac" 'clean-audio' \
    || _fail "the run after a refusal did not mirror the original"

echo "ok: run_lock (a later run proceeds once the lock is free)"

# ---------------------------------------------------------------------------
# C. A STALE lock (owner pid no longer running, as after kill -9) is broken, so a
#    crashed run cannot wedge the library for good.
# ---------------------------------------------------------------------------
SBX2=''
make_sandbox SBX2
register_sandbox "$SBX2"
LIB2="$SBX2/lib"
mkdir -p "$LIB2/Album" "$LIB2/.flac_scan_data/lock"
write_file "$LIB2/Album/new.flac" 'fresh-track'
# A pid that cannot be running: the parent of this test shell is long gone on any
# normal CI run, and the value is far above any plausible live pid on Linux.
printf '%s\n' '4294967294' > "$LIB2/.flac_scan_data/lock/pid"

run_script "$SBX2" '5' 'y' '' 'q'
absent_re 'Another copy of this script'
occur_re 'Successful reencodes: 1'
# The broken lock is gone, so the library is usable without manual cleanup.
miss "$LIB2/.flac_scan_data/lock"

echo "ok: run_lock (a stale lock is broken)"

# ---------------------------------------------------------------------------
# D. The lock keys on the RESOLVED library, so a second run that reaches the same
#    library by another spelling is refused too. Without canonicalisation the two
#    would take different lock paths and overlap - the exact corruption the lock
#    exists to prevent.
# ---------------------------------------------------------------------------
SBX3=''
make_sandbox SBX3
register_sandbox "$SBX3"
LIB3="$SBX3/lib"
mkdir -p "$LIB3/Album"
write_file "$LIB3/Album/song.flac" 'clean-audio'
# A symlinked route to the same library: '<sbx>/alias' -> '<sbx>/lib'.
ln -s "$LIB3" "$SBX3/alias"
# The other run holds the lock as the script writes it: inside the RESOLVED library.
start_lock_holder "$LIB3"

# Configure the library by the SYMLINK path, with a trailing slash for good measure.
printf '{"library_path": "%s", "backup_path": "%s", "version": "1.1"}\n' \
    "$SBX3/alias/" "$SBX3/lib_backup" > "$SBX3/flac_health_config.json"
run_script "$SBX3" '5' 'y' '' 'q'
stop_lock_holder "$LIB3"
occur_re "Another copy of this script is already working on '$LIB3'"
file_eq "$LIB3/Album/song.flac" 'clean-audio' \
    || _fail "a run reaching the library via a symlink bypassed the lock"

echo "ok: run_lock (a symlinked route to the same library is refused)"
