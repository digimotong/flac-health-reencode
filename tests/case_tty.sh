#!/usr/bin/env bash
# case_tty.sh - integration: the interactive (stdout-is-a-TTY) rendering branch.
#
# WHY THIS CASE NEEDS A PSEUDO-TERMINAL: the other cases run the script through
# run_script(), which redirects stdout to a file. There `[ -t 1 ]` is ALWAYS false, so
# every `if stdout_is_tty` branch is dead as far as the rest of the suite is concerned -
# the animated progress bar, the colorised scan summary and the "Library: <path>" banner
# were unexercised. This case uses `script -qec`, which attaches the child to a real PTY,
# and asserts the TTY-only output the plain-text branch never produces:
#
#   * the single-line progress bar framed by \r ... \033[K (show_progress)
#   * the colorised "Scan complete." summary (printf with $GREEN/$NC)
#   * the colorised "Library: <path>" banner in the menu
#
# A control run WITHOUT the PTY asserts the same markers are ABSENT, so the two together
# pin the branch both ways: taken on a tty, not taken otherwise. Without the negative
# control, "the marker appeared" would not prove the branch was chosen.
#
# It also pins that the live bar REACHES 100%: it is driven by completed files, and it
# once stayed frozen at "0% (0/N)" for a whole run.
#
# `script` missing (or lacking PTY support) reports a SKIP rather than failing.

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

# If `script` cannot give us a tty at all, skip instead of reporting a false failure: an
# environment limitation, not a product defect. (stdin via a file, not a pipe: see
# run_under_pty below.)
if ! timeout 10 script -qec 'test -t 1' /dev/null < /dev/null > /dev/null 2>&1; then
    echo "SKIP: case_tty ('script' cannot allocate a PTY here)"
    exit 0
fi

# The tty branch is reached at runtime, so the output holds a real ESC byte (0x1b) rather
# than the literal "\033" text. Compute the raw escape here so the assertions are
# unambiguous.
ESC="$(printf '\033')"

# Build a library with one good and one CORRUPT file, and the stdin script that drives
# option 1 (scan).
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
#     * 'script -c' executes its argument with /bin/sh, so PATH is assigned AND exported
#       inside the child command rather than prefixed on it. A bare `VAR=x bash` prefix
#       would apply only to that 'sh', and the later `bash` lookup would then fail with
#       exit 127.
#     * stdin comes from a FILE, never a pipe. Feeding `printf ... | script` makes the run
#       block indefinitely (the pipe closes while the PTY master still waits), which
#       surfaced as this case hanging until the runner's per-case timeout killed it. A
#       redirected regular file is read normally and the run ends on EOF like every other
#       case.
#     * TERM is pinned EXPLICITLY. This case asserts the live-bar branch, and the script
#       deliberately falls back to plain lines for TERM=dumb; util-linux 'script' sets
#       TERM=dumb on the child when TERM is UNSET, which is exactly how GitHub Actions
#       runs its steps - so inheriting the ambient TERM made the result depend on the
#       runner and turned CI red while a normal developer shell stayed green.
#       PTY_TERM overrides the pinned value (the dumb-terminal case below uses it).
#       A plain 'xterm' is the fallback so a machine without the -256color terminfo
#       entry (and no 'tput') still gets a working live bar: the script only needs
#       '\r' and ASCII, not a feature-rich terminfo.
if [ -z "${PTY_TERM:-}" ]; then
    if infocmp xterm-256color >/dev/null 2>&1; then
        PTY_TERM='xterm-256color'
    else
        PTY_TERM='xterm'
    fi
fi
run_under_pty() {
    local sbx="$1"; shift
    CURRENT_OUT="$sbx/pty_output.log"
    local stdin_file child
    stdin_file="$sbx/pty_stdin.txt"
    printf '%s\n' "$@" > "$stdin_file"
    child="TERM='$PTY_TERM'; export TERM; PATH='$sbx/bin:$PATH'; export PATH;"
    child="$child exec bash '$sbx/flac_health_reencode.sh'"
    if timeout 30 script -qec "$child" /dev/null \
            < "$stdin_file" > "$CURRENT_OUT" 2>&1; then
        LAST_STATUS=0
    else
        LAST_STATUS=$?
    fi
    return 0
}

