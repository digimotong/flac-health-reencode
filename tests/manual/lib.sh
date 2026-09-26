#!/usr/bin/env bash
# lib.sh - shared helpers for the REAL-flac manual harness (tests/manual/).
#
# WHY THIS EXISTS, SEPARATE FROM tests/helpers.sh
#   The main suite (tests/case_*.sh) stubs flac/metaflac, so it proves the
#   scheduler/sharding logic but can never prove that a REAL flac round-trip
#   preserves audio, that backups are byte-identical, or that a real concurrent
#   run survives storage faults. This harness complements it by operating on real
#   binaries and real files, but ONLY inside throwaway sandboxes under TMPDIR.
#
# CONTRACT WITH THE RUNNER (tests/manual/run_manual.sh)
#   Each script sources this file, calls mlib_require_real_tools OR
#   mlib_require_basic_tools, then does its work. A missing tool must print a
#   single line beginning "SKIP:" and exit 0 - that is how the harness stays green
#   in a container without flac while still being a real gate on a server. Any
#   other non-zero exit is a FAIL.
#
# NOT part of tests/run_tests.sh: the runner globs only tests/case_*.sh, so these
# scripts never run in the stubbed CI suite. They are exercised by
# tests/manual/run_manual.sh, which CI runs only in the (non-required) job that
# installs the flac package - see .github/workflows/tests.yml.

set -o errexit
set -o nounset
set -o pipefail

: "${PROD_SCRIPT:?lib.sh: PROD_SCRIPT must point at flac_health_reencode.sh}"

# Every sandbox this harness creates, removed on EXIT. A failure anywhere must not
# leave a synthetic library (and its backups) behind.
#
# The explicit `return 0` is load-bearing, not stylistic: this runs as an EXIT trap,
# so its status BECOMES the script's exit status. When the list is empty (the SKIP
# paths, which never create a sandbox) the `[ -n "$d" ] && rm -rf "$d"` line is
# never reached by the loop, and without the `return 0` the trailing `done` leaves
# the function at status 1 - turning every clean SKIP into a spurious FAIL.
MLIB_SANDBOXES=()
mlib_cleanup() {
    local d
    for d in "${MLIB_SANDBOXES[@]:-}"; do
        if [ -n "$d" ]; then
            rm -rf "$d" || true
        fi
    done
    return 0
}
trap mlib_cleanup EXIT

# mlib_log <msg> : progress line, prefixed so the runner's output is readable.
mlib_log() { printf '    .. %s\n' "$*"; }

# mlib_fail <msg> : report and exit non-zero (the runner records a FAIL).
mlib_fail() { printf '  FAIL: %s\n' "$*" >&2; exit 1; }

# mlib_require_basic_tools : jq + md5sum, needed even by scripts that only inspect
# outputs. Prints SKIP and exits 0 when either is missing.
mlib_require_basic_tools() {
    local t
    for t in jq md5sum; do
        command -v "$t" >/dev/null 2>&1 \
            || { echo "SKIP: '$t' not installed (needed to inspect the script's output)"; exit 0; }
    done
}

# mlib_require_real_tools : flac + metaflac + jq + md5sum. The scripts that
# generate or verify real FLAC data call this; without the real binaries there is
# nothing meaningful to assert, so they SKIP rather than pass vacuously.
mlib_require_real_tools() {
    mlib_require_basic_tools
    local t
    for t in flac metaflac; do
        command -v "$t" >/dev/null 2>&1 \
            || { echo "SKIP: '$t' (real flac package) not installed - run this on a host with flac"; exit 0; }
    done
    return 0
}

