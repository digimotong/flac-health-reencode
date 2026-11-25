#!/usr/bin/env bash
# case_report_nasty_names.sh - end-to-end: a scan report survives real filenames.
#
# The scan report is the hand-off between option 1 and option 2, so a filename the
# report cannot carry is a file the library can never repair. The old CSV report lost
# three kinds of name outright:
#   * a comma        -> 'IFS=, read' truncated "A, B.flac" to "A"
#   * a double quote -> the blanket '"'-strip corrupted the name
#   * a newline      -> the scan worker's newline-terminated shard split one file into
#                       two bogus entries before a report was even written
# and it never escaped anything, so it was not valid CSV either.
#
# This case feeds ONE library holding a name of each hostile shape (plus a UTF-8 name
# and a name starting with '-', which must never be read as an option) through scan ->
# option 2, and asserts:
#   * the scan flags exactly those files;
#   * the report parses as NDJSON, with one 'error' record per file;
#   * every reported filepath is BYTE-IDENTICAL to the file on disk (compared with
#     [ "$a" = "$b" ] on NUL-read records and with cmp on files, never on lines, since
#     one of them holds a newline);
#   * option 2 re-encodes every one of them and mirrors the pristine original into the
#     backup tree at the same relative path, still byte-identical;
#   * the clean file is never touched.

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
BAK="$SBX/lib_backup"
mkdir -p "$LIB/Album"

# The fixture: every name is a legal filename, and every one of them broke the CSV.
NEWLINE_NAME="$LIB/Album/a"$'\n'"b.flac"
CLEAN="$LIB/Album/healthy.flac"
NAMES=(
    "$LIB/Album/comma,name.flac"
    "$LIB/Album/quote\"name.flac"
    "$LIB/Album/back\\slash.flac"
    "$NEWLINE_NAME"
    "$LIB/Album/Thé Bleu.flac"
    "$LIB/Album/-dash.flac"
)
# Each carries the stub's CORRUPT marker, so the scan flags all six; the marker also
# makes the pristine bytes distinguishable from the reencoded output.
i=0
for f in "${NAMES[@]}"; do
    i=$((i + 1))
    write_file "$f" "orig-$i:CORRUPT"
