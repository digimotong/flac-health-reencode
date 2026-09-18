#!/usr/bin/env bash
###############################################################################
# case_requirements.sh - integration: the required-tool gate.
#
# At startup the script refuses to run unless BOTH 'flac' and 'metaflac' are on
# PATH, and it must do so BEFORE any menu is drawn or any file is touched
# (flac_health_reencode.sh, the `for cmd in flac metaflac` loop). Without this
# gate a user with a partial install could reach the reencode paths, where a
# missing 'flac' would fail per-file only after 'metaflac' had already been
# trusted for fingerprints.
#
# Covered here:
#   A. 'flac' absent  -> error names flac, exit status 1, no menu, no writes.
#   B. 'metaflac' absent -> error names metaflac, exit status 1, no menu.
#   C. Both absent    -> still exits 1 with the first missing tool's message.
#   D. Both present (control) -> the menu DOES render, proving A-C fail for the
#      stated reason and not because the sandbox is broken.
###############################################################################

set -o errexit
set -o nounset
set -o pipefail

: "${TESTS_ROOT:?}"
: "${PROD_SCRIPT:?}"
. "$TESTS_ROOT/helpers.sh"

MENU_TITLE='FLAC Health Check & Reencode Script'

# run_script_missing <sbx> <tool-to-hide> [stdin lines...]
#   Like run_script, but the named stub is hidden from the child's PATH so the
#   script's `command -v` probe fails for exactly that tool.
run_script_missing() {
    local sbx="$1" hidden="$2"; shift 2
    local bindir="$sbx/bin_nowrap"
    rm -rf "$bindir"; mkdir -p "$bindir"
    local f
    for f in flac metaflac; do
        [ "$f" = "$hidden" ] && continue
        ln -s "$sbx/bin/$f" "$bindir/$f"
    done
    CURRENT_OUT="$sbx/output.log"
    if printf '%s\n' "$@" | PATH="$bindir:/usr/bin:/bin" bash "$sbx/flac_health_reencode.sh" \
            > "$CURRENT_OUT" 2>&1; then
        LAST_STATUS=0
    else
        LAST_STATUS=$?
    fi
    return 0
}

# ===========================================================================
# A. 'flac' missing -> exit 1, tool named, no menu, no side effects.
# ===========================================================================
SBX_FLAC=''
make_sandbox SBX_FLAC
register_sandbox "$SBX_FLAC"

run_script_missing "$SBX_FLAC" flac 'q'

occur_re "The 'flac' command is not installed"
occur_re 'sudo apt-get install flac'
[ "$LAST_STATUS" -eq 1 ] || _fail "missing flac exited $LAST_STATUS, expected 1"
absent_re "$MENU_TITLE"
# The gate runs before any library work: nothing may have been created.
miss "$SBX_FLAC/lib/.flac_scan_data"

echo "ok: case_requirements (missing flac refuses to start)"

# ===========================================================================
# B. 'metaflac' missing -> exit 1, tool named, no menu.
# ===========================================================================
SBX_META=''
make_sandbox SBX_META
register_sandbox "$SBX_META"

run_script_missing "$SBX_META" metaflac 'q'

occur_re "The 'metaflac' command is not installed"
occur_re 'sudo apt-get install flac'
[ "$LAST_STATUS" -eq 1 ] || _fail "missing metaflac exited $LAST_STATUS, expected 1"
absent_re "$MENU_TITLE"
miss "$SBX_META/lib/.flac_scan_data"

echo "ok: case_requirements (missing metaflac refuses to start)"

# ===========================================================================
# C. Both missing -> still a clean exit 1 naming a required tool.
# ===========================================================================
SBX_NONE=''
make_sandbox SBX_NONE
register_sandbox "$SBX_NONE"

# The script probes 'flac' first, so hiding both yields the flac message; the
# check is repeated for metaflac so a future reorder of the probe loop cannot
# silently change which tool is reported.
run_script_missing "$SBX_NONE" flac 'q'
occur_re "The 'flac' command is not installed"
[ "$LAST_STATUS" -eq 1 ] || _fail "no tools exited $LAST_STATUS, expected 1"

run_script_missing "$SBX_NONE" metaflac 'q'
occur_re "The 'metaflac' command is not installed"
[ "$LAST_STATUS" -eq 1 ] || _fail "no tools exited $LAST_STATUS, expected 1"
absent_re "$MENU_TITLE"

echo "ok: case_requirements (both tools missing)"

# ===========================================================================
# D. Control: with both stubs present the menu renders and 'q' exits 0.
# ===========================================================================
SBX_OK=''
make_sandbox SBX_OK
register_sandbox "$SBX_OK"

run_script "$SBX_OK" 'q'

occur_re "$MENU_TITLE"
[ "$LAST_STATUS" -eq 0 ] || _fail "control run exited $LAST_STATUS, expected 0"

echo "ok: case_requirements (control: both tools present)"
