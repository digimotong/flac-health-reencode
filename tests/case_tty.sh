#!/usr/bin/env bash
# case_tty.sh - integration: the interactive (stdout-is-a-TTY) rendering branch.
#
# WHY THIS CASE NEEDS A PSEUDO-TERMINAL
#   The other cases run the script through run_script(), which redirects stdout to a
#   file. There `[ -t 1 ]` is ALWAYS false, so every `if stdout_is_tty` branch is
#   dead as far as the rest of the suite is concerned: the animated progress bar,
#   the colorised scan summary and the "Library: <path>" banner were unexercised.
#   This case uses `script -qec`, which attaches the child to a real PTY, and
#   asserts the TTY-only output the plain-text branch never produces:
#
#     * the single-line progress bar framed by \r ... \033[K (show_progress)
#     * the colorised "Scan complete." summary (printf with $GREEN/$NC)
#     * the colorised "Library: <path>" banner in the menu
#
#   A control run WITHOUT the PTY asserts the same markers are ABSENT, so the two
#   together pin the branch both ways: taken on a tty, not taken otherwise. Without
#   the negative control, "the marker appeared" would not prove the branch was chosen.
#
#   `script` missing (or lacking PTY support) is harmless: the case reports a SKIP
#   rather than failing, so the suite stays portable.

set -o errexit
set -o nounset
set -o pipefail

: "${TESTS_ROOT:?}"
: "${PROD_SCRIPT:?}"
. "$TESTS_ROOT/helpers.sh"

if ! command -v script > /dev/null 2>&1; then
    echo "SKIP: case_tty (util-linux 'script' not available for PTY allocation)"
    exit 0
fi

# If `script` cannot give us a tty at all, skip instead of reporting a false
# failure: an environment limitation, not a product defect. (stdin via a file, not a
# pipe: see run_under_pty below.)
if ! timeout 10 script -qec 'test -t 1' /dev/null < /dev/null > /dev/null 2>&1; then
    echo "SKIP: case_tty ('script' cannot allocate a PTY here)"
    exit 0
fi

# The scan output logs emitted with a real ESC byte (0x1b) rather than the literal
# "\033" text, because the tty branch is reached at runtime. Compute the raw escape
# here so the assertions below are unambiguous.
ESC="$(printf '\033')"

# Build a library with one good and one CORRUPT file, and the stdin script that
# drives option 1 (scan).
mkdir_library() {
    local sbx="$1"
    mkdir -p "$sbx/lib/Album"
    write_file "$sbx/lib/Album/good.flac"    'PCM_DATA'
    write_file "$sbx/lib/Album/corrupt.flac" 'PCM_DATA_CORRUPT'
}

# run_under_pty <sbx> [stdin lines...]
#   Runs the sandbox script attached to a PTY. The PTY's output is captured to
#   CURRENT_OUT (CRLF line endings and raw escapes included).
#
#   Three subtleties, all learned the hard way:
#     * 'script -c' executes its argument with /bin/sh, so PATH is assigned AND
#       exported inside the child command rather than prefixed on it. A bare
#       `VAR=x bash` prefix would apply only to that 'sh', and the later `bash`
#       lookup would then fail with exit 127.
#     * stdin comes from a FILE, never a pipe. Feeding `printf ... | script`
#       makes the run block indefinitely (the pipe closes while the PTY master
#       still waits), which surfaced as this case hanging until the runner's
#       per-case timeout killed it. A redirected regular file is read normally
#       and the run ends on EOF like every other case.
#     * `timeout` is applied locally too, so even a PTY hiccup fails THIS case
#       promptly instead of consuming the suite's whole budget.
run_under_pty() {
    local sbx="$1"; shift
    CURRENT_OUT="$sbx/pty_output.log"
    local stdin_file child
    stdin_file="$sbx/pty_stdin.txt"
    printf '%s\n' "$@" > "$stdin_file"
    child="PATH='$sbx/bin:$PATH'; export PATH; exec bash '$sbx/flac_health_reencode.sh'"
    if timeout 30 script -qec "$child" /dev/null \
            < "$stdin_file" > "$CURRENT_OUT" 2>&1; then
        LAST_STATUS=0
    else
        LAST_STATUS=$?
    fi
    return 0
}

# tty_occur_re <needle regex>
#   Like occur_re but WITHOUT clean_sandbox_output's escape stripping, because
#   this case asserts the presence of those very escape sequences. The script
#   emits two flavours of colour (a real ESC byte in most places, and a literal
#   backslash-033 string in a few), so patterns below match the plain words and
#   the surrounding bytes separately.
tty_occur_re() {
    grep -qE -- "$1" "$CURRENT_OUT" || _fail "tty output missing: $1"
}

# ===========================================================================
# TTY run: option 1 scan must take the animated/colourised branch.
# ===========================================================================
SBX=''
make_sandbox SBX
register_sandbox "$SBX"
mkdir_library "$SBX"

run_under_pty "$SBX" '1' '' 'q'

[ "$LAST_STATUS" -eq 0 ] || _fail "tty run exited $LAST_STATUS, expected 0"

# 1. The scan summary is the COLOURISED variant. These printf calls use '%b',
#    which (like the original `printf "${GREEN}...${NC}"` format string)
#    INTERPRETS the \033 in the colour variables, so the real ESC byte must be
#    on the wire. Asserting the real byte here is what makes this case a true
#    regression test for the colouring: a rewrite to plain '%s' would emit the
#    literal text "\033[0;32m" and fail these checks.
tty_occur_re 'Scan complete\.'
tty_occur_re "${ESC}\[0;32mScan complete\."
tty_occur_re "${ESC}\[0;31m"                    # red error line
tty_occur_re "${ESC}\[1;33m"                    # yellow numbers

# 2. The animated single-line bar: a \r-prefixed framed bar followed by the
#    clear-to-end-of-line sequence that overwrites it in place. Neither appears
#    in the non-tty branch, and the frame is the discriminator.
tty_occur_re "\[#+-*\] +[0-9]+% \(1/2\)"
tty_occur_re "${ESC}\[K"

# 3. The colourised "Library: <path>" banner must carry a real ESC too.
tty_occur_re "${ESC}\[0;32mLibrary: "

# 4. Guard the specific bug this case was written to catch: the literal
#    backslash-033 text must NEVER reach the terminal (that would mean a printf
#    lost its escape interpretation).
if grep -qF '\033[' "$CURRENT_OUT"; then
    _fail "tty output contains literal '\\033[' text instead of a real ESC byte"
fi

echo "ok: case_tty (tty branch renders colour + animated progress)"

# ===========================================================================
# Negative control: the SAME run without a PTY must NOT emit those escapes.
# ===========================================================================
SBX2=''
make_sandbox SBX2
register_sandbox "$SBX2"
mkdir_library "$SBX2"

run_script "$SBX2" '1' '' 'q'

# Plain-text branch: the words are there ...
occur_re 'Scan complete\.'
# ... but the colourised form and the bar-clearing escapes are not.
absent_re "${ESC}\[K"
grep -qE -- "${ESC}\[" "$CURRENT_OUT" \
    && _fail "non-tty run emitted real ESC sequences"
# The bar is a plain, self-terminated "Progress: [...]" line instead.
occur_re 'Progress: \[#+-*\]'

echo "ok: case_tty (non-tty control emits no escapes)"

