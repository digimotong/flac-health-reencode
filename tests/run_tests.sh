#!/usr/bin/env bash
###############################################################################
# run_tests.sh - black-box + source-guard test runner for flac_health_reencode.sh
#
#   Usage:  bash tests/run_tests.sh [--verbose]
#
# Stages:
#   1. Syntax gate: `bash -n` the production script.
#   2. Tool check: flac/metaflac are STUBS (tests/), but the production script
#      needs real `jq` to read/write its config, so require it here.
#   3. Each tests/case_*.sh runs in its OWN subprocess + sandbox. A case prints
#      nothing on success and "FAIL: ..." on failure, and exits non-zero on any
#      failed assertion. Captured logs are replayed on failure for debugging.
#   4. Overall PASS/FAIL summary; exit 0 iff every case passes.
###############################################################################

set -o errexit
set -o nounset
set -o pipefail

# Locate this runner and the repo roots regardless of CWD.
THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/.." && pwd)"
PROD_SCRIPT="$REPO_ROOT/flac_health_reencode.sh"

VERBOSE=0
case "${1:-}" in
    --verbose|-v) VERBOSE=1 ;;
    --help|-h|"") : ;;
    *) echo "run_tests.sh: unrecognized option: $1" >&2; exit 2 ;;
esac

# 1. Syntax gate ----------------------------------------------------------------
if ! bash -n "$PROD_SCRIPT"; then
    echo "FAIL: '$PROD_SCRIPT' fails 'bash -n'." >&2
    exit 1
fi
echo "ok: syntax gate       ($PROD_SCRIPT)"

# 2. Required tooling -----------------------------------------------------------
for tool in jq md5sum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "SKIP: tool '$tool' not installed; run_tests cannot exercise the script." >&2
        exit 0
    fi
done
echo "ok: tool check        jq + md5sum present"

# 3. Export env the cases need ------------------------------------------------
export TESTS_ROOT="$THIS_DIR"
export PROD_SCRIPT="$PROD_SCRIPT"

total=0
passed=0
failed=0
failed_names=()

echo ""
echo "== running test cases =="
for case in "$THIS_DIR"/case_*.sh; do
    [ -e "$case" ] || continue
    name="$(basename "$case")"
    total=$((total + 1))

    log="$(mktemp "${TMPDIR:-/tmp}/${name}.XXXXXX")"
    if bash "$case" >"$log" 2>&1; then
        passed=$((passed + 1))
        echo "  PASS  $name"
    else
        failed=$((failed + 1))
        failed_names+=("$name")
        echo "  FAIL  $name"
        echo "  -------- $name output --------"
        cat "$log"
        echo "  ------------------------------"
    fi
    rm -f "$log"
done

echo ""
echo "=============================================="
if [ "$failed" -eq 0 ]; then
    echo "ALL $passed CASE(S) PASSED"
    echo "=============================================="
    exit 0
else
    echo "RESULT: $passed passed, $failed failed (of $total)"
    printf 'failed: %s\n' "${failed_names[*]}"
    echo "=============================================="
    exit 1
fi