# mlib_make_sandbox <var_name>
#   Builds a self-contained sandbox and points $<var_name> at it:
#       $sbx/bin/            (PATH shims, when a script installs any)
#       $sbx/lib/            (the library the script will operate on)
#       $sbx/backup/         (the configured backup root, an explicit sibling path)
#       $sbx/flac_health_reencode.sh   (a COPY of the production script)
#       $sbx/flac_health_config.json   (jobs: 1 by default; callers override)
#   A copy of the script is used so CONFIG_FILE resolves INSIDE the sandbox
#   (the script derives it from dirname $0), never the developer's real config.
#
#   The caller's variable is assigned through a NAME REFERENCE (`declare -n`). The
#   CALLER MUST HAVE ASSIGNED IT FIRST (e.g. `local sbx=''`): under `set -u`, which
#   lib.sh enables, a nameref to a declared-but-UNSET variable cannot be assigned,
#   and neither can `printf -v`, so `local sbx` alone fails with a confusing
#   "unbound variable". Every call site therefore starts the variable empty, and the
#   harness fails loudly and early if one forgets.
mlib_make_sandbox() {
    local -n _mlib_sandbox_target="$1"
    local -n _mlib_check="$1"
    local mlib_sbx
    # Fail with the harness's own message rather than a bare nounset abort.
    if ! declare -p _mlib_check >/dev/null 2>&1; then
        mlib_fail "mlib_make_sandbox: target variable '$1' is unset - declare it as '' first"
    fi
    mlib_sbx="$(mktemp -d "${TMPDIR:-/tmp}/flac_manual_XXXXXX")"
    MLIB_SANDBOXES+=("$mlib_sbx")
    _mlib_sandbox_target="$mlib_sbx"
    mkdir -p "$mlib_sbx/bin" "$mlib_sbx/lib" "$mlib_sbx/backup"
    cp "$PROD_SCRIPT" "$mlib_sbx/flac_health_reencode.sh"
    chmod +x "$mlib_sbx/flac_health_reencode.sh"
    mlib_set_config "$mlib_sbx" 1
    mlib_log "sandbox created at $mlib_sbx"
    return 0
}

# mlib_set_config <sbx> <jobs> : (re)write the sandbox config with a worker count.
mlib_set_config() {
    local sbx="$1" jobs="$2"
    printf '{"library_path": "%s", "backup_path": "%s", "version": "1.1", "jobs": %s}\n' \
        "$sbx/lib" "$sbx/backup" "$jobs" > "$sbx/flac_health_config.json"
}

# mlib_pcm_escapes <seed> [frames]
#   Deterministic 16-bit signed samples in [-16000,16000), stereo interleaved, as
#   ASCII-ONLY octal escapes ("\ddd" per octet, 1024 per line to stay readable).
#   A consumer turns it back into raw bytes with `printf '%b'` (see mlib_make_pcm).
#
# WHY ESCAPES AND NOT `printf "%c", v` -- THE BUG THIS ENCODES AROUND
#   The obvious byte emitter is `printf "%c%c", v % 256, int(v / 256) % 256`, and
#   on a byte-oriented awk (mawk, i.e. Ubuntu's default) that is exactly one octet
#   per conversion. But POSIX only requires %c to take the NUMERIC value of the
#   argument as a character, and in a multibyte locale gawk reads that as a WIDE
#   character, so it emits the whole UTF-8 sequence: for v % 256 = 233 that is two
#   bytes (0xC3 0xA9) instead of one. Any octet >= 0x80 occurs constantly in this
#   stream, so the PCM silently becomes longer than frames*4 bytes - not 4-aligned -
#   and real flac rejects it with "ERROR: got partial sample", which is what made
#   CI's manual-real-flac job fail while passing on containers whose awk is mawk.
#   Escaping sidesteps the whole question: octal escapes and `printf '%b'` are
#   byte-oriented by definition and cannot vary with the locale or the awk.
mlib_pcm_escapes() {
    local seed="$1" frames="${2:-30000}"
    awk -v n="$frames" -v s="$seed" 'BEGIN {
        x = s + 1
        k = 0
        for (i = 0; i < n; i++) {
            for (c = 1; c <= 2; c++) {
                x = (1103515245 * x + 12345) % 2147483648
                v = int((x / 2147483648) * 32000) - 16000
                if (v < 0) v += 65536
                printf "\\%03o\\%03o", v % 256, int(v / 256) % 256
                if (++k == 1024) { printf "\n"; k = 0 }
            }
        }
        if (k) printf "\n"
    }'
}

