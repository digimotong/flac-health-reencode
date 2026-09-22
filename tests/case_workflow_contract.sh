#!/usr/bin/env bash
###############################################################################
# case_workflow_contract.sh - INTEGRATION: the CI workflow keeps its checks
# reportable on `main`.
#
# `.github/workflows/tests.yml` is the only thing that produces this repo's
# status checks, and the check *name* is what a ruleset matches on. Three
# perfectly ordinary edits to that file silently change or remove the name while
# leaving the build green, and the damage is not a red X - it is a PR that can
# never merge, stuck on "Expected - waiting for status to be reported":
#
#   1. A `paths:`/`branches:` filter on the trigger. The whole run is skipped on
#      exactly the PRs that touch those files, so no check is ever reported.
#   2. Renaming or deleting a job. The reported context is the job id, so
#      removing `lint` leaves the required `lint` context unreported.
#   3. Adding a `strategy:`/matrix to a job, or a job-level `name:`. Either
#      renames the reported context (`lint` becomes `lint (3.12)`, or whatever
#      `name:` says), so the required bare `lint` stops reporting.
#   4. Adding a job-level `if:`/`needs:`. A skipped job reports nothing at all,
#      so a `if:` that is false on pull_request, or a `needs:` chain through a
#      job that is itself skipped, leaves the required context unreported.
#
# The sibling tagger repos assert the same properties in
# tests/test_twin_parity.py (TestWorkflowKeepsTheParityCheckUsable), but they do
# it with PyYAML because their comments NAME `paths:` and `branches:` while
# explaining that filters must not be used, so a substring match cannot tell the
# structure from the prose about it. This repo has no Python in CI (the `test`
# job installs only jq), so the equivalent is done here by extracting blocks with
# awk and comparing only the block's *shape* - never its text. That is what makes
# this comment-proof: whole-line comments are discarded before anything is
# compared, and property A reads line numbers and nesting depth rather than
# values, so a future comment mentioning `paths:` cannot be mistaken for a filter.
#
# The two suites differ in one deliberate way: there the matrix on `test` is
# REQUIRED (the ruleset demands `test (3.12)`/`(3.13)`/`(3.14)`), so its absence
# is the failure; here any `strategy:` on a required job is the failure. Each
# side asserts what its own ruleset matches, so they must not be copied across.
#
# Deliberately NOT asserted: step names, wording, which tools a step installs,
# the shellcheck pin, the workflow's own `name:`, or the exact set of jobs.
# Adding a job or a step is legitimate and must not fail this; per
# tests/helpers.sh, only structural facts are asserted.
###############################################################################

set -o errexit
set -o nounset
set -o pipefail

: "${TESTS_ROOT:?}"
: "${PROD_SCRIPT:?}"
. "$TESTS_ROOT/helpers.sh"

REPO_ROOT="$(dirname "$PROD_SCRIPT")"
WORKFLOW="$REPO_ROOT/.github/workflows/tests.yml"

# The workflow ships in the repo next to the script under test.
exist "$WORKFLOW"

# Jobs whose names are the status checks a ruleset requires on `main`. Unlike
# the documentation guards, these two names ARE the contract - they are what a
# branch ruleset matches on - so pinning them here is the point, not a hardcoded
# fact that would go stale. Renaming a job is a deliberate act that has to be
# mirrored in the ruleset, so failing here is the correct outcome.
#
# The list mirrors the ruleset exactly, so it has to be edited together with it,
# in the same change. The taggers require `parity` and `dockerfile` on top of
# `lint` and matrix `test`; this repo has neither job and requires neither, so a
# ruleset or job list copied between the repos would ask a check to report that
# nothing ever produces - which blocks every merge. The workflow's comment above
# `jobs:` names these same two contexts, which is where they are documented.
REQUIRED_JOBS='test lint'

# awk source for "print the body of a block". Shared so the extraction rule is
# stated exactly once:
#   sec   = the section key to open on, matched as an exact whole line
#   start = an ERE matching a *sibling* of the section, which closes the block.
#           Empty/absent for a top-level section, where the block instead closes
#           at the next column-0 line.
#
# Two different closing rules, because the file has two levels of "next entry":
# a top-level section like `on:` ends at the next column-0 line, while a job body
# starts at a 2-space id and ends at the *next* 2-space id. Both were needed:
# getting the job case wrong is not cosmetic, because with only the column-0 rule
# `test`'s body ran on to the end of the file and swallowed `lint`'s keys, so a
# `strategy:` added to `lint` was reported against `test` - the failing job was
# misnamed and, worse, the same pass could have hidden the drift entirely.
#
# SC2016 is expected here: the single quotes are deliberate, because this is an
# awk program whose '$0' must reach awk unexpanded - not a shell expansion.
# shellcheck disable=SC2016
BLOCK_BODY_AWK='
    $0 == sec { inblock = 1; next }
    inblock && start != "" && $0 ~ start { exit }
    inblock && start == "" && /^[^[:space:]]/ { inblock = 0 }
    inblock { print }
