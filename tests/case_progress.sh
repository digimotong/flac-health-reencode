#!/usr/bin/env bash
# case_progress.sh - integration: the shared progress display on options 1/2/4/5.
#
# REGRESSION ANCHOR. The pool used to render its bar from a counter that was only
# filled in AFTER every worker had finished, and it rendered on DISPATCH rather
# than on completion. A parallel run therefore painted "0% (0/N)" N times and
# never reached 100%, while the default scan (jobs > 1) selected a replay mode and
# drew no bar at all. This case pins the fixed contract for every long-running
# option:
#
#   * a captured (non-tty) parallel run emits plain "Progress: [...]" lines that
#     ADVANCE and finish on a real "100% (N/N)" line - never a repeated 0%;
#   * a captured sequential run never emits a progress bar (its per-file status
#     lines already say everything);
#   * the bar never leaks carriage returns or escapes into captured output;
#   * each operation's own summary starts on its own row (nothing is glued to a
#     bar line).
#
# The live single-line form needs a PTY and is covered by case_tty.sh.

set -o errexit
set -o nounset
set -o pipefail

: "${TESTS_ROOT:?}"
: "${PROD_SCRIPT:?}"
. "$TESTS_ROOT/helpers.sh"

FILE_COUNT=10

# progress_pcts: every whole-percent value rendered by a "Progress: [...]" line, in
# order. Read from clean_sandbox_output so the bar text is compared without escapes.
progress_pcts() {
    clean_sandbox_output | sed -nE 's/.*\[[#-]+\] +([0-9]+)%.*/\1/p'
}

# assert_progress_finished <label> : the run drew a real progress display that
# advanced monotonically and ended on 100%.
assert_progress_finished() {
    local label="$1"
    local pcts last
    pcts=$(progress_pcts)
    [ -n "$pcts" ] || _fail "$label: no 'Progress:' lines were rendered"
    # Never a repeated percentage: a redraw that did not advance means the counter
    # driving the bar is not the completion tally (the original bug).
    last=-1
    while IFS= read -r pct; do
        [ "$pct" -ge "$last" ] || _fail "$label: progress went backwards ($last% -> $pct%)"
        [ "$pct" -eq "$last" ] && _fail "$label: percentage $pct% rendered twice (bar not advancing)"
        last="$pct"
    done <<< "$pcts"
    [ "$last" -eq 100 ] || _fail "$label: progress ended at $last%, expected 100%"
    occur_re "Progress: \[#+-*\] +100% \($FILE_COUNT/$FILE_COUNT\)"
    # The multi-line text form only: a captured run must never emit carriage
    # returns or real escapes (those belong to the live, PTY-only display).
    if LC_ALL=C grep -q $'\r' "$CURRENT_OUT"; then
        _fail "$label: captured output contains carriage-return bytes"
    fi
    if LC_ALL=C grep -q $'\033' "$CURRENT_OUT"; then
        _fail "$label: captured output contains real ESC bytes"
    fi
    return 0
}

# make_n_files <sbx> [corrupt_index...] : FILE_COUNT real FLAC files, the listed
# indexes (1-based) corrupt, mirroring the stub's CORRUPT-marker contract.
make_n_files() {
    local sbx="$1"; shift
    local corrupt=" $* "
    local i
    mkdir -p "$sbx/lib/Album"
    for i in $(seq 1 "$FILE_COUNT"); do
        case "$corrupt" in
            *" $i "*) write_file "$sbx/lib/Album/track$i.flac" 'PCM_DATA_CORRUPT' ;;
            *)        write_file "$sbx/lib/Album/track$i.flac" "orig-$i" ;;
        esac
    done
}

# set_jobs <sbx> <n>
set_jobs() {
    printf '{"library_path": "%s", "backup_path": "%s", "version": "1.1", "jobs": %s}\n' \
        "$1/lib" "$1/lib_backup" "$2" > "$1/flac_health_config.json"
}