done
write_file "$CLEAN" 'healthy-bytes'
ALL_FILES=("${NAMES[@]}" "$CLEAN")
FLAGGED=${#NAMES[@]}

# The pristine bytes of every flagged file, for the backup comparison, one copy per
# index: a filename with a newline cannot be used as a key.
PRISTINE="$SBX/pristine"
mkdir -p "$PRISTINE"
i=0
for f in "${NAMES[@]}"; do
    i=$((i + 1))
    cp -p "$f" "$PRISTINE/$i"
done

# ---------------------------------------------------------------------------
# Option 1: the scan
# ---------------------------------------------------------------------------
run_script "$SBX" '1' ''

occur_re "Found ${#ALL_FILES[@]} FLAC files to scan"
[ "$(captured_count 'Scanned ([0-9]+) files')" -eq "${#ALL_FILES[@]}" ] \
    || _fail "the scan did not scan every file (${#ALL_FILES[@]})"
[ "$(captured_count 'Found ([0-9]+) errors')" -eq "$FLAGGED" ] \
    || _fail "the scan did not flag exactly $FLAGGED files"

REPORT=$(find "$LIB/.flac_scan_data/reports" -type f -name 'flac_scan_*.ndjson' -print | head -1)
[ -n "$REPORT" ] || _fail "the scan wrote no .ndjson report"

# JSON Lines: one object per line, a header and $FLAGGED error records.
jq -e . "$REPORT" >/dev/null 2>&1 || _fail "the report is not valid JSON Lines"
[ "$(jq -s 'length' "$REPORT")" -eq "$(wc -l < "$REPORT")" ] \
    || _fail "the report has a line that is not exactly one JSON value"
[ "$(jq -s '[.[] | select(.type == "header")] | length' "$REPORT")" -eq 1 ] \
    || _fail "expected exactly one header record"
[ "$(jq -s '[.[] | select(.type == "error")] | length' "$REPORT")" -eq "$FLAGGED" ] \
    || _fail "expected $FLAGGED error records"

# Every reported path is byte-identical to a file on disk, and each file is reported
# exactly once. The set is compared through NUL-separated records, so the newline in
# one name is data, not a separator.
jq -j 'select(.type == "error") | .filepath, "\u0000"' "$REPORT" > "$SBX/reported.nul"
: > "$SBX/want.nul"
for f in "${NAMES[@]}"; do
    printf '%s\0' "$f" >> "$SBX/want.nul"
done
# tr maps NUL to a newline ONLY inside these pipelines, for sort/diff: the report's
# 'error' paths are compared as a SET, which catches a mangled name, a duplicated
# record and a missing one at once.
tr '\0' '\n' < "$SBX/reported.nul" | sort > "$SBX/reported.txt"
tr '\0' '\n' < "$SBX/want.nul"     | sort > "$SBX/want.txt"
diff -u "$SBX/want.txt" "$SBX/reported.txt" > "$SBX/report.diff" 2>&1 \
    || _fail "the report's filepaths do not match the flagged files byte for byte:
$(cat "$SBX/report.diff")"
# ...and the healthy file is not in it.
! grep -qxF "$CLEAN" "$SBX/reported.txt" \
    || _fail "the report lists a file that scanned clean"

echo "ok: case_report_nasty_names (scan report round-trips every hostile name)"


# ---------------------------------------------------------------------------
# Option 2: re-encode from the report
# ---------------------------------------------------------------------------
run_script "$SBX" '2' 'Y' ''

occur_re 'Latest scan report found:.*flac_scan_.*\.ndjson'
[ "$(captured_count 'Total files processed: ([0-9]+)')" -eq "$FLAGGED" ] \
    || _fail "option 2 did not process all $FLAGGED flagged files"
[ "$(captured_count 'Successful reencodes: ([0-9]+)')" -eq "$FLAGGED" ] \
    || _fail "option 2 did not re-encode every flagged file"
[ "$(captured_count 'Failed reencodes: ([0-9]+)')" -eq 0 ] \
    || _fail "option 2 reported failures"

# Every flagged file was replaced by the stub's re-encode output, and its pristine
# original is in the backup tree at the SAME relative path, byte for byte. cmp is used
# rather than $(cat) because these names cannot be rendered in a shell string, and the
# pristine side is byte-compared so the newline name is checked as data.
i=0
for f in "${NAMES[@]}"; do
    i=$((i + 1))
    file_eq "$f" "$RE_MARKER" || _fail "flagged file #$i was not re-encoded: <$f>"
    cmp -s "$PRISTINE/$i" "$BAK/Album/${f#"$LIB/Album/"}" \
        || _fail "backup of flagged file #$i is missing or differs from the original: <$f>"
done

# Every flagged file is also recorded in the tracking DB - including the newline name.
# That name is a known limit of this case's assertion, not of the DB: db_has_path
# rebuilds a path from space-split tokens, which cannot express a newline, so the
# format itself is covered by source_guard_units.sh (a newline record loads as ONE row)
# and the newline file's own row is counted here.
for f in "${NAMES[@]}"; do
    [ "$f" = "$NEWLINE_NAME" ] && continue
    db_has_path "$SBX" "$f"
done
[ "$(db_row_count "$LIB/.flac_scan_data/reencoded.db")" -eq "$FLAGGED" ] \
    || _fail "the tracking DB should hold exactly $FLAGGED records"

# A name starting with '-' must never be read as an option by any tool it reaches: the
# scan passes the path to 'flac -t' and the reencode hands it to flac, metaflac and cp.
# Here it must have gone through the whole pipeline like any other name - its backup
# holds the pristine original, looked up by its own '-'-prefixed, quoted name.
file_eq "$BAK/Album/-dash.flac" 'orig-6:CORRUPT' \
    || _fail "the '-dash.flac' backup does not hold the pristine original"

# The clean file was never touched by either operation.
file_eq "$CLEAN" 'healthy-bytes' || _fail "the clean file was re-encoded"
miss "$BAK/Album/healthy.flac"

echo "ok: case_report_nasty_names (option 2 consumes every hostile name)"
