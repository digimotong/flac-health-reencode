#!/usr/bin/env bash
# helpers.sh - shared sandbox and loose-assertion harness for case_*.sh
#
# Conventions
#   - Each case runs the REAL flac_health_reencode.sh as a subprocess against its
#     own throwaway sandbox (fresh library tree + stub bin + config), so the
#     developer's real config/library are never touched.
#   - run_script sets $CURRENT_OUT to that run's combined-output log; every
#     assertion below reads CURRENT_OUT.
#   - Assertions are deliberately LOOSE: occurrence of short stable regex markers,
#     file exists/contents, counts parsed by a regex helper, and DB/backup side
#     effects. Rendered sentences, progress bars, spacing and timestamps are NOT
#     matched, so cosmetic rewording cannot break the suite.
#   - A failed assertion prints a readable message and exits 1 from the case.

: "${TESTS_ROOT:?helpers.sh: TESTS_ROOT must be set}"
: "${PROD_SCRIPT:?helpers.sh: PROD_SCRIPT must be set}"

# PATH as it was when this file was sourced. run_script() prepends the sandbox stub
# bin to THIS value rather than to the ambient $PATH, so a case that narrows PATH
# for one child cannot change how later runs resolve tools.
# shellcheck disable=SC2034  # referenced by run_script below (same file scope)
PATH_PRE="$PATH"

CURRENT_OUT=''
# Set by run_script() for the CALLING case script to inspect (e.g. "the script
# exited non-zero"), so it is used across files rather than inside helpers.sh.
# shellcheck disable=SC2034  # read by case_*.sh after sourcing this file
LAST_STATUS=0

# Strips color/progress escapes for the loose text grep. The script emits some
# markers via a literal "\033[...m" string (backslash-0-3-3) rather than a real
# ESC byte, so strip both that and real ESC (\x1b / \e) sequences.
clean_sandbox_output() {
    sed -E 's#(\x1b|\\033|\\e)\[[0-9;]*m##g' "$CURRENT_OUT"
}

###############################################################################
# Sandbox creation / teardown
###############################################################################

# make_sandbox <var_name>
#   Builds: sbx/bin/{flac,metaflac} stubs, sbx/lib (library root), sbx/lib_backup
#   (the configured backup root), the config file the script reads, and a copy of
#   the script. Sets $<var_name> to the sbx root.
#
#   backup_path is seeded EXPLICITLY (as a sibling of the library) rather than left
#   to the derived '<library>_backup' default, so cases never depend on the
#   derivation prompt and the tree is always at "$sbx/lib_backup".
make_sandbox() {
    local _vn="$1"
    local sbx
    sbx="$(mktemp -d "${TMPDIR:-/tmp}/flac_test_XXXXXX")"
    mkdir -p "$sbx/bin" "$sbx/lib" "$sbx/lib_backup"
    cp "$TESTS_ROOT/stub_flac"        "$sbx/bin/flac"
    cp "$TESTS_ROOT/stub_metaflac"    "$sbx/bin/metaflac"
    chmod +x "$sbx/bin/flac" "$sbx/bin/metaflac"
    cp "$PROD_SCRIPT" "$sbx/flac_health_reencode.sh"
    # 'jobs' is pinned to 1 in every sandbox on purpose: the pre-existing cases
    # were written against strictly-sequential behavior (status lines in file
    # order, tallies equal to the file count) and stay the regression anchor for
    # it. Parallel behavior has its own case (case_parallel.sh).
    printf '{"library_path": "%s", "backup_path": "%s", "version": "1.1", "jobs": 1}\n' \
        "$sbx/lib" "$sbx/lib_backup" > "$sbx/flac_health_config.json"
    printf -v "$_vn" '%s' "$sbx"
}

# register_sandbox <sbx> : rm -rf on EXIT (idempotent). Call once per case.
REGISTERED=( )
_auto_clean() { local s; for s in "${REGISTERED[@]}"; do rm -rf "$s"; done; }
register_sandbox() {
    REGISTERED+=("$1")
    trap _auto_clean EXIT
}

###############################################################################
# Running the script + primitives
###############################################################################

# run_script <sbx> [stdin lines...]
#   Runs the real script against the sandbox stubs. The script is expected to end
#   (via errexit on the final menu read at EOF) with a non-zero status; that is NOT
#   a failure of this helper, so the pipeline runs under an `if` to keep it from
#   tripping the case's `set -e`. The child's exit code lands in LAST_STATUS.
#
# LAST_STATUS / CURRENT_OUT are the helper's public outputs: the case scripts that
# source this file read them after the call, so shellcheck's "appears unused"
# (SC2034) does not apply within this file.
# shellcheck disable=SC2034
run_script() {
    local sbx="$1"; shift
    CURRENT_OUT="$sbx/output.log"
    # PATH_PRE is the PATH captured at source time: a case that narrows PATH for
    # its own child (case_requirements.sh) must not leak that into these runs.
    if printf '%s\n' "$@" | PATH="$sbx/bin:$PATH_PRE" bash "$sbx/flac_health_reencode.sh" \
            > "$CURRENT_OUT" 2>&1; then
        LAST_STATUS=0
    else
        LAST_STATUS=$?
    fi
    return 0
}