# tty_occur_re <needle regex>
#   Like occur_re but WITHOUT clean_sandbox_output's escape stripping, because this case
#   asserts the presence of those very escape sequences. The script emits two flavours of
#   colour (a real ESC byte in most places, and a literal backslash-033 string in a few),
#   so patterns below match the plain words and the surrounding bytes separately.
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

# 1. The scan summary is the COLOURISED variant. These printf calls use '%b', which (like
#    the original `printf "${GREEN}...${NC}"` format string) INTERPRETS the \033 in the
#    colour variables, so the real ESC byte must be on the wire. Asserting the real byte
#    here is what makes this case a true regression test for the colouring: a rewrite to
#    plain '%s' would emit the literal text "\033[0;32m" and fail these checks.
tty_occur_re 'Scan complete\.'
tty_occur_re "${ESC}\[0;32mScan complete\."
tty_occur_re "${ESC}\[0;31m"                    # red error line
tty_occur_re "${ESC}\[1;33m"                    # yellow numbers

# 2. The animated single-line bar: a \r-prefixed framed bar followed by the
#    clear-to-end-of-line sequence that overwrites it in place. Neither appears in the
#    non-tty branch, and the frame is the discriminator.
tty_occur_re "\[#+-*\] +[0-9]+% \(1/2\)"
tty_occur_re "${ESC}\[K"

# 3. The colourised "Library: <path>" banner must carry a real ESC too.
tty_occur_re "${ESC}\[0;32mLibrary: "

# 4. The live bar must reach completion: the final frame of a finished run is
#    "100% (N/N)". This is the regression anchor for the bar that used to stay
#    frozen at "0% (0/N)" because it was drawn from an unfilled counter.
tty_occur_re "\\[#+\\] +100% \\(2/2\\)"

# 5. Guard the specific bug this case was written to catch: the literal backslash-033 text
#    must NEVER reach the terminal (that would mean a printf lost its escape
#    interpretation).
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
# And no animated bar was drawn at all: the live form is TTY-only. (This sandbox
# runs jobs=1, and a captured sequential run reports through its per-file lines
# rather than a bar, so no "Progress:" line may appear either.)
absent_re 'Progress: \[#'
echo "ok: case_tty (non-tty control emits no escapes and no bar)"

# ===========================================================================
# TERM=dumb on a PTY must degrade to PLAIN lines, not the animated one.
# ===========================================================================
# The script treats a dumb terminal as "cannot redraw in place": no carriage
# return and no erase sequence, but progress is still reported as ordinary
# "Progress: ..." lines. Pinned here because it is the fallback that keeps a text
# console readable, and because util-linux 'script' hands the child TERM=dumb
# whenever TERM is unset (see run_under_pty) - so this branch is easy to hit by
# accident and must be covered deliberately.
SBX3=''
make_sandbox SBX3
register_sandbox "$SBX3"
mkdir_library "$SBX3"

PTY_TERM=dumb run_under_pty "$SBX3" '1' '' 'q'

[ "$LAST_STATUS" -eq 0 ] || _fail "dumb-term run exited $LAST_STATUS, expected 0"
# Still a complete, readable scan ...
occur_re 'Scan complete\.'
# ... reported as plain lines ...
occur_re 'Progress: \[#'
# ... with none of the live display's control bytes.
absent_re "${ESC}\[K"
# The script's own in-place redraw shows up as a line that STARTS with a carriage return,
# which a dumb terminal must never receive. Bare '\r' bytes are NOT that: the PTY's line
# discipline (onlcr) turns every '\n' into CRLF, and an echoed blank input line becomes a
# lone "\r\n" - both look like a leading CR to awk. So the check ignores empty lines and
# looks only at real content.
if LC_ALL=C awk '/^\r/ && /[^\r]/ { found = 1 } END { exit found ? 0 : 1 }' "$CURRENT_OUT"; then
    _fail "TERM=dumb run used in-place redraws (a content line starts with a carriage return)"
fi
echo "ok: case_tty (TERM=dumb falls back to plain progress lines)"