'

# drop_noise: remove comments and blank lines before any comparison. Used on the
# OUTPUT of body_of, in a second awk pass, because the ' #' strip needs the whole
# line and a line already printed cannot be un-printed.
#   A full-line comment anywhere is prose, not structure.
#   An inline trailing comment is stripped only after ' #' - requiring the space
#   keeps a '#' inside a value (e.g. a 'name: fix #42') from being cut in half.
#   '}' == '!x' cannot be written inline because a '!' in an awk regex after a
#   POSIX class can be read as a negated class; comparing the string is equivalent.
drop_noise() {
    awk '
        {
            line = $0
            if (index(line, " #") > 0) sub(/ #.*$/, "", line)
            if (line ~ /^[[:space:]]*$/) next
            if (line ~ /^[[:space:]]*#/) next
            print line
        }
    '
}

# body_of <section> : echo a top-level section's body lines. No `start` anchor,
# so the block ends at the next column-0 line (`permissions:` etc.).
body_of() {
    awk -v sec="$1" "$BLOCK_BODY_AWK" "$WORKFLOW"
}

# body_of_job <job> : echo a job's body lines. The anchor is any 2-space key,
# which ends the body at the next job id. Regex (not an exact match) because the
# point of asserting on the *shape* is that sibling job ids are unknown to this
# guard - a new job may be added at any time, and its name must not matter.
body_of_job() {
    awk -v sec="  $1:" -v start='^  [a-zA-Z0-9_-]+:' "$BLOCK_BODY_AWK" "$WORKFLOW"
}

# ===========================================================================
# A. The triggers must be unfiltered.
# ===========================================================================
# `push:` and `pull_request:` must both appear, each as a bare key with nothing
# nested under it. A `paths:`/`branches:` child - or a list item under the key -
# filters the run, so the required checks are simply never reported on the PRs
# that matter, which blocks them with no red X to explain it.
#
# Both halves of that are load-bearing, and both were live false negatives before
# this guard was written this way:
#   * Inspecting only the keys cannot see a filter. A `push:` with a nested
#     `paths:` is still a `push:` line, so the filter has to be detected as an
#     extra *depth* under the key, not as an extra key.
#   * A YAML comment line can start with whitespace. Because YAML itself treats
#     the whole line as a comment, a commented-out filter is inert and must NOT
#     fail this, so comments are dropped by awk while the line numbers (which is
#     all this assertion reads) are still intact.
#
# What is read, therefore, is only the *shape* of the block: which lines sit
# directly under `push:`/`pull_request:` (4-space keys), which sit one level
# deeper (6-space keys or `- ` list items), and how many keys each trigger has.
# Values are never compared, so reordering, inline comments and re-indenting are
# all ignored.
trigger_shape="$(awk -v sec='on:' '
    function is_comment(line) { return line ~ /^[[:space:]]*#/ }

    # Trim a trailing comment, keeping a "#" that is inside a value.
    function strip(line) {
        if (index(line, " #") > 0) sub(/ #.*$/, "", line)
        return line
    }

    BEGIN { in_on = 0; trigger = ""; keys = 0 }

    $0 == sec { in_on = 1; next }

    # A comment never ends the block, at any indent: YAML discards the whole
    # line, so a note about `paths:` sitting between the triggers must not look
    # like the end of the section. This is checked BEFORE the end-of-block rule
    # so a column-0 comment cannot cut the block short.
    in_on && is_comment($0) { next }

    in_on && /^[^[:space:]]/ { in_on = 0 }

    in_on {
        line = strip($0)
        if (line ~ /^[[:space:]]*$/) next

        # A trigger key: exactly two spaces of indent, nothing after the colon.
        # The key keeps its indentation, so the shape reads like the YAML it came
        # from and the comparison below can be written literally.
        if (line ~ /^  [a-zA-Z0-9_-]+:[[:space:]]*$/) {
            if (trigger != "") print trigger " " keys
            trigger = line
            keys = 0
            next
        }

        # Anything indented further is nested *under* the current trigger.
        if (trigger != "" && line ~ /^    [a-zA-Z0-9_-]+:/) keys++
        next
    }

    END { if (trigger != "") print trigger " " keys }
' "$WORKFLOW" | sort)"

# Sorted, because the order of the triggers carries no meaning: pinning the set
# keeps a removed trigger (which stops one event producing checks at all) failing
# while a purely cosmetic reorder does not.
expected_triggers="$(printf '  push: 0\n  pull_request: 0\n' | sort)"
if [ "$trigger_shape" != "$expected_triggers" ]; then
    _fail "the workflow's \`on:\` block no longer starts an unfiltered run on
       every push and PR. Expected each trigger to be a bare key with nothing
       nested beneath it:

$(printf '%s\n' "$expected_triggers" | sed 's/^/         /')

       found instead (trigger, then how many keys are nested under it):

$(printf '%s\n' "$trigger_shape" | sed 's/^/         /')

       A nested key is a filter: \`paths:\`/\`branches:\` skips the whole run -
       required checks included - on exactly the PRs that touch those files, so
       GitHub reports no status and the PR is blocked rather than failed. Remove
       the filter, or accept that the required checks cannot gate main."
fi

echo "ok: case_workflow_contract (triggers are unfiltered: push, pull_request)"

# ===========================================================================
# B. Every required job is still declared.
# ===========================================================================
# The job id is the status-check context a ruleset matches on. Only presence is
# asserted, never the exact job set: adding a job is legitimate, removing or
# renaming one of these is what breaks a merge.
job_ids="$(body_of 'jobs:' | grep -E '^  [a-zA-Z0-9_-]+:' | sed -E 's/^  ([a-zA-Z0-9_-]+):.*$/\1/' | sort)"

for job in $REQUIRED_JOBS; do
    printf '%s\n' "$job_ids" | grep -qxF -- "$job" \
        || _fail "the workflow no longer declares a job named '$job'. That name
       is the required status-check context in this repository, so removing or
       renaming it leaves the required check unreported and blocks every merge.
       jobs found: $(printf '%s' "$job_ids" | tr '\n' ' ')"
done

echo "ok: case_workflow_contract (required jobs declared: $REQUIRED_JOBS)"

# ===========================================================================
# C. No required job may be matrixed or renamed.
# ===========================================================================
# Both a job-level `strategy:` and a job-level `name:` rename the reported
# context: `lint` becomes `lint (3.12)`, or whatever `name:` says. The required
# bare `lint` then never reports - the same silent block as B, but produced by an
# edit that looks purely additive.
#
# These four keys are named explicitly rather than matched by class: the first
# two are exactly the keys GitHub uses to change a check's name, and the last two
# are the keys that stop a job from running at all - and a job that does not run
# reports nothing, which is the same silent block reached by a different route:
#
#   strategy  -> the check is renamed `lint (3.12)`
#   name      -> the check is whatever `name:` says
#   if        -> the job is skipped whenever the condition is false (e.g. an
#                `if:` that only holds on push leaves every PR unreported)
#   needs     -> the job is skipped whenever a dependency is skipped or fails,
#                so one `if:` upstream silently takes this check down with it
#
# Listing them is the rule, not a sample of it: every other job-level key
# (`runs-on:`, `steps:`, a new `env:` ...) is legitimate and must pass.
#
# Indentation is what makes this safe to check by pattern. Job ids sit at two
# spaces and a job's own keys at four, while step entries are nested one level
# deeper and are introduced by `- ` (`      - name: Checkout`); anchoring on
# exactly four spaces + a word character therefore matches job-level keys only,
# so a step's `name:` or `if:` can neither satisfy nor trip this. Job bodies come
# from body_of_job, which stops at the next job id, so one job's keys can never be
# attributed to another.
for job in $REQUIRED_JOBS; do
    renames="$(body_of_job "$job" | grep -E '^    (strategy|name|if|needs):' || true)"
    [ -z "$renames" ] || _fail "the '$job' job grew a job-level key that renames
       the reported status check or stops it running, so the required '$job'
       context stops reporting and every PR is blocked:

$(printf '%s\n' "$renames" | sed 's/^/         /')

       A 'strategy:' makes the check '$job (3.12)'; a 'name:' replaces it
       outright; an 'if:' or 'needs:' skips the job, and a skipped job reports
       nothing. Fix the workflow - matrix, rename, guard or chain a job that is
       NOT required - or update the ruleset in the same change."
done

echo "ok: case_workflow_contract (required jobs un-matrixed, unnamed and unconditional)"
