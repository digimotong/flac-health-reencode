#!/usr/bin/env bash
###############################################################################
# case_reencode_all.sh - integration: option 4 (Reencode ALL FLAC files)
#
# Verifies the full-library reencode:
#   * the pre-warning reports the real-file count (3 real; the pre-existing
#     backup copy + internal .flac_scan_data file are excluded and require
#     'REENCODE ALL' confirmation),
#   * the warning names the backup directory the originals will be mirrored
#     into,
#   * every REAL .flac is re-encoded (replaced by the stub marker) exactly
#     once and recorded in reencoded.db,
#   * each original is mirrored into the backup root OUTSIDE the library at its
#     album-relative path,
#   * pre-existing legacy in-library backup copies and internal .flac_scan_data
#     files are never processed (they hold original bytes, and never the
#     reencode marker) and never copied into the backup root.
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

# 2 real FLACs spread across a nested album.
R1="$LIB/Album One/trackA.flac"
R2="$LIB/Album One/sub/trackB.flac"
R3="$LIB/Album Two/trackC.flac"
mkdir -p "$LIB/Album One/sub" "$LIB/Album Two" "$LIB/Album One/sub/backup_FLAC_originals"
write_file "$R1" 'orig-A'
write_file "$R2" 'orig-B'
write_file "$R3" 'orig-C'
# A real file that ALREADY has a LEGACY in-library backup snapshot:
#   (backup copy is at Album One/sub/backup_FLAC_originals/trackB.flac)
write_file "$LIB/Album One/sub/backup_FLAC_originals/trackB.flac" 'orig-B'
# An internal FLAC the scan must exclude:
mkdir -p "$LIB/.flac_scan_data"
write_file "$LIB/.flac_scan_data/metrics.flac" 'IGNORED'

run_script "$SBX" '4' 'REENCODE ALL' ''

# Count = 3 real, never the backup/internal.
occur_re "You are about to reencode ALL 3 FLAC files"
occur_re 'Starting reencode of all 3 FLAC files'
# The warning names the backup root the originals are mirrored into.
occur_re "$SBX/lib_backup"
[ "$(captured_count 'Successful reencodes: ([0-9]+)')" -eq 3 ] || _fail "all: successes != 3"
[ "$(captured_count 'Failed reencodes: ([0-9]+)')" -eq 0 ]    || _fail "all: failures != 0"
[ "$(message_count 'SUCCESS:')" -eq 3 ]                       || _fail "expected exactly 3 SUCCESS lines"

# Regression (progress-bar/output collision): success/status text must never be
# emitted on the same row as the \r-based progress bar, which glued output like
# "Failed: 0SUCCESS:". Captured stdout (redirected) must therefore contain no
# carriage-return byte, and every SUCCESS line must start cleanly on its own row.
if LC_ALL=C grep -q $'\r' "$CURRENT_OUT"; then
    _fail "captured output contains carriage-return bytes (progress glue)"
fi
if grep -qE 'Failed: [0-9]+SUCCESS:' "$CURRENT_OUT"; then
    _fail "SUCCESS text glued onto the progress line"
fi

# Every real file was replaced by the stub reencode marker ...
file_eq "$R1" 'REENCODE_OK'
file_eq "$R2" 'REENCODE_OK'
file_eq "$R3" 'REENCODE_OK'
# ... and each original was mirrored into the backup root at its library-relative
# path, holding the pre-reencode bytes ...
BAK="$SBX/lib_backup"
file_eq "$BAK/Album One/trackA.flac"     'orig-A'
file_eq "$BAK/Album One/sub/trackB.flac" 'orig-B'
file_eq "$BAK/Album Two/trackC.flac"     'orig-C'
# ... while the LEGACY in-library backup was neither touched nor promoted into
# the new backup tree, and the internal file was untouched.
file_eq "$LIB/Album One/sub/backup_FLAC_originals/trackB.flac" 'orig-B'
file_eq "$LIB/.flac_scan_data/metrics.flac" 'IGNORED'
miss "$BAK/Album One/sub/backup_FLAC_originals"
[ "$(find "$BAK" -type f | wc -l)" -eq 3 ] || _fail "backup root should hold exactly the 3 mirrored originals"

# DB records exactly the 3 real files; no backup / internal path ever appears.
DB="$LIB/.flac_scan_data/reencoded.db"
[ "$(wc -l < "$DB")" -eq 3 ]   || _fail "expected exactly 3 db rows, got $(wc -l < "$DB")"
db_has_path "$SBX" "$LIB/Album One/trackA.flac"
db_has_path "$SBX" "$LIB/Album One/sub/trackB.flac"
db_has_path "$SBX" "$LIB/Album Two/trackC.flac"
! grep -Fq 'backup_FLAC_originals' "$DB" || _fail "db mentions a backup path"
! grep -Fq '.flac_scan_data' "$DB"       || _fail "db mentions an internal path"

echo "ok: case_reencode_all"
