#!/usr/bin/env bash
###############################################################################
# case_scan.sh - integration: option 1 (Full scan music library)
#
# A. Library WITH a corrupt REAL file + a corrupt BACKUP + a corrupt .flac_scan_data
#    file. Asserts only real files are counted/catalogued (2 real of 4 total),
#    a CSV is produced with the '# Scan Report...' comment + 'filepath' header,
#    the report's single data row = the real corrupt file (backup/internal are
#    NOT reported even when corrupt), AND a scan summary log is written.
# B. Library that is CLEAN: reports "No errors found.", writes a scan summary
#    log, but leaves NO CSV.
###############################################################################

set -o errexit
set -o nounset
set -o pipefail

: "${TESTS_ROOT:?}"
: "${PROD_SCRIPT:?}"
. "$TESTS_ROOT/helpers.sh"

# 'reports' dir only exists once a scan runs; helper to fetch its one CSV.
first_csv() { find "$1/.flac_scan_data/reports" -type f -name 'flac_scan_*.csv' -print | head -1; }
# Fetch the single scan-summary log written to the logs dir.
first_scan_log() { find "$1/.flac_scan_data/logs" -type f -name 'scan_log_*.txt' -print | head -1; }

# ===========================================================================
# Run A: corrupt real + corrupt backup + corrupt internal file
# ===========================================================================
SBX=''
make_sandbox SBX
register_sandbox "$SBX"
LIB="$SBX/lib"
mkdir -p "$LIB/Album OK" "$LIB/AlbumBad/backup_FLAC_originals" "$LIB/.flac_scan_data"

write_file "$LIB/Album OK/track one.flac" 'good1'
write_file "$LIB/AlbumBad/broken.flac"    'bad-payload:CORRUPT'      # real + corrupt
write_file "$LIB/AlbumBad/backup_FLAC_originals/broken.flac" 'bad-payload:CORRUPT'  # backup
write_file "$LIB/.flac_scan_data/metrics.flac" 'in:CORRUPT'         # internal

run_script "$SBX" '1' ''

occur_re 'Found 2 FLAC files to scan'
occur_re 'Error detected in:.*broken\.flac'
occur_re 'Found 1 errors'

CSV=$(first_csv "$LIB")
[ -n "$CSV" ] || _fail "expected a non-empty CSV on the corrupt run"
exist "$CSV"

meta=$(sed -n '1p' "$CSV")
hdr=$(sed -n '2p' "$CSV")
row=$(sed -n '3p' "$CSV")
case "$meta" in
    '# Scan Report:'*) : ;;
    *) _fail "CSV row 1 is not the '# Scan Report ...' metadata comment" ;;
esac
[ "$hdr" = 'filepath' ]              || _fail "CSV row 2 is not the 'filepath' header"
[ "$row" = "\"$LIB/AlbumBad/broken.flac\"" ] || _fail "CSV row 3 is not exactly the real corrupt path"
[ "$(wc -l < "$CSV")" -eq 3 ]        || _fail "CSV should have exactly 1 quoted data row"

# Sanity: the corrupt BACKUP and INTERNAL files are simply not in the report.
! grep -Fq 'backup_FLAC_originals' "$CSV" || _fail "corrupt backup echoed in CSV"
! grep -Fq '.flac_scan_data' "$CSV"       || _fail "internal path echoed in CSV"

# A scan summary log is written even on a run that found errors.
SLOG=$(first_scan_log "$LIB")
[ -n "$SLOG" ] || _fail "expected a scan summary log after the corrupt run"
exist "$SLOG"
occur_re 'Scan summary saved to: .*scan_log_.*\.txt'

echo "ok  case_scan (library with corrupt real file)"

# ===========================================================================
# Run B: clean library  ->  "No errors found." and no report file created.
# ===========================================================================
SBX2=''
make_sandbox SBX2
register_sandbox "$SBX2"
LIB2="$SBX2/lib"
mkdir -p "$LIB2/Albums"
write_file "$LIB2/Albums/ok.flac" 'clean'

run_script "$SBX2" '1' ''

occur_re 'No errors found'
occur_re 'Scan complete'
[ -z "$(first_csv "$LIB2")" ] || _fail "a CSV was left behind after a clean scan"

# A clean scan still leaves a summary log (no CSV), and its report line says so.
SLOG2=$(first_scan_log "$LIB2")
[ -n "$SLOG2" ] || _fail "expected a scan summary log after the clean run"
exist "$SLOG2"
grep -qE '^Errors found: 0$' "$SLOG2"   || _fail "clean summary log lacks 'Errors found: 0'"
grep -Fq 'none - no errors found' "$SLOG2" \
    || _fail "clean summary log's Report line does not indicate no report"

echo "ok  case_scan (clean library)"