# mlib_make_pcm <path> <seed> [frames]
#   Writes frames*4 raw bytes (stereo/16-bit little-endian signed) at <path>, then
#   verifies the LENGTH ITSELF. That check is the point of this function: flac only
#   reports a 4-alignment violation indirectly, as a bare "ERROR: got partial
#   sample" naming the temp file, so a length bug reads like a flac problem. Here
#   it fails with both byte counts and the reason.
#
#   The `while read` + `printf '%b'` consumer (rather than one big `printf '%b' "$var"`)
#   keeps memory bounded and shellcheck's SC2059 quiet, and `|| [ -n "$line" ]`
#   handles a final line with no trailing newline. Both printfs are bash builtins,
#   so no locale conversion happens anywhere on the path.
mlib_make_pcm() {
    local path="$1" seed="$2" frames="${3:-30000}"
    local want=$(( frames * 4 )) got line
    mkdir -p "$(dirname "$path")"
    if ! mlib_pcm_escapes "$seed" "$frames" \
        | while IFS= read -r line || [ -n "$line" ]; do printf '%b' "$line"; done > "$path"; then
        rm -f "$path"
        mlib_fail "could not write PCM to $path"
    fi
    got=$(wc -c < "$path")
    if [ "$got" -ne "$want" ]; then
        rm -f "$path"
        mlib_fail "$path is $got bytes, expected $want ($frames stereo 16-bit frames);
        the PCM generator emitted a non-4-aligned stream, which real flac rejects"
    fi
    return 0
}

# mlib_make_flac <path> <seed> [frames]
#   Writes a REAL, decodable FLAC file from deterministic PCM. --force-raw-format
#   keeps this dependent only on flac itself (no sox/ffmpeg): the PCM comes from the
#   seeded generator above, so two sandboxes can be made byte-identical for the
#   equivalence check. Default length is ~0.7s of stereo/16-bit/44.1kHz - long
#   enough that a truncation is genuinely undecodable, short enough that a suite of
#   them stays well under a second.
mlib_make_flac() {
    local path="$1" seed="$2" frames="${3:-30000}"
    local pcm
    pcm="$(mktemp "${TMPDIR:-/tmp}/flac_pcm_XXXXXX")"
    mlib_make_pcm "$pcm" "$seed" "$frames"
    mkdir -p "$(dirname "$path")"
    flac --force-raw-format --endian=little --sign=signed --channels=2 --bps=16 \
        --sample-rate=44100 --silent --force -o "$path" "$pcm" \
        || { rm -f "$pcm"; mlib_fail "could not create a real FLAC at $path"; }
    rm -f "$pcm"
    return 0
}

# mlib_corrupt_truncate <flac_file> : drop the last ~6KB, destroying the frames
# (and usually the trailing metadata), so 'flac -t' must fail.
mlib_corrupt_truncate() {
    local f="$1" size
    size=$(wc -c < "$f")
    [ "$size" -gt 8192 ] || mlib_fail "file too small to corrupt by truncation: $f"
    truncate -s "$(( size - 6000 ))" "$f"
}

# mlib_corrupt_bytes <flac_file> <offset> : overwrite 800 bytes starting at
# <offset> with 0xFF, damaging frame data while leaving the file length intact.
# Used alongside a truncation so one file fails by size and one by content.
mlib_corrupt_bytes() {
    local f="$1" off="$2"
    head -c 800 /dev/zero | tr '\0' '\377' \
        | dd of="$f" bs=1 seek="$off" count=800 conv=notrunc status=none
}

# mlib_corrupt_tail <flac_file> : flip the LAST 512 bytes to 0xFF, which damages
# the trailing metadata/frame data a real decoder needs. Paired with the
# truncation above it gives two independent damage modes, and unlike a fixed
# offset it works on files of any length (a mid-file flip can land entirely in
# padding and leave a short file decodable).
mlib_corrupt_tail() {
    local f="$1" size
    size=$(wc -c < "$f")
    [ "$size" -gt 1024 ] || mlib_fail "file too small to corrupt by tail flip: $f"
    head -c 512 /dev/zero | tr '\0' '\377' \
        | dd of="$f" bs=1 seek="$(( size - 512 ))" count=512 conv=notrunc status=none
}

