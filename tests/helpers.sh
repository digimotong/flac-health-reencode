#!/usr/bin/env bash
###############################################################################
# helpers.sh - shared sandbox + loose-assertion harness for case_*.sh
#
# Conventions
#   - Each test case runs the REAL flac_health_reencode.sh as a subprocess
#     against its own throwaway sandbox (fresh library tree + stub bin + config)
#     so the developer's real config/library are never touched.
#   - run_script sets $CURRENT_OUT to that run's combined-output log. Every
#     output assertion below reads CURRENT_OUT, keeping case call sites terse.
#   - Assertions are deliberately LOOSE relative to exact-output matching:
#       * occurrence of short, stable regex markers
#       * file exists / not-exists / content                 (strong checks)
#       * counts parsed out of a line by a regex helper
#       * DB / backup side effects (the reliable consequence checks)
#     Whole rendered sentences, progress bars, spacing, and timestamps are NOT
#     matched, so cosmetic wording changes don't break the suite.
#   - A failed assertion prints a readable message and exits 1 from the case.
###############################################################################

: "${TESTS_ROOT:?helpers.sh: TESTS_ROOT must be set}"
: "${PROD_SCRIPT:?helpers.sh: PROD_SCRIPT must be set}"

CURRENT_OUT=''
LAST_STATUS=0

# Strip color / progress escape sequences for the loose text grep. The script
# emits some markers VIA a literal "\033[...m" string (backslash-0-3-3) rather
# than a real ESC byte, so strip both that and real ESC (\x1b / \e) sequences,
# leaving the plain words/numbers to match on.
clean_sandbox_output() {
    sed -E 's#(\x1b|\\033|\\e)\[[0-9;]*m##g' "$CURRENT_OUT"
}

###############################################################################
# Sandbox creation / teardown
###############################################################################

# make_sandbox <var_name>
#   Builds: sbx/bin/{flac,metaflac} stubs, sbx/lib (library root), the config
#   file the production script reads (pointing at sbx/lib), and a copy of the
#   script. Sets $<var_name> to the sbx root.
make_sandbox() {
    local _vn="$1"
    local sbx
    sbx="$(mktemp -d "${TMPDIR:-/tmp}/flac_test_XXXXXX")"
    mkdir -p "$sbx/bin" "$sbx/lib"
    cp "$TESTS_ROOT/stub_flac"        "$sbx/bin/flac"
    cp "$TESTS_ROOT/stub_metaflac"    "$sbx/bin/metaflac"
    chmod +x "$sbx/bin/flac" "$sbx/bin/metaflac"
    cp "$PROD_SCRIPT" "$sbx/flac_health_reencode.sh"
    printf "{\"library_path\": \"%s\"}\n" "$sbx/lib" > "$sbx/flac_health_config.json"
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
#   (via errexit on the final menu read at EOF) with a non-zero status; that is
#   NOT a failure of this helper, so the pipeline runs under an `if` to keep it
#   from tripping the case's `set -e`. The child's exit code is recorded in
#   LAST_STATUS for cases that want to inspect it.
run_script() {
    local sbx="$1"; shift
    CURRENT_OUT="$sbx/output.log"
    if printf '%s\n' "$@" | PATH="$sbx/bin:$PATH" bash "$sbx/flac_health_reencode.sh" \
            > "$CURRENT_OUT" 2>&1; then
        LAST_STATUS=0
    else
        LAST_STATUS=$?
    fi
    return 0
}

# Convenience alias for the active log path.
out() { printf '%s\n' "$CURRENT_OUT"; }

###############################################################################
# Loose output assertions (all read CURRENT_OUT)
###############################################################################

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

###############################################################################
# Filesystem / state assertions
###############################################################################

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
#   reencoded.db rows are "<md5> <size> <mtime> <path>" -- the path is the LAST
#   field (so it may contain spaces). Passes iff any row ENDS with the path.
db_has_path() {
    local sbx="$1" path="$2" db
    db="$sbx/lib/.flac_scan_data/reencoded.db"
    [ -f "$db" ] || _fail "expected db at $db"
    # Parsing: each row is "<md5> <size> <mtime> <path>" where <path> is the LAST
    # field (may contain spaces). Drop the first three space-delimited tokens and
    # rebuild the remainder -- that remainder must equal $path exactly.
    local line tokens rest
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in \#*|'') continue ;; esac
        read -r -a tokens <<< "$line"
        rest="${tokens[*]:3}"
        [ "$rest" = "$path" ] && return 0
    done < "$db"
    _fail "db lacks entry for: $path"
    return 1
}

###############################################################################
# Fixtures
###############################################################################

# write_file <path> <content>   : no trailing newline (control EXACT bytes).
write_file() { printf '%s' "$2" > "$1"; }

# Content-marker contract with the stubs (kept short here; see stub headers):
#   * appending 'CORRUPT' to a file makes the stub's `flac -t` FAIL.
#   * a successful stub reencode REPLACES the target file with content
#     'REENCODE_OK' -- backups tracked by these tests never carry it, so
#     "backup untouched by reencode" is checked via file_eq against the marker.
RE_MARKER='REENCODE_OK'


