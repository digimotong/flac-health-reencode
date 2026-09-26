#!/usr/bin/env bash
# case_fixture_pcm.sh - UNIT: the manual harness's PCM fixture generator emits a
# byte-exact stream that real flac will accept.
#
# WHY THIS CASE EXISTS, AND WHY IT IS HERMETIC
#   tests/manual/lib.sh used to build its fixture with awk's `printf "%c%c", ...`.
#   POSIX only requires %c to interpret the argument as a character, and in a
#   multibyte locale gawk does so as a WIDE character, emitting the full UTF-8
#   sequence for any value >= 0x80 (one sample's low octet, constantly). The PCM
#   then grew past frames*4 bytes, was no longer 4-aligned, and the real flac in
#   the manual-real-flac CI job died with "ERROR: got partial sample" - a message
#   that names a temp file and points nowhere near the generator. On a host whose
#   awk is byte-oriented (mawk, Ubuntu's default and this repo's dev containers) the
#   bug is invisible, so the manual harness passed locally and failed in CI.
#
#   That job is NOT required, and it SKIPs entirely when flac is missing, so it can
#   never be the guard for this. This case needs no flac and no multibyte awk: it
#   asserts the properties that flac depends on, straight from the generator. The
#   ASCII-only assertion (A) is the actual regression guard - it fails against the
#   old `%c` generator on ANY awk, mawk included, which is what makes it provable
#   here rather than only on the affected runner.
#
# Not asserted: the exact sample values (the seeded LCG's sequence is an
# implementation detail), the number of escape lines, or the frame default.

set -o errexit
set -o nounset
set -o pipefail

: "${TESTS_ROOT:?}"
: "${PROD_SCRIPT:?}"
. "$TESTS_ROOT/helpers.sh"

# The generator under test lives in the manual harness, which run_manual.sh does
# not run here; sourcing lib.sh only DEFINES its helpers (its only side effects are
# the sandbox list, an EXIT trap that no-ops on an empty list, and a PROD_SCRIPT
# guard, which the harness above already exports) so this case can call it directly.
. "$TESTS_ROOT/manual/lib.sh"

# Small enough to stay instant, long enough that the seeded stream certainly covers
# octets >= 0x80 and NUL: 2000 stereo frames = 8000 bytes, as in case A below.
FRAMES=2000
WANT=$(( FRAMES * 4 ))

WORK="$(mktemp -d "${TMPDIR:-/tmp}/flac_case_pcm_XXXXXX")"
register_sandbox "$WORK"

# ===========================================================================
# A. The intermediate is pure ASCII, so no locale or awk can reinterpret it.
#    THIS is the regression guard: the old "printf %c" generator is binary
#    output, so it fails here even where its byte count happens to be right.
# ===========================================================================
ESC="$WORK/escapes.txt"
mlib_pcm_escapes 1 "$FRAMES" > "$ESC"

total="$(tr -d '\n' < "$ESC" | wc -c)"
printable="$(tr -d '\n' < "$ESC" | tr -dc '\040-\176' | wc -c)"
[ "$total" -gt 0 ] || _fail "mlib_pcm_escapes produced no output"
[ "$printable" -eq "$total" ] || _fail \
    "mlib_pcm_escapes output is not pure ASCII: only $printable of $total bytes are printable
      (a non-ASCII byte means a character/byte-width assumption, i.e. the %c bug class)"
# Octal escapes only: every line must be runs of \ddd. Guards against a generator
# that quietly starts emitting raw bytes again but happens to stay printable.
grep -qE '^([\\][0-7]{3})+$' "$ESC" || _fail \
    "mlib_pcm_escapes output is not made of \\\\ddd escapes"


# ===========================================================================
# B. Direct bytes: exactly frames*4, i.e. 4-aligned. This is the property real
#    flac enforces with "ERROR: got partial sample".
# ===========================================================================
PCM="$WORK/a.bin"
mlib_make_pcm "$PCM" 1 "$FRAMES"
got="$(wc -c < "$PCM")"
[ "$got" -eq "$WANT" ] || _fail \
    "mlib_make_pcm wrote $got bytes for $FRAMES stereo 16-bit frames, expected $WANT"

# ===========================================================================
# C. NUL octets survive the escape -> printf '%b' round trip. A consumer that
#    went through $(...) or a text-only path would drop or mangle them, and one
#    lost byte is exactly the 4-alignment failure this case guards.
# ===========================================================================
nul="$(tr -cd '\000' < "$PCM" | wc -c)"
[ "$nul" -gt 0 ] || _fail "mlib_make_pcm wrote no NUL octets; escape decoding dropped byte 0x00"

# ===========================================================================
# D. Determinism per seed (the harness's equivalence check compares two sandboxes
#    built from the same seed) and variation across seeds.
# ===========================================================================
PCM_SAME="$WORK/b.bin"
PCM_OTHER="$WORK/c.bin"
mlib_make_pcm "$PCM_SAME" 1 "$FRAMES"
mlib_make_pcm "$PCM_OTHER" 2 "$FRAMES"
cmp -s "$PCM" "$PCM_SAME" || _fail "same seed produced different PCM (not deterministic)"
if cmp -s "$PCM" "$PCM_OTHER"; then
    _fail "different seeds produced identical PCM (generator ignores the seed)"
fi

# ===========================================================================
# E. Locale invariance: byte-for-byte identical under the C locale and whatever
#    UTF-8 locale this host has. This is the direct expression of the bug - the
#    fixture must not depend on the locale at all.
# ===========================================================================
LOCALE_UTF8="$(locale -a 2>/dev/null | grep -iE '^(C\.)?UTF-?8$' | head -n1 || true)"
if [ -n "$LOCALE_UTF8" ]; then
    PCM_C="$WORK/d.bin"
    PCM_UTF8="$WORK/e.bin"
    # One helper, called twice in a child shell whose LC_ALL differs. Writing it as
    # a function keeps the locale change and the call in the SAME subshell, so there
    # is no "modified in a subshell" confusion (shellcheck SC2030/SC2031) and the
    # caller's locale is untouched.
    make_pcm_under_locale() {
        ( export LC_ALL="$1"; mlib_make_pcm "$2" 1 "$FRAMES" )
    }
    make_pcm_under_locale C "$PCM_C"
    make_pcm_under_locale "$LOCALE_UTF8" "$PCM_UTF8"
    cmp -s "$PCM_C" "$PCM_UTF8" || _fail \
        "PCM differs between LC_ALL=C and LC_ALL=$LOCALE_UTF8 (locale-dependent fixture)"
    echo "ok: case_fixture_pcm (bytes=$WANT, nul=$nul, locales C/$LOCALE_UTF8)"
else
    echo "ok: case_fixture_pcm (bytes=$WANT, nul=$nul, no UTF-8 locale to compare)"
fi
