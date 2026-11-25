#!/usr/bin/env bash
# case_scan.sh - integration: option 1 (Full scan music library).
#
# A. Library WITH a corrupt REAL file + a corrupt BACKUP + a corrupt .flac_scan_data file.
#    Asserts only real files are counted/catalogued (2 real of 4 total), an NDJSON report
#    is produced whose header record counts the scan and whose single 'error' record is
#    the real corrupt file (backup/internal are NOT reported even when corrupt), and a
#    scan summary log is written.
# B. A CLEAN library: reports "No errors found.", writes a scan summary log, but leaves
#    NO report (neither .ndjson nor the legacy .csv).
#
# The report is JSON Lines, one object per line, and is parsed with jq - a hard
# dependency of the script - so a path is compared as a JSON string VALUE, never as a
# delimiter-split line.

set -o errexit
set -o nounset
set -o pipefail

: "${TESTS_ROOT:?}"
: "${PROD_SCRIPT:?}"
. "$TESTS_ROOT/helpers.sh"

# 'reports' dir only exists once a scan runs; helper to fetch its one report.
first_report() {
    find "$1/.flac_scan_data/reports" -type f \
        \( -name 'flac_scan_*.ndjson' -o -name 'flac_scan_*.csv' \) -print 2>/dev/null | head -1
}
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
occur_re 'Report generated: .*flac_scan_.*\.ndjson'

REPORT=$(first_report "$LIB")
[ -n "$REPORT" ] || _fail "expected a non-empty scan report on the corrupt run"
exist "$REPORT"
case "$REPORT" in
    *.ndjson) : ;;
    *) _fail "a new scan must write an .ndjson report, got: $REPORT" ;;
esac

# Every record is one JSON object on its own line, and every record says what it is.
jq -e . "$REPORT" >/dev/null 2>&1 || _fail "the report is not valid JSON Lines: $REPORT"
[ "$(jq -s 'length' "$REPORT")" -eq "$(wc -l < "$REPORT")" ] \
    || _fail "the report has lines that are not exactly one JSON value"
[ "$(jq -s '[.[] | has("type")] | all' "$REPORT")" = 'true' ] \
    || _fail "a report record has no 'type' field"
[ "$(jq -s '[.[] | .type] | unique == ["error", "header"]' "$REPORT")" = 'true' ] \
    || _fail "the report holds record types other than 'header' and 'error'"

# Exactly one header, carrying this run's counts.
[ "$(jq -s '[.[] | select(.type == "header")] | length' "$REPORT")" -eq 1 ] \
    || _fail "expected exactly one header record"
[ "$(jq -s '.[] | select(.type == "header") | .files' "$REPORT")" -eq 2 ] \
    || _fail "header 'files' is not the scanned file count (2)"
[ "$(jq -s '.[] | select(.type == "header") | .errors' "$REPORT")" -eq 1 ] \
    || _fail "header 'errors' is not the failure count (1)"
jq -e -s '.[] | select(.type == "header") | .generated | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' \
    "$REPORT" >/dev/null || _fail "header 'generated' is not an RFC 3339 UTC timestamp"

# Exactly one error record, and it is the real corrupt path - compared as a JSON value.
[ "$(jq -s '[.[] | select(.type == "error")] | length' "$REPORT")" -eq 1 ] \
    || _fail "expected exactly one error record"
GOT=$(jq -j -s '.[] | select(.type == "error") | .filepath' "$REPORT" | tr -d '\n')
[ "$GOT" = "$LIB/AlbumBad/broken.flac" ] \
    || _fail "error record filepath is '$GOT', expected the real corrupt path"

# Sanity: the corrupt BACKUP and INTERNAL files are simply not in the report.
! grep -Fq 'backup_FLAC_originals' "$REPORT" || _fail "corrupt backup echoed in the report"
! grep -Fq '.flac_scan_data' "$REPORT"       || _fail "internal path echoed in the report"

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
[ -z "$(first_report "$LIB2")" ] || _fail "a report was left behind after a clean scan"
absent_re 'Report generated:'

# A clean scan still leaves a summary log (no report), and its report line says so.
SLOG2=$(first_scan_log "$LIB2")
[ -n "$SLOG2" ] || _fail "expected a scan summary log after the clean run"
exist "$SLOG2"
grep -qE '^Errors found: 0$' "$SLOG2"   || _fail "clean summary log lacks 'Errors found: 0'"
grep -Fq 'none - no errors found' "$SLOG2" \
    || _fail "clean summary log's Report line does not indicate no report"

echo "ok  case_scan (clean library)"
