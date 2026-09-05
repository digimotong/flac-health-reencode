#!/usr/bin/env bash
###############################################################################
# case_reencode_csv.sh - integration: option 2 (problematic list from a CSV)
#
# Pre-seeds TWO scan CSVs -- one stale, one NEWEST manual list. The manual list
# deliberately mixes valid rows with rows the script must IGNORE: the '# Scan
# Report...' comment, the 'filepath' header, a backup copy, and an internal
# .flac_scan_data file. Only the single real "problematic" file is reencoded:
#   * the manual (newest) CSV is chosen, not the stale one
#   * count line reflects the 1 real row
#   * the real file is backed up and replaced with reencoded content
#   * backup + internal files stay untouched (never re-encoded, no db rows)
#   * the reencoded real file is recorded in reencoded.db
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

REAL="$LIB/Album Big/worst.flac"                 # the one "problematic" real file
BADBAK="$LIB/Album Big/backup_FLAC_originals/w2.flac"
INTFILE="$LIB/.flac_scan_data/reports/x.flac"
# Base dirs; ".flac_scan_data/" is created by the nested mkdir (its parent is the
# library root): we place real albums, one backup dir, and a pre-existing report
# that doubles as the "internal file candidate" location.
mkdir -p "$LIB/Album Big/backup_FLAC_originals" "$LIB/Album Big2" "$LIB/.flac_scan_data/reports"

write_file "$REAL"   'orig-worst-bytes'
write_file "$BADBAK" 'orig-w2-bytes'
write_file "$INTFILE" 'orig-x-bytes'
write_file "$LIB/Album Big2/other.flac" 'original-other'

# Stale CSV (older mtime).
RPT="$LIB/.flac_scan_data/reports"
sleep 0.01   # ensure a distinct mtime ordering is unnecessary: sort is by mtime, so order creation below
printf '# Scan Report: stale\nfilepath\n"%s"\n' "$LIB/Album Big2/other.flac" > "$RPT/flac_scan_2020-01-01_00-00-00.csv"
sleep 0.02

# Newest manually-authored scan list: comment + header + REAL + backup + internal.
MANUAL="$RPT/flac_scan_manual.csv"
{
    printf '# Scan Report: 2026 | Files: 5 | Errors: 4\n'
    printf 'filepath\n'
    printf '"%s"\n' "$REAL"
    printf '"%s"\n' "$BADBAK"
    printf '"%s"\n' "$INTFILE"
} > "$MANUAL"

run_script "$SBX" '2' 'Y' ''

occur_re 'Latest scan CSV file found:.*flac_scan_manual\.csv'
occur_re "Processing file: $REAL"
occur_re 'SUCCESS:.*worst\.flac reencoded successfully'

# Count lines (tee'd + printed to stdout): exactly 1 processed.
[ "$(captured_count 'Total files processed: ([0-9]+)')"  -eq 1 ] || _fail "option2 total != 1"
[ "$(captured_count 'Successful reencodes: ([0-9]+)')"    -eq 1 ] || _fail "option2 success != 1"
[ "$(captured_count 'Failed reencodes: ([0-9]+)')"        -eq 0 ] || _fail "option2 fail != 0"
# Two rows (backup + internal) were skipped via the internal/backup filter.
[ "$(message_count 'Skipping internal/backup path:')"     -eq 2 ] || _fail "expected exactly 2 internal-skip messages"

# State: the real file was replaced by the stub's reencode marker...
file_eq "$REAL" 'REENCODE_OK' || {
    echo "   (content after run: '$(cat "$REAL" 2>/dev/null)')" >&2
    _fail "real file was not replaced by reencode marker"
}
# ...its backup holds the ORIGINAL bytes (never the marker)...
file_eq "$LIB/Album Big/backup_FLAC_originals/worst.flac" 'orig-worst-bytes' \
  || _fail "backup of real file does not preserve the original"
# ...and the OTHER real file (stale CSV's target) was NOT re-encoded.
file_eq "$LIB/Album Big2/other.flac" 'original-other' || _fail "stale-CSV file was re-encoded (manual CSV should win)"

# Backup + internal sources remain byte-identical (never re-encoded).
file_eq "$BADBAK"  'orig-w2-bytes'  || _fail "backup file was re-encoded/overwritten"
file_eq "$INTFILE" 'orig-x-bytes'   || _fail "internal file was re-encoded/overwritten"

# DB records ONLY the real file; backup/internal paths must not appear.
DB="$LIB/.flac_scan_data/reencoded.db"
db_has_path "$SBX" "$REAL"
! grep -Fq 'w2.flac' "$DB"               || _fail "db mentions a backup file"
! grep -Fq '.flac_scan_data/reports/x.flac' "$DB" || _fail "db mentions an internal file"

echo "ok: case_reencode_csv"
