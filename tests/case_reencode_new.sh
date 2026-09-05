#!/usr/bin/env bash
###############################################################################
# case_reencode_new.sh - integration: option 6 (NEW FLAC files only)
#
# Three sequential menu runs in ONE library demonstrate incremental behaviour:
#   run 1  : empty tracking DB  -> both known real files are "new", re-encoded,
#            each written to reencoded.db, internal .flac_scan_data excluded.
#   run 2  : no changes         -> "All N FLAC files have already been
#            reencoded"; nothing is reprocessed, DB unchanged.
#   run 3  : a brand-new real file (with a different payload, hence a different
#            fingerprint) is added -> exactly it is discovered as new and
#            re-encoded (DB grows by one, nothing else is touched).
###############################################################################

set -o errexit
set -o nounset
set -o pipefail

: "${TESTS_ROOT:?}"
: "${PROD_SCRIPT:?}"
. "$TESTS_ROOT/helpers.sh"

SBX=''
make_sandbox SBX
register_sandbox "$SBX"
LIB="$SBX/lib"
DB="$LIB/.flac_scan_data/reencoded.db"

R1="$LIB/Album/r1.flac"
R2="$LIB/Album/r2.flac"
mkdir -p "$LIB/Album"
write_file "$R1" 'song-alpha-content'      # distinct fingerprint
write_file "$R2" 'song-beta-content-002'   # distinct fingerprint
mkdir -p "$LIB/.flac_scan_data"
write_file "$LIB/.flac_scan_data/hidden.flac" 'DO-NOT-COUNT'

# ---- run 1: first-ever NEW pass re-encodes both real files -------------------
run_script "$SBX" '6' 'y' ''
occur_re 'never been reencoded \(0 entry/entries in'
occur_re 'Found 2 new FLAC file\(s\).*never been reencoded'
[ "$(captured_count 'New files found: ([0-9]+)')" -eq 2 ] || _fail "new run1: reported != 2"
file_eq "$R1" 'REENCODE_OK'
file_eq "$R2" 'REENCODE_OK'
file_eq "$LIB/.flac_scan_data/hidden.flac" 'DO-NOT-COUNT'
[ "$(wc -l < "$DB")" -eq 2 ] || _fail "run1 db should have 2 rows"
db_has_path "$SBX" "$R1"
db_has_path "$SBX" "$R2"

# ---- run 2: nothing new -> no-op, DB unchanged -------------------------------
run_script "$SBX" '6' ''
occur_re 'All 2 FLAC files have already been reencoded'
absent_re 'Starting reencode of .* new FLAC file'
file_eq "$R1" 'REENCODE_OK'
file_eq "$R2" 'REENCODE_OK'
[ "$(wc -l < "$DB")" -eq 2 ] || _fail "run2 db grew unexpectedly (no-op)"

# ---- run 3: add one brand-new real file --------------------------------------
R3="$LIB/Album New/added later.flac"
mkdir -p "$LIB/Album New"
write_file "$R3" 'completely-fresh-track-xyz'
# also add a redundant copy under a backup dir to prove NEW ignores backups
mkdir -p "$LIB/Album/backup_FLAC_originals"
write_file "$LIB/Album/backup_FLAC_originals/junk.flac" 'note-a-backup-copy-usually-present'

run_script "$SBX" '6' 'y' ''
occur_re 'Found 1 new FLAC file\(s\) out of 3 total'
[ "$(captured_count 'New files found: ([0-9]+)')" -eq 1 ] || _fail "new run3 reported != 1"

# Still the ORIGINAL 2 unchanged, and the fresh one is now re-encoded; the
# backup copy added above was NOT consumed by option 6.
file_eq "$R1" 'REENCODE_OK'
file_eq "$R2" 'REENCODE_OK'
file_eq "$LIB/Album New/added later.flac" 'REENCODE_OK'
file_eq "$LIB/Album/backup_FLAC_originals/junk.flac" 'note-a-backup-copy-usually-present'
[ "$(wc -l < "$DB")" -eq 3 ] || _fail "db should now hold 3 rows"
db_has_path "$SBX" "$R3"

echo "ok: case_reencode_new"
