#!/usr/bin/env bash
###############################################################################
# case_docs.sh - INTEGRATION: the README still describes the real script.
#
# This repository had no check on README.md at all, so its documentation could
# drift from the script with nothing to catch it -- and it did: commit 78dd960
# ("Require jq in the startup gate and correct the docs") had to fix the README
# by hand after the startup gate gained a tool. These guards make that class of
# drift fail here instead of in the field.
#
# What is asserted, and why it is derived from SOURCE rather than hardcoded:
#
#   A. Required tools. The names in the script's startup gate (`for cmd in ...`)
#      must each appear in the README, so adding a required tool forces a doc
#      mention in the same change.
#   B. Config keys. The keys the script writes into flac_health_config.json must
#      each appear in the README, so a new config key cannot ship undocumented.
#   C. The `version` claim. The README once said that key was "read by the
#      script"; the script only ever WRITES it (the only reader is
#      tests/case_config.sh). This guard fails if the script ever starts reading
#      it again, which is the signal to correct that row rather than let it go
#      stale a second time.
#
# Deliberately NOT asserted: rendered sentences, menu wording, option counts, or
# exact timing text. Per tests/helpers.sh, assertions in this suite stay loose so
# cosmetic rewording cannot break it -- these guards are limited to facts that
# are extracted from the production script itself.
###############################################################################

set -o errexit
set -o nounset
set -o pipefail

: "${TESTS_ROOT:?}"
: "${PROD_SCRIPT:?}"
. "$TESTS_ROOT/helpers.sh"

README="$(dirname "$PROD_SCRIPT")/README.md"

# Read the README straight from the repo, next to the script under test.
exist "$README"
README_TEXT="$(cat "$README")"

# ===========================================================================
# A. Every tool in the startup gate is named in the README.
# ===========================================================================
# Parse: for cmd in flac metaflac jq; do
gate_line="$(grep -E '^for cmd in ' "$PROD_SCRIPT" | head -n1)"
[ -n "$gate_line" ] \
    || _fail "no 'for cmd in ...' startup gate found in $PROD_SCRIPT"

tools="${gate_line#for cmd in }"
tools="${tools%%;*}"            # drop everything from the first ';'
# shellcheck disable=SC2086  # deliberate word splitting into the tool list
set -- $tools

[ "$#" -ge 1 ] || _fail "startup gate lists no tools"

for tool in "$@"; do
    printf '%s\n' "$README_TEXT" | grep -qF -- "$tool" \
        || _fail "required tool '$tool' is in the startup gate but not in README.md"
    # The README's own Requirements block must carry it too, not just a mention
    # somewhere in prose: an install list that omits a hard requirement is the
    # exact bug 78dd960 fixed. The section ends at the next '## ' heading, so a
    # later mention (e.g. the '## Development' shellcheck note) cannot satisfy it.
    awk '/^## Requirements$/{f=1;next} /^## /{f=0} f' "$README" | grep -qF -- "$tool" \
        || _fail "required tool '$tool' is missing from the README '## Requirements' section"
done

echo "ok: case_docs (startup-gate tools documented: $*)"

# ===========================================================================
# B. Every key the script writes into the config is documented.
# ===========================================================================
# Parse the width-1 keys out of the script's `jq -n '{...}'` default-config
# call: the ONLY place the config schema is defined.
jq_default="$(grep -E "jq -n '\{" "$PROD_SCRIPT" | head -n1)"
[ -n "$jq_default" ] \
    || _fail "could not find the jq default-config call in $PROD_SCRIPT"

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
# The README documents `version` as write-only. If a jq read of '.version' shows
# up in the production script, that claim is false and the doc must be corrected
# -- so fail here and point at the row. The script's own writer line is excluded
# by matching reads only: it sets the key, it never queries it.
version_reads="$(grep -nE '\.version\b|\[\"version\"\]|\[.version.\]' "$PROD_SCRIPT" || true)"
if [ -n "$version_reads" ]; then
    _fail "the script now reads '.version' from the config, but the README key
       table documents it as never read back; update that row (and this guard).
       offending line(s):
$version_reads"
fi

# The row must still exist: guard B above owns the keys the script WRITES, and a
# deleted row would otherwise quietly retire this guard's subject. Match the
# backticked key cell specifically, so prose mentioning `version` is not enough.
# (BT is the backtick, kept out of the quotes to avoid an SC2016 command-
# substitution warning.)
BT='`'
grep -qF -- "| ${BT}version${BT} |" "$README" \
    || _fail "README no longer documents the 'version' config key row"

echo "ok: case_docs (README's write-only 'version' claim still holds)"
