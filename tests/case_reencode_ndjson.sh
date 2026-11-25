#!/usr/bin/env bash
# case_reencode_ndjson.sh - integration: option 2 on the CURRENT (NDJSON) report.
#
# The report a scan writes is JSON Lines. This case pre-seeds one - in the exact shape
# write_scan_report emits - and proves option 2:
#   * prefers it over an OLDER legacy .csv sitting beside it (newest by mtime wins,
#     whichever format it is in; both extensions are discovered);
#   * reads the paths out of the 'error' records and IGNORES the header record;
#   * keeps filtering (a backup path and an internal path in the report are skipped);
#   * reencodes exactly the listed files, mirrors their originals and records them.
#
# It also covers the reader itself: a filepath that CONTAINS a JSON escape (a double
# quote, a backslash) must come back byte-identical, which is the whole point of the
# format. That is asserted through the same jq -j path option 2 uses.

set -o errexit
set -o nounset
set -o pipefail

: "${TESTS_ROOT:?}"
: "${PROD_SCRIPT:?}"
. "$TESTS_ROOT/helpers.sh"

# report_paths <report> <out-file> : the 'error' filepaths of an NDJSON report, NUL
# separated, exactly as the script derives them. Kept in a FILE and read with
# 'read -r -d ""', so a path containing a newline is one record, not two.
report_paths() {
    jq -j 'select(.type == "error") | .filepath, "\u0000"' "$1" > "$2"
}

SBX=''
make_sandbox SBX
register_sandbox "$SBX"
LIB="$SBX/lib"
RPT="$LIB/.flac_scan_data/reports"

# Two "problematic" files, one of them with a name that needs JSON escaping in both a
# quote and a backslash, plus a healthy file the report must NOT touch.
PLAIN="$LIB/Album/quoted \"loud\" mix.flac"
BACKSLASH="$LIB/Album/back\\slash.flac"
HEALTHY="$LIB/Album/healthy.flac"
BADBAK="$LIB/Album/backup_FLAC_originals/w2.flac"
INTFILE="$LIB/.flac_scan_data/reports/x.flac"

mkdir -p "$LIB/Album" "$LIB/Album/backup_FLAC_originals" "$RPT"
write_file "$PLAIN"     'orig-plain-bytes'
write_file "$BACKSLASH" 'orig-backslash-bytes'
write_file "$HEALTHY"   'orig-healthy-bytes'
write_file "$BADBAK"    'orig-w2-bytes'
write_file "$INTFILE"   'orig-x-bytes'

# Older legacy CSV: it must lose to the newer NDJSON, so its target stays untouched.
sleep 0.01
printf '# Scan Report: legacy\nfilepath\n"%s"\n' "$HEALTHY" > "$RPT/flac_scan_2020-01-01_00-00-00.csv"
sleep 0.02

# The NDJSON report, written the way write_scan_report writes it: jq encodes the
# strings, so the nested quote and backslash in PLAIN/BACKSLASH are escaped for us.
REPORT="$RPT/flac_scan_2026-01-01_00-00-00.ndjson"
{
    jq -c -n --arg generated '2026-01-01T00:00:00Z' --argjson files 5 --argjson errors 4 \
        '{type: "header", generated: $generated, files: $files, errors: $errors}'
    for f in "$PLAIN" "$BACKSLASH" "$BADBAK" "$INTFILE"; do
        jq -c -n --arg filepath "$f" '{type: "error", filepath: $filepath}'
    done
} > "$REPORT"

# The reader contract, checked before any script run: every seeded path comes back
# byte-for-byte, in order, as one NUL record each.
report_paths "$REPORT" "$SBX/expected.nul"
EXPECTED=("$PLAIN" "$BACKSLASH" "$BADBAK" "$INTFILE")
i=0
while IFS= read -r -d '' got; do
    [ "$i" -lt "${#EXPECTED[@]}" ] || _fail "report yielded more paths than were seeded"
    [ "$got" = "${EXPECTED[$i]}" ] \
        || _fail "NDJSON round-trip mangled path $i: got <$got>, want <${EXPECTED[$i]}>"
    i=$((i + 1))
done < "$SBX/expected.nul"
[ "$i" -eq "${#EXPECTED[@]}" ] || _fail "report yielded $i paths, expected ${#EXPECTED[@]}"

run_script "$SBX" '2' 'Y' ''

occur_re 'Latest scan report found:.*flac_scan_.*\.ndjson'
# The header record is not a path: it is filtered by record type, so it is neither
# attempted nor echoed.
[ "$(captured_count 'Total files processed: ([0-9]+)')"  -eq 2 ] || _fail "option2 total != 2"
[ "$(captured_count 'Successful reencodes: ([0-9]+)')"    -eq 2 ] || _fail "option2 success != 2"
[ "$(captured_count 'Failed reencodes: ([0-9]+)')"        -eq 0 ] || _fail "option2 fail != 0"
[ "$(message_count 'Skipping internal/backup path:')"     -eq 2 ] || _fail "expected exactly 2 internal-skip messages"

# Both flagged files re-encoded, each original mirrored at its album-relative path.
file_eq "$PLAIN"       "$RE_MARKER" || _fail "quote-named file was not re-encoded"
file_eq "$BACKSLASH"   "$RE_MARKER" || _fail "backslash-named file was not re-encoded"
file_eq "$SBX/lib_backup/Album/quoted \"loud\" mix.flac" 'orig-plain-bytes' \
    || _fail "quote-named backup lost its name"
file_eq "$SBX/lib_backup/Album/back\\slash.flac" 'orig-backslash-bytes' \
    || _fail "backslash-named backup lost its name"

# Not in the report -> untouched, no backup, no DB row.
file_eq "$HEALTHY" 'orig-healthy-bytes' || _fail "the stale legacy CSV's target was re-encoded"
miss "$SBX/lib_backup/Album/healthy.flac"
file_eq "$BADBAK"  'orig-w2-bytes' || _fail "a backup path was re-encoded"
file_eq "$INTFILE" 'orig-x-bytes'  || _fail "an internal path was re-encoded"

DB="$LIB/.flac_scan_data/reencoded.db"
db_has_path "$SBX" "$PLAIN"
db_has_path "$SBX" "$BACKSLASH"
! grep -Fq 'healthy.flac' "$DB" || _fail "db mentions a file that was not in the report"

# The legacy CSV is never deleted by consuming an NDJSON report.
exist "$RPT/flac_scan_2020-01-01_00-00-00.csv"

echo "ok: case_reencode_ndjson"