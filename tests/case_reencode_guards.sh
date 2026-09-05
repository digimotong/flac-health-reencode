#!/usr/bin/env bash
###############################################################################
# case_reencode_guards.sh - integration: temp-file naming, backup preservation
# and graceful menu return on error paths.
#
# A. Temp-file guard (F1): a leftover reencode temp named 'tmp_<...>.part'
#    (the post-fix temp extension) sitting in a real album dir is NOT library
#    content -- a scan neither counts it nor flags it, even though its bytes
#    contain the CORRUPT marker (a real *.flac with those bytes would be
#    reported). This proves the temp naming keeps interrupted-run leftovers out
#    of scans / reencode-NEW discovery.
# B. Backup-preservation guard (F3): re-encoding the SAME file twice (as a
#    re-run over the same CSV would) must NOT overwrite the original backup --
#    the pristine first-reencode backup bytes survive the re-run.
# C. Graceful-return guard (F4): choosing an option whose library path no
#    longer exists returns to the main menu instead of hard-exiting the script.
# D. Stale-residue guard (F1): a leftover 'tmp_*.part' from an interrupted run
#    (which makes real flac's -o write refuse with "output file ... already
#    exists") is cleared by the script before re-encoding, so a resumed full
#    pass succeeds and leaves no residue to trip the run after it.
###############################################################################

set -o errexit
set -o nounset
set -o pipefail

: "${TESTS_ROOT:?}"
: "${PROD_SCRIPT:?}"
. "$TESTS_ROOT/helpers.sh"

# The single immutable text line of our main-menu banner (printed on every loop
# iteration), used to detect that control returned to the menu rather than exiting.
MENU_TITLE='FLAC Health Check & Reencode Script'

# ===========================================================================
# A. Temp-file naming keeps leftover/live temps invisible to a scan.
# ===========================================================================
SBX=''
make_sandbox SBX
register_sandbox "$SBX"
LIB="$SBX/lib"
mkdir -p "$LIB/Album"

write_file "$LIB/Album/good.flac"              'clean-audio'
# A leftover reencode temp from a hypothetical interrupted run. Post-fix it is
# named '*.part' (NOT '*.flac'), so even though it is corrupt-looking it must
# never be discovered as library content.
write_file "$LIB/Album/tmp_song.flac.part"     'partial:CORRUPT'

run_script "$SBX" '1' ''

occur_re 'No errors found'
occur_re 'Found 1 FLAC files to scan'
# The corrupt-looking temp is never counted nor flagged:
absent_re 'Error detected in:.*tmp_song\\.flac\\.part'
# And a scan leaves no CSV (nothing was wrong), so it is not in any report.
[ -z "$(find "$LIB/.flac_scan_data/reports" -name 'flac_scan_*.csv' 2>/dev/null)" ] \
    || _fail "a scan that saw only a .part temp produced an error CSV"

echo "ok: reencode_guards (temp .part invisible to scan)"

# ===========================================================================
# B. Re-encoding the same file twice must preserve the original backup.
# ===========================================================================
SBX2=''
make_sandbox SBX2
register_sandbox "$SBX2"
LIB2="$SBX2/lib"
mkdir -p "$LIB2/Albums"
write_file "$LIB2/Albums/song.flac" 'PRIMAL-ORIGINAL'

# First reencode: scan it (clean), then reencode via option 6 (new-file set).
run_script "$SBX2" '6' 'y' ''
# song.flac was reencoded -> now holds the stub marker; a backup now exists.
BACKUP2="$LIB2/Albums/backup_FLAC_originals/song.flac"
exist "$BACKUP2"
file_eq "$BACKUP2" 'PRIMAL-ORIGINAL'   # first backup = pristine original
file_eq "$LIB2/Albums/song.flac" "$RE_MARKER"

