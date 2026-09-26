#!/usr/bin/env bash
# run_manual.sh - aggregator for the REAL-flac manual harness (tests/manual/).
#
# Deliberately NOT wired into tests/run_tests.sh: that suite must stay fast,
# hermetic and dependency-free (it stubs flac), and it is what the required CI
# 'test' job runs. This harness needs the flac package, real CPU time and a real
# filesystem, so it runs as its own (non-required) CI job and on any server before
# a release - see .github/workflows/tests.yml and tests/manual/README.md.
#
# Behavior mirrors tests/run_tests.sh: run every *.sh here except itself, print a
# PASS/SKIP/FAIL line each, and summarize. A script that exits 0 after printing
# "SKIP:" is a SKIP (the harness is green without real flac, but says so loudly).
# Any other non-zero status is a FAIL and fails this runner.
#
#   Usage: bash tests/manual/run_manual.sh [script.sh ...]
#   Env:   PROD_SCRIPT  path to flac_health_reencode.sh (default: repo root copy)

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$HERE")")"
PROD_SCRIPT="${PROD_SCRIPT:-$REPO_ROOT/flac_health_reencode.sh}"
export PROD_SCRIPT

if [ ! -f "$PROD_SCRIPT" ]; then
    printf 'run_manual.sh: production script not found at %s\n' "$PROD_SCRIPT" >&2
    exit 2
fi
# The harness must never run without the real tools; state that up front so a SKIP
# is obviously a "this host cannot test this", not a silent hole.
if ! command -v flac >/dev/null 2>&1 || ! command -v metaflac >/dev/null 2>&1; then
    printf 'NOTE: real flac/metaflac not found on PATH - every script will SKIP.\n'
    printf '      Install the flac package and re-run to actually exercise this harness.\n\n'
fi

# A bare call runs everything; explicit arguments run just those (handy locally).
if [ "$#" -gt 0 ]; then
    SCRIPTS=("$@")
else
    SCRIPTS=()
    while IFS= read -r s; do
        SCRIPTS+=("$s")
    done < <(find "$HERE" -maxdepth 1 -type f -name '*.sh' \
             ! -name 'run_manual.sh' ! -name 'lib.sh' | sort)
fi

if [ "${#SCRIPTS[@]}" -eq 0 ]; then
    printf 'run_manual.sh: no harness scripts found under %s\n' "$HERE" >&2
    exit 2
fi

printf '== real-flac manual harness ==\n'
printf '   script under test: %s\n' "$PROD_SCRIPT"
printf '   flac: %s\n' "$(command -v flac 2>/dev/null || echo '(missing)')"
printf '   metaflac: %s\n\n' "$(command -v metaflac 2>/dev/null || echo '(missing)')"

pass=0
fail=0
skip=0
failed_names=()

for s in "${SCRIPTS[@]}"; do
    name="$(basename "$s")"
    out="$(mktemp "${TMPDIR:-/tmp}/flac_manual_out_XXXXXX")"

    # Run in its own process; capture combined output for the verdict. `if` keeps
    # a non-zero status from tripping errexit here.
    if bash "$s" > "$out" 2>&1; then
        status=0
    else
        status=$?
    fi

    if [ "$status" -ne 0 ]; then
        printf '  FAIL  %s (exit %s)\n' "$name" "$status"
        sed 's/^/        | /' "$out"
        fail=$((fail + 1))
        failed_names+=("$name")
    elif grep -q '^SKIP:' "$out"; then
        printf '  SKIP  %s\n' "$name"
        printf '        %s\n' "$(grep -m1 '^SKIP:' "$out")"
        skip=$((skip + 1))
    else
        printf '  PASS  %s\n' "$name"
        pass=$((pass + 1))
    fi

    rm -f "$out"
done

printf '\n==============================================\n'
printf 'MANUAL HARNESS: %d passed, %d skipped, %d failed\n' "$pass" "$skip" "$fail"
if [ "$fail" -gt 0 ]; then
    printf 'FAILED: %s\n' "${failed_names[*]}"
    printf '==============================================\n'
    exit 1
fi
# SKIPs are NOT failures (a host may legitimately lack flac), but a run where
# nothing executed at all is reported, so CI logs make the coverage gap obvious.
if [ "$pass" -eq 0 ] && [ "$skip" -gt 0 ]; then
    printf 'NOTE: nothing was actually exercised on this host (all scripts skipped).\n'
fi
printf '==============================================\n'
