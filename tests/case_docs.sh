#!/usr/bin/env bash
# case_docs.sh - INTEGRATION: the README still describes the real script. Nothing else
# checked README.md, so the docs could (and did) drift from the script.
#
# Asserted, all derived from the SOURCE rather than hardcoded:
#   A. Required tools: every name in the script's startup gate (`for cmd in ...`) appears in
#      the README, and in its '## Requirements' section, so adding a required tool forces a
#      doc update.
#   B. Config keys: every key the script writes into flac_health_config.json is documented,
#      so a new key cannot ship undocumented.
#   C. The `version` claim: the README documents that key as write-only, so this fails if the
#      script ever starts reading it (the signal to fix that row).
#
# Deliberately NOT asserted: rendered sentences, menu wording, option counts or timing text -
# per tests/helpers.sh, assertions stay loose so cosmetic rewording cannot break the suite.

set -o errexit
set -o nounset
set -o pipefail

: "${TESTS_ROOT:?}"
: "${PROD_SCRIPT:?}"
. "$TESTS_ROOT/helpers.sh"

README="$(dirname "$PROD_SCRIPT")/README.md"
# The production SOURCE is the entry script plus the modules it sources: a value the
# script relies on may legitimately live in either, and the guards below are about the
# script's contract with the user, not about which file holds the line.
PROD_SOURCES=("$PROD_SCRIPT" "$(dirname "$PROD_SCRIPT")"/lib/*.sh)

# grep_prod <pattern> : the matching SOURCE LINES across the production sources, with
# any "file:line:" prefix removed, so callers parse the code and never the file name.
grep_prod() {
    grep -nE -- "$1" "${PROD_SOURCES[@]}" 2>/dev/null \
        | sed -E 's/^[^:]*:[0-9]+://' || true
}

# Read the README straight from the repo, next to the script under test.
exist "$README"
README_TEXT="$(cat "$README")"

# ===========================================================================
# A. Every tool in the startup gate is named in the README.
# ===========================================================================
# Parse: for cmd in flac metaflac jq; do
gate_line="$(grep_prod '^for cmd in ' | head -n1)"
[ -n "$gate_line" ] \
    || _fail "no 'for cmd in ...' startup gate found in the production sources"

tools="${gate_line#*for cmd in }"
tools="${tools%%;*}"            # drop everything from the first ';'
# shellcheck disable=SC2086  # deliberate word splitting into the tool list
set -- $tools

[ "$#" -ge 1 ] || _fail "startup gate lists no tools"

for tool in "$@"; do
    printf '%s\n' "$README_TEXT" | grep -qF -- "$tool" \
        || _fail "required tool '$tool' is in the startup gate but not in README.md"
    # The README's own Requirements block must carry it too, not just a mention in prose: an
    # install list that omits a hard requirement is the bug this guard exists for. The section
    # ends at the next '## ' heading, so a later mention (e.g. the '## Development' shellcheck
    # note) cannot satisfy it.
    awk '/^## Requirements$/{f=1;next} /^## /{f=0} f' "$README" | grep -qF -- "$tool" \
        || _fail "required tool '$tool' is missing from the README '## Requirements' section"
done

echo "ok: case_docs (startup-gate tools documented: $*)"

# ===========================================================================
# B. Every key the script writes into the config is documented.
# ===========================================================================
# Parse the width-1 keys out of the production sources' `jq -n '{...}'` default-config
# call: the ONLY place the config schema is defined.
jq_default="$(grep_prod "jq -n '\{" | head -n1)"
[ -n "$jq_default" ] \
    || _fail "could not find the jq default-config call in the production sources"

# shellcheck disable=SC2016  # single quotes are literal: matching field names
keys="$(printf '%s\n' "$jq_default" | grep -oE '[a-z_]+: ' | sed -E 's/: $//' | sort -u)"
[ -n "$keys" ] || _fail "extracted no config keys from: $jq_default"

for key in $keys; do
    # Backticked, because the README documents keys as `key` in its tables.
    printf '%s\n' "$README_TEXT" | grep -qF -- "\`$key\`" \
        || _fail "config key '$key' is written by the script but not documented in README.md"
done

echo "ok: case_docs (config keys documented: $(printf '%s' "$keys" | tr '\n' ' '))"

# ===========================================================================
# C. The README's `version` row: the script must not read that key.
# ===========================================================================
# The README documents `version` as write-only. A jq read of '.version' in the production
# script would make that claim false, so fail and point at the row. Matching reads only, so
# the script's own writer line is not caught.
version_reads="$(grep_prod '\.version\b')"
if [ -n "$version_reads" ]; then
    _fail "the script now reads '.version' from the config, but the README key
       table documents it as never read back; update that row (and this guard).
       offending line(s):
$version_reads"
fi

# The row must still exist: guard B owns the keys the script WRITES, and a deleted row would
# quietly retire this guard's subject. Match the backticked key cell specifically, so prose
# mentioning `version` is not enough. (BT is the backtick, kept out of the quotes to avoid an
# SC2016 command-substitution warning.)
BT='`'
grep -qF -- "| ${BT}version${BT} |" "$README" \
    || _fail "README no longer documents the 'version' config key row"

echo "ok: case_docs (README's write-only 'version' claim still holds)"
