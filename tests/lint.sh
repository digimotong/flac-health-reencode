#!/usr/bin/env bash
###############################################################################
# lint.sh - the single source of truth for how this repo is linted.
#
#   Usage:  bash tests/lint.sh
#
# CI's `lint` job runs exactly this script, so `bash tests/lint.sh` locally and
# CI can never disagree about how ShellCheck is invoked. That matters: an
# earlier SC1091 failure came from running a *different* command locally (the
# two documented invocations hand-merged into one, which happened to put the
# production script in the file list) than CI ran.
#
# Exits 0 iff every invocation is clean, so it also works as a local pre-push
# gate and is safe to chain into other scripts.
###############################################################################

set -o errexit
set -o nounset
set -o pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "FAIL: shellcheck is not installed." >&2
    echo "      Install it (e.g. 'apt-get install shellcheck') and re-run." >&2
    exit 1
fi

# -S style is the strictest threshold shellcheck offers, so every diagnostic it
# can emit is treated as a failure.
THRESHOLD="style"

# Print the version: CI installs whatever apt ships, and a future bump can turn
# this job red with no repository change at all (0.10 already changed flag
# support, e.g. --rcfile). Having it in the log makes that drift obvious
# instead of mysterious.
echo "== shellcheck $(shellcheck --version | awk '/^version:/ {print $2}') (-S $THRESHOLD) =="

# Run both invocations even if the first fails, so one run reports everything.
rc=0

run_lint() {
    local label="$1"
    shift
    echo "-- $label: shellcheck $*"
    if ! shellcheck -S "$THRESHOLD" "$@"; then
        rc=1
    fi
}

# The production script is the priority: it is the artefact that rewrites the
# user's audio files.
run_lint "production script" flac_health_reencode.sh

# The test suite and the flac/metaflac stubs. These are analysed WITHOUT the
# production script in the file list, which is why .shellcheckrc enables
# external-sources: tests/source_guard_units.sh sources ../flac_health_reencode.sh
# and ShellCheck refuses to follow a source it has no permission to read.
run_lint "test suite and stubs" tests/*.sh tests/stub_flac tests/stub_metaflac

if [ "$rc" -ne 0 ]; then
    echo "FAIL: shellcheck reported diagnostics (see above)." >&2
    exit 1
fi

echo "ok: shellcheck clean at -S $THRESHOLD."