# mlib_run_menu <sbx> <menu-line> [more lines...]
#   Runs the sandbox script with the given menu answers, capturing combined output
#   to $sbx/run.out. Always returns 0 so a caller can inspect output and status
#   separately (status lands in mlib_last_status).
#
# mlib_last_status / the following function are the helper's public outputs (a
# caller reads mlib_last_status after the call), so shellcheck's "appears unused"
# (SC2034) does not apply within this file - the same note tests/helpers.sh makes
# about LAST_STATUS.
# shellcheck disable=SC2034
mlib_last_status=0
mlib_run_menu() {
    local sbx="$1"; shift
    local out="$sbx/run.out"
    if printf '%s\n' "$@" | bash "$sbx/flac_health_reencode.sh" > "$out" 2>&1; then
        mlib_last_status=0
    else
        # shellcheck disable=SC2034  # public output read by the caller, mirroring
        # tests/helpers.sh's LAST_STATUS convention
        mlib_last_status=$?
    fi
    mlib_log "ran the script with answers: $(printf '%s ' "$@")"
    return 0
}

# mlib_run_menu_bg <sbx> <out_file> [menu lines...]
#   Like mlib_run_menu but in the background, echoing the PID. Used by the
#   resilience script to interrupt a run mid-flight.
mlib_run_menu_bg() {
    local sbx="$1" out="$2"; shift 2
    printf '%s\n' "$@" | bash "$sbx/flac_health_reencode.sh" > "$out" 2>&1 &
    echo "$!"
}

# mlib_count <dir> [find args...] : match count, 0 when the dir is absent.
mlib_count() {
    local dir="$1"; shift
    [ -d "$dir" ] || { echo 0; return 0; }
    find "$dir" "$@" 2>/dev/null | wc -l
}

# mlib_latest_csv <sbx> : newest scan CSV under the sandbox library, or empty.
mlib_latest_csv() {
    local sbx="$1"
    find "$sbx/lib/.flac_scan_data/reports" -type f -iname 'flac_scan_*.csv' \
        2>/dev/null | sort | tail -1
}

# mlib_assert_real_flac <path> : 'flac -t' must pass on a real file.
mlib_assert_real_flac() {
    flac -t --silent "$1" 2>/dev/null \
        || mlib_fail "real 'flac -t' rejects $1"
}

# mlib_assert_backup_matches <backup_file> <pristine_original>
#   The backup must be a byte-for-byte copy of the ORIGINAL, not of the reencoded
#   replacement. This is the whole point of the backup tree, and only a real run
#   can check it.
mlib_assert_backup_matches() {
    cmp -s "$1" "$2" \
        || mlib_fail "backup $1 is not byte-identical to the pristine original $2"
}

# mlib_assert_no_residue <library_dir>
#   No reencode temp, shard, index or seed file survives a completed run.
mlib_assert_no_residue() {
    local lib="$1" n list
    n=$(mlib_count "$lib" -type f -name 'tmp_*.part')
    [ "$n" -eq 0 ] || mlib_fail "$n tmp_*.part file(s) left inside the library:
$(find "$lib" -type f -name 'tmp_*.part' | sed 's/^/        /')"
    # Names the pool's own artifacts. A failure lists them, because "13 files left
    # behind" is not actionable without knowing WHICH kind survived.
    list=$(find "$lib/.flac_scan_data" -type f \
            \( -name '*_w*.log' -o -name '*_w*.db' -o -name '*_w*.result' \
               -o -name '*.index' -o -name '*.temps' -o -name '*.paths' \) \
            2>/dev/null | sort)
    n=$(printf '%s\n' "$list" | grep -c . || true)
    [ "$n" -eq 0 ] || mlib_fail "$n pool shard/index/seed file(s) left behind:
$(printf '%s\n' "$list" | sed 's/^/        /')"
    return 0
}