# run_script_env <sbx> <ENV=VAL...> -- <stdin lines...>
#   Same as run_script, but with extra environment variables in scope (e.g.
#   FLAC_HEALTH_JOBS, STUB_FLAC_SLEEP). Keeping the assignment in the command
#   prefix rather than export'ing it stops a case leaking an override into a later
#   run. Outputs are set exactly as run_script's.
run_script_env() {
    local sbx="$1"; shift
    local envs=()
    while [ "$#" -gt 0 ] && [ "$1" != '--' ]; do
        envs+=("$1"); shift
    done
    [ "${1:-}" = '--' ] && shift
    CURRENT_OUT="$sbx/output.log"
    if printf '%s\n' "$@" | env "${envs[@]}" PATH="$sbx/bin:$PATH_PRE" \
            bash "$sbx/flac_health_reencode.sh" > "$CURRENT_OUT" 2>&1; then
        # shellcheck disable=SC2034  # read by case_*.sh after sourcing this file
        LAST_STATUS=0
    else
        # shellcheck disable=SC2034  # read by case_*.sh after sourcing this file
        LAST_STATUS=$?
    fi
    return 0
}

# Convenience alias for the active log path.
out() { printf '%s\n' "$CURRENT_OUT"; }

# ===========================================================================
# Loose output assertions (all read CURRENT_OUT)
# ===========================================================================

_fail() {
    echo "  FAIL: $*" >&2
    exit 1
}

# occur_re <needle regex>        : PASS if needle matches CURRENT_OUT (regex)
occur_re() {
    grep -qE -- "$1" <(clean_sandbox_output) || _fail "output missing: $1"
}

# absent_re <needle regex>       : PASS if needle does NOT match CURRENT_OUT
absent_re() {
    grep -qE -- "$1" <(clean_sandbox_output) && _fail "output unexpectedly has: $1" || return 0
}

# captured_count <regex>         : echo the first captured numeric group
captured_count() {
    local m
    m="$(clean_sandbox_output | grep -oE -- "$1" | head -n1 | sed -E "s/$1/\\1/")"
    [ -n "$m" ] || _fail "no count matched regex: $1"
    printf '%s\n' "$m"
}

# message_count <regex>          : how many distinct lines in CURRENT_OUT contain regex
message_count() {
    clean_sandbox_output | grep -cE -- "$1"
}

# ===========================================================================
# Filesystem / state assertions
# ===========================================================================

exist() { [ -e "$1" ] || _fail "expected to exist: $1"; return 0; }
miss()  { [ ! -e "$1" ] || _fail "expected to NOT exist: $1"; return 0; }

# soft_file_eq <path> <expected-content>  : exact whole-file content compare
file_eq() {
    local got
    got="$(cat "$1" 2>/dev/null || true)"
    [ "$got" = "$2" ] || _fail "content mismatch for $1"
    return 0
}

# db_has_path <sbx> <absolute-path>
#   Rows are "<md5> <size> <mtime> <path>", path LAST (so it may contain spaces).
#   Passes iff a row ENDS with the path: drop the first three tokens and compare
#   the rebuilt remainder exactly.
db_has_path() {
    local sbx="$1" path="$2" db
    db="$sbx/lib/.flac_scan_data/reencoded.db"
    [ -f "$db" ] || _fail "expected db at $db"
    local line tokens rest
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in \#*|'') continue ;; esac
        read -r -a tokens <<< "$line"
        rest="${tokens[*]:3}"
        [ "$rest" = "$path" ] && return 0
    done < "$db"
    _fail "db lacks entry for: $path"
}

# ===========================================================================
# Fixtures
# ===========================================================================

# write_file <path> <content>   : no trailing newline (control EXACT bytes).
write_file() { printf '%s' "$2" > "$1"; }

# Content-marker contract with the stubs (see the stub headers):
#   * appending 'CORRUPT' makes the stub's `flac -t` FAIL.
#   * a successful stub reencode REPLACES the target with 'REENCODE_OK' -- no
#     backup ever carries it, so "backup untouched" is a file_eq against this.
# Read by case_*.sh (which source this file), not within helpers.sh itself.
# shellcheck disable=SC2034
RE_MARKER='REENCODE_OK'