# Second reencode of the very same file (simulates a re-run: the file is no
# longer 'new' only because option 5 reencodes everything, so use the full
# pass). The re-run must NOT clobber the FIRST backup with the reencoded bytes.
run_script "$SBX2" '5' 'REENCODE ALL' ''
file_eq "$BACKUP2" 'PRIMAL-ORIGINAL'   # STILL the pristine original
file_eq "$LIB2/Albums/song.flac" "$RE_MARKER"

echo "ok: reencode_guards (re-run preserves original backup)"

# ===========================================================================
# C. A missing library path returns to the menu (no hard exit).
# ===========================================================================
SBX3=''
make_sandbox SBX3
register_sandbox "$SBX3"
LIB3="$SBX3/lib"
# Point the sandbox config at a path that does not exist, then pick option 1.
printf '{"library_path": "%s"}\n' "$LIB3/no-such-dir" > "$SBX3/flac_health_config.json"

run_script "$SBX3" '1' '' ''

# Option 1 printed the error, consumed "Press Enter to return to main menu",
# and control came back to the main-menu loop (the banner is drawn AGAIN)
# instead of hard-exiting the whole script on the missing directory.
occur_re "The directory '$LIB3/no-such-dir' does not exist"
occur_re "$MENU_TITLE"
# The banner appears at least twice: once at launch and once after the option
# returned to the menu loop. A hard exit would have shown it only once.
[ "$(message_count "$MENU_TITLE")" -ge 2 ] \
    || _fail "main menu was not redrawn after the error return (script hard-exited?)"

echo "ok: reencode_guards (missing path returns to menu)"

# ===========================================================================
# D. Stale-residue guard (F1): a leftover 'tmp_*.part' from an interrupted run
#    blocks a re-encode unless the script clears it first.
#
#    REAL flac (invoked without -f) refuses to write when its -o target already
#    exists. On a full option-5 pass over 27k files the user hit exactly that:
#    a stale 'tmp_...part' after a previous interrupted run made flac error
#    "output file ... already exists". This guard plants a sandbox-local flac
#    stub that reproduces that refusal, pre-seeds the same stale residue, and
#    verifies the script's pre-delete lets the re-encode proceed -- and that no
#    residue remains afterward to trip the NEXT run.
# ===========================================================================
SBX4=''
make_sandbox SBX4
register_sandbox "$SBX4"
LIB4="$SBX4/lib"
mkdir -p "$LIB4/Album"

# Plant a REAL-flac-like overwrite-refusing stub in this sandbox only.
cat > "$SBX4/bin/flac" <<'FLAC'
#!/usr/bin/env bash
prev=''; out=''
for a in "$@"; do [ "$prev" = '-o' ] && out="$a"; prev="$a"; done
if [ -z "$out" ]; then echo "stub needs -o" >&2; exit 1; fi
if [ -e "$out" ]; then
    echo "ERROR: output file $out already exists, use -f to override" >&2
    exit 1
fi
printf 'REENCODE_OK\n' > "$out"
exit 0
FLAC
chmod +x "$SBX4/bin/flac"

write_file "$LIB4/Album/track.flac"         'PRIMAL-ORIGINAL'
# The exact residue from the user's interrupted full re-encode: a pre-existing
# temp the script itself created on a prior (aborted) pass.
write_file "$LIB4/Album/tmp_track.flac.part" 'pristine-debris-CORRUPT'

# Option 5 = full re-encode of every *.flac in the library.
run_script "$SBX4" '5' 'REENCODE ALL' ''

# The stale .part must have been cleared BEFORE flac (no "already exists" error)
# and the re-encode must have replaced the track with the stub marker.
absent_re 'already exists'
file_eq "$LIB4/Album/track.flac" "$RE_MARKER"
# The temp was consumed by the successful mv -- nothing left to trip a future run.
find_result="$(find "$LIB4/Album" -name 'tmp_*' -print)"
[ -z "$find_result" ] || _fail "residue remains after successful re-encode: $find_result"

echo "ok: reencode_guards (stale .part cleared before re-encode)"

