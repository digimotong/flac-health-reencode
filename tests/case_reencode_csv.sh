#!/usr/bin/env bash
# case_reencode_csv.sh - integration: option 2 on a LEGACY (CSV) scan report.
#
# Older versions wrote reports as CSV, and users keep those files, so option 2 must
# still consume them (the NDJSON path has its own case, case_reencode_ndjson.sh).
# The CSV parse is quoted-row based: the path is the whole line with ONE surrounding
# quote pair removed, so a comma or an interior double quote in a filename survives -
# 'IFS=, read' used to truncate "A, B.flac" at the comma and a blanket quote-strip
# corrupted any name containing a quote.
#
# Pre-seeds TWO scan CSVs: one stale, one NEWEST manual list. The manual list mixes valid rows
# with rows the script must IGNORE (the '# Scan Report...' comment, the 'filepath' header, a
# backup copy, an internal .flac_scan_data file). Only the real "problematic" files are
# reencoded:
#   * the manual (newest) CSV is chosen, not the stale one
#   * the count lines reflect the 3 real rows
#   * their ORIGINAL BYTES are mirrored into the backup root (outside the library, at the
#     album-relative path) and each file is replaced with reencoded content
#   * backup + internal files stay untouched (never re-encoded, no db rows)
#   * the reencoded real files are recorded in reencoded.db

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
# Filenames a delimiter-based format mangles: a comma (IFS=, truncation) and a
# double quote (blanket quote-strip). Both are legal on every filesystem and all too
# real in tagged libraries.
COMMA="$LIB/Album Big/A, B.flac"
QUOTED="$LIB/Album Big/A, B\"c.flac"
BADBAK="$LIB/Album Big/backup_FLAC_originals/w2.flac"
INTFILE="$LIB/.flac_scan_data/reports/x.flac"
# Base dirs; ".flac_scan_data/" is created by the nested mkdir (its parent is the library
# root). We place real albums, one backup dir, and a pre-existing report that doubles as the
# "internal file candidate" location.
mkdir -p "$LIB/Album Big/backup_FLAC_originals" "$LIB/Album Big2" "$LIB/.flac_scan_data/reports"

write_file "$REAL"   'orig-worst-bytes'
write_file "$COMMA"  'orig-comma-bytes'
write_file "$QUOTED" 'orig-quoted-bytes'
write_file "$BADBAK" 'orig-w2-bytes'
write_file "$INTFILE" 'orig-x-bytes'
write_file "$LIB/Album Big2/other.flac" 'original-other'

# Stale CSV (older mtime).
RPT="$LIB/.flac_scan_data/reports"
sleep 0.01
printf '# Scan Report: stale\nfilepath\n"%s"\n' "$LIB/Album Big2/other.flac" > "$RPT/flac_scan_2020-01-01_00-00-00.csv"

# The manual CSV must be strictly newer: selection is by mtime, so the gap keeps the
# ordering unambiguous regardless of timestamp granularity.
sleep 0.02

# Newest manually-authored scan list: comment + header + REAL + a comma name + a
# comma+quote name + backup + internal.
MANUAL="$RPT/flac_scan_manual.csv"
{
    printf '# Scan Report: 2026 | Files: 7 | Errors: 5\n'
    printf 'filepath\n'
    printf '"%s"\n' "$REAL"
    printf '"%s"\n' "$COMMA"
    printf '"%s"\n' "$QUOTED"
    printf '"%s"\n' "$BADBAK"
    printf '"%s"\n' "$INTFILE"
} > "$MANUAL"

run_script "$SBX" '2' 'Y' ''

occur_re 'Latest scan report found:.*flac_scan_manual\.csv'
# Captured runs get the pool's per-file result lines replayed in file order; the pre-pool
# "Processing file: <path>" dispatch line no longer exists.
occur_re "SUCCESS: $REAL reencoded successfully"
occur_re "SUCCESS: $COMMA reencoded successfully"
occur_re "SUCCESS: $QUOTED reencoded successfully"

# Count lines (tee'd + printed to stdout): exactly 3 processed.
[ "$(captured_count 'Total files processed: ([0-9]+)')"  -eq 3 ] || _fail "option2 total != 3"
[ "$(captured_count 'Successful reencodes: ([0-9]+)')"    -eq 3 ] || _fail "option2 success != 3"
[ "$(captured_count 'Failed reencodes: ([0-9]+)')"        -eq 0 ] || _fail "option2 fail != 0"
# Two rows (backup + internal) were skipped via the internal/backup filter.
[ "$(message_count 'Skipping internal/backup path:')"     -eq 2 ] || _fail "expected exactly 2 internal-skip messages"

# State: the real files were replaced by the stub's reencode marker...
file_eq "$REAL" 'REENCODE_OK' || _fail "real file was not replaced by reencode marker"
file_eq "$COMMA"  'REENCODE_OK' || _fail "comma-named file was not re-encoded (truncated at the comma?)"
file_eq "$QUOTED" 'REENCODE_OK' || _fail "quote-named file was not re-encoded (quotes stripped?)"
# ...their ORIGINAL bytes were mirrored into the backup root (outside the library, at the same
# album-relative path)...
BAK="$SBX/lib_backup"
file_eq "$BAK/Album Big/worst.flac" 'orig-worst-bytes' \
  || _fail "mirrored backup does not preserve the original"
file_eq "$BAK/Album Big/A, B.flac" 'orig-comma-bytes' \
  || _fail "mirrored backup lost the comma name"
file_eq "$BAK/Album Big/A, B\"c.flac" 'orig-quoted-bytes' \
  || _fail "mirrored backup lost the quote name"
# ...and the OTHER real file (stale CSV's target) was NOT re-encoded.
file_eq "$LIB/Album Big2/other.flac" 'original-other' || _fail "stale-CSV file was re-encoded (manual CSV should win)"

# Backup + internal sources remain byte-identical (never re-encoded).
file_eq "$BADBAK"  'orig-w2-bytes'  || _fail "backup file was re-encoded/overwritten"
file_eq "$INTFILE" 'orig-x-bytes'   || _fail "internal file was re-encoded/overwritten"

# DB records ONLY the real files; backup/internal paths must not appear.
DB="$LIB/.flac_scan_data/reencoded.db"
db_has_path "$SBX" "$REAL"
db_has_path "$SBX" "$COMMA"
db_has_path "$SBX" "$QUOTED"
! grep -Fq 'w2.flac' "$DB"               || _fail "db mentions a backup file"
! grep -Fq '.flac_scan_data/reports/x.flac' "$DB" || _fail "db mentions an internal file"

echo "ok: case_reencode_csv"