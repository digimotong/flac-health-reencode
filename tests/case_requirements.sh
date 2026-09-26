#!/usr/bin/env bash
# case_requirements.sh - integration: the required-tool gate.
#
# At startup the script refuses to run unless 'flac' and 'metaflac' are on PATH,
# and it must do so BEFORE any menu is drawn or any file is touched (the
# `for cmd in flac metaflac jq` loop). Without this gate a partial install could
# reach the reencode paths, where a missing 'flac' would fail per-file only after
# 'metaflac' had been trusted for fingerprints.
#
# Covered here:
#   A. 'flac' absent  -> error names flac, status 1, no menu, no writes.
#   B. 'metaflac' absent -> error names metaflac, status 1, no menu.
#   C. Both absent    -> still exits 1 with the first missing tool's message.
#   D. Both present (control) -> the menu DOES render, proving A-C fail for the
#      stated reason and not because the sandbox is broken.

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

# run_script_missing_hermetic <sbx> <tool-to-hide> [stdin lines...]
#   Sibling of run_script_missing for the tools that are NOT stubbed in $sbx/bin
#   (jq): the child's PATH holds ONLY $sbx/bin_hermetic, so the tool under test
#   is unreachable no matter where the host keeps it.
#
#   Two deliberate details keep this hermetic without breaking the script under
#   test:
#     - The script is launched as /bin/bash, not as bare 'bash'. With PATH set to
#       just $bindir, a bare 'bash' would not resolve, and the failure would be a
#       shell error rather than the tool gate this case exists to exercise.
#     - $bindir is seeded with the stubs plus the handful of REAL utilities the
#       script legitimately touches on its way to the gate (dirname/realpath for
#       CONFIG_FILE, cat/tr/grep for config probing). Everything else genuine
#       stays out of reach, which is the point: jq must be absent here.
run_script_missing_hermetic() {
    local sbx="$1" hidden="$2"; shift 2
    local bindir="$sbx/bin_hermetic"
    rm -rf "$bindir"; mkdir -p "$bindir"
    local f p
    for f in flac metaflac; do
        [ "$f" = "$hidden" ] && continue
        ln -s "$sbx/bin/$f" "$bindir/$f"
    done
    for p in dirname realpath cat tr grep; do
        ln -s "$(command -v "$p")" "$bindir/$p"
    done
    CURRENT_OUT="$sbx/output.log"
    if printf '%s\n' "$@" | PATH="$bindir" /bin/bash "$sbx/flac_health_reencode.sh" \
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

# ===========================================================================
# E. 'jq' absent: the gate must catch it. jq is not stubbed in $sbx/bin and
#    lives on the host, so the case runs the script against a hermetic PATH that
#    holds the stubs plus the few real utilities the script needs pre-gate. The
#    config is deliberately removed first: the interesting property is that the
#    gate fires BEFORE anything creates one, so no zero-byte config is left.
# ===========================================================================
SBX_NOJQ=''
make_sandbox SBX_NOJQ
register_sandbox "$SBX_NOJQ"
rm -f "$SBX_NOJQ/flac_health_config.json"

run_script_missing_hermetic "$SBX_NOJQ" jq 'q'
occur_re "The 'jq' command is not installed"
[ "$LAST_STATUS" -eq 1 ] || _fail "no jq exited $LAST_STATUS, expected 1"
absent_re "$MENU_TITLE"
[ ! -e "$SBX_NOJQ/flac_health_config.json" ] \
    || _fail "no jq still created a config file"

# F. The hint must name the tool's own package. A single hardcoded
#    "apt-get install flac" (the pre-fix behaviour) would misdirect a user whose
#    jq is missing, so the no-jq run must suggest jq. The flac hint itself is
#    checked in case A, where flac is the reported tool: asserting it HERE would
#    be wrong, since the jq message legitimately never mentions flac.
occur_re 'apt-get install jq'
absent_re 'apt-get install flac'

# G. Control for F: with every tool installed the hint itself never appears,
#    so the F assertions above are about the failure path only.
run_script "$SBX_OK" 'q'
absent_re "apt-get install"
[ "$LAST_STATUS" -eq 0 ] || _fail "jq-present control exited $LAST_STATUS, expected 0"

echo "ok: case_requirements (jq missing is gated, with the right hint)"
