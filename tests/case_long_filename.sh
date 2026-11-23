#!/usr/bin/env bash
# case_long_filename.sh - integration: a basename near NAME_MAX still re-encodes.
#
# WHY THIS EXISTS. The in-library temp is 'tmp_<base>.part', which is 9 BYTES longer
# than the original name. Lidarr copies a long track title verbatim, and a real
# library hit a 254-byte basename (the Sufjan Stevens "Black Hawk War..." track):
# the 263-byte temp could be neither created (flac: "ERROR initializing encoder",
# state FLAC__STREAM_ENCODER_IO_ERROR) nor unlinked (rm: "File name too long"), so
# that file failed on every run - and, never being recorded in reencoded.db, was
# retried and failed again forever.
#
# temp_path_for_file now keeps 'tmp_<base>.part' when it fits and falls back to
# 'tmp_<md5 of the path>.part' when it would exceed 255 bytes. This case pins the
# behaviour with the two fixtures that matter:
#
#   * ASCII_MAX  - 255 bytes, the longest name the kernel accepts at all (the exact
#                  prefix layout of the file that failed, padded out).
#   * MB_MAX     - 255 BYTES of multi-byte characters ('é' is 2 bytes, '’' is 3).
#                  Its CHARACTER count is only 127, so a locale-aware length check
#                  would wrongly call the 264-byte temp acceptable. The check must
#                  count bytes, exactly as the filesystem does.
#   * SHORT      - a control file, whose temp must stay the plain readable name.
#
# Filesystems that refuse the 255-byte fixture itself (NAMEMAX < 255) skip it rather
# than fail: there is nothing to re-encode there, and the multi-byte fixture still
# exercises the fallback.

set -o errexit
set -o nounset
set -o pipefail

: "${TESTS_ROOT:?}"
: "${PROD_SCRIPT:?}"
. "$TESTS_ROOT/helpers.sh"

SBX=''
make_sandbox SBX
register_sandbox "$SBX"
LIB="$SBX/lib"
ALBUM="$LIB/Sufjan Stevens/Albums/Illinois (2005)"
mkdir -p "$ALBUM"

# 255 bytes: '02 - ' (5) + 245 characters + '.flac' (5).
ascii_pad=''
printf -v ascii_pad '%*s' 245 ''
ASCII_MAX="$ALBUM/02 - ${ascii_pad// /x}.flac"
# 'é' x 125 + '.flac' is 250 + 5 = 255 bytes in every UTF-8 locale (and 127 chars).
mb_stem=''
for _ in $(seq 1 125); do mb_stem="${mb_stem}é"; done
MB_MAX="$ALBUM/${mb_stem}.flac"
SHORT="$ALBUM/02 - Short Title.flac"

# The fixtures must really be the intended byte lengths, or this case proves nothing.
[ "$(printf '%s' "${ASCII_MAX##*/}" | wc -c)" -eq 255 ] \
    || _fail "ASCII_MAX basename is $(printf '%s' "${ASCII_MAX##*/}" | wc -c) bytes, expected 255"
[ "$(printf '%s' "${MB_MAX##*/}" | wc -c)" -eq 255 ] \
    || _fail "MB_MAX basename is $(printf '%s' "${MB_MAX##*/}" | wc -c) bytes, expected 255"

write_file "$SHORT" 'orig-short'
# Only create the long fixtures if the filesystem can hold them at all.
have_ascii=0
have_mb=0
if write_file "$ASCII_MAX" 'orig-ascii-long' 2>/dev/null; then
    have_ascii=1
fi
if write_file "$MB_MAX" 'orig-multibyte-long' 2>/dev/null; then
    have_mb=1
fi
[ "$have_ascii" -eq 1 ] || [ "$have_mb" -eq 1 ] \
    || { echo "SKIP: this filesystem cannot hold a 255-byte name"; exit 0; }

expected=$(( 1 + have_ascii + have_mb ))

# Option 4 = reencode ALL, so every fixture goes through the real reencode path
# (temp -> verify -> backup -> replace -> DB) in one run.
run_script "$SBX" '4' 'REENCODE ALL' '' 'q'

[ "$(captured_count 'Successful reencodes: ([0-9]+)')" -eq "$expected" ] \
    || _fail "successes != $expected (long basenames were not re-encoded)"
[ "$(captured_count 'Failed reencodes: ([0-9]+)')" -eq 0 ] \
    || _fail "failures != 0 (a basename near NAME_MAX still fails)"

# The kernel's own complaint must be gone from both directions: flac could not create
# the temp, rm could not unlink it.
absent_re 'File name too long'
absent_re 'ERROR initializing encoder'
# And nothing may be reported as failed in the run log either.
if grep -rq 'FAILURE' "$LIB/.flac_scan_data/logs/" 2>/dev/null; then
    _fail "the run log records a FAILURE for a long-basename file"
fi

# Each fixture was replaced by the stub marker, mirrored into the backup root with its
# ORIGINAL bytes, and recorded in the tracking DB (without the last, option 4/5 would
# retry it on every future run - the second half of the bug).
check_one() {
    local file="$1" original="$2"
    local rel="${file#"$LIB"/}"
    file_eq "$file" "$RE_MARKER"
    file_eq "$SBX/lib_backup/$rel" "$original"
    db_has_path "$SBX" "$file"
}
check_one "$SHORT" 'orig-short'
[ "$have_ascii" -eq 0 ] || check_one "$ASCII_MAX" 'orig-ascii-long'
[ "$have_mb" -eq 0 ]    || check_one "$MB_MAX" 'orig-multibyte-long'

# No temp may survive, under either naming scheme. A rejected over-long 'tmp_<base>.part'
# could never be removed by the script, so any residue must be reported loudly here.
residue="$(find "$LIB" -type f -name 'tmp_*.part' -print)"
[ -z "$residue" ] || _fail "reencode temp(s) survived the run:
$residue"

echo "ok: case_long_filename (basenames at NAME_MAX are re-encoded via a hashed temp)"