# ===========================================================================
# Option 1 (scan), parallel: the DEFAULT configuration must show progress.
# ===========================================================================
SBX=''
make_sandbox SBX
register_sandbox "$SBX"
make_n_files "$SBX"
set_jobs "$SBX" 4

run_script_env "$SBX" "STUB_FLAC_TEST_SLEEP=0.05" -- '1' '' 'q'
[ "$LAST_STATUS" -eq 0 ] || _fail "scan: exited $LAST_STATUS, expected 0"
assert_progress_finished 'option 1 scan (jobs=4)'
# The scan reports its results only AFTER the bar has finished, on their own rows
# (the error list would otherwise be appended to a half-drawn bar line).
occur_re 'Scan complete\.'
if grep -qE '\[[#-]+\].*Scan complete' "$CURRENT_OUT"; then
    _fail 'scan: summary glued onto the progress bar row'
fi

# ===========================================================================
# Option 1 (scan), sequential: no bar in captured output, but still complete.
# ===========================================================================
set_jobs "$SBX" 1
run_script_env "$SBX" -- '1' '' 'q'
[ "$LAST_STATUS" -eq 0 ] || _fail "scan jobs=1: exited $LAST_STATUS"
[ -z "$(progress_pcts)" ] || _fail 'scan jobs=1: expected no progress lines in captured output'
occur_re 'Scan complete\.'

# ===========================================================================
# Option 4 (reencode ALL), parallel: bar advances to 100%, summary on its own row.
# ===========================================================================
SBX4=''
make_sandbox SBX4
register_sandbox "$SBX4"
make_n_files "$SBX4"
set_jobs "$SBX4" 4

run_script_env "$SBX4" "STUB_FLAC_SLEEP=0.05" -- '4' 'REENCODE ALL' '' 'q'
assert_progress_finished 'option 4 (jobs=4)'
occur_re "Successful reencodes: $FILE_COUNT"
if grep -qE '\[[#-]+\].*Reencode complete' "$CURRENT_OUT"; then
    _fail 'option 4: summary glued onto the progress bar row'
fi

# ===========================================================================
# Option 2 (problem files from the latest scan), parallel.
# ===========================================================================
SBX2=''
make_sandbox SBX2
register_sandbox "$SBX2"
make_n_files "$SBX2" 3 6
set_jobs "$SBX2" 4
# Seed the newest scan report exactly as scan_library writes it.
mkdir -p "$SBX2/lib/.flac_scan_data/reports"
{
    echo '# Scan Report: 2026-01-01T00:00:00Z | Files: 10 | Errors: 2'
    echo 'filepath'
    echo "\"$SBX2/lib/Album/track3.flac\""
    echo "\"$SBX2/lib/Album/track6.flac\""
} > "$SBX2/lib/.flac_scan_data/reports/flac_scan_2026-01-01_00-00-00.csv"

run_script_env "$SBX2" "STUB_FLAC_SLEEP=0.05" -- '2' 'y' '' 'q'
occur_re 'Progress: \[#+-*\] +100% \(2/2\)'
# The completion summary must start on a fresh row (option 2 used to append it to
# the bar, because nothing ended the bar's line).
if grep -qE '% \([0-9]+/[0-9]+\).*Reencoding complete' "$CURRENT_OUT"; then
    _fail 'option 2: summary glued onto the progress bar row'
fi
occur_re 'Reencoding complete at'

# ===========================================================================
# Option 5 (new files only), parallel.
# ===========================================================================
SBX5=''
make_sandbox SBX5
register_sandbox "$SBX5"
make_n_files "$SBX5"
set_jobs "$SBX5" 4

run_script_env "$SBX5" "STUB_FLAC_SLEEP=0.05" -- '5' 'y' '' 'q'
assert_progress_finished 'option 5 (jobs=4)'
occur_re "New files processed: $FILE_COUNT"

echo "ok: case_progress (options 1/2/4/5 all render an advancing bar)"
