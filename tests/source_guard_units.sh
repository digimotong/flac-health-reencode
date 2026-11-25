#!/usr/bin/env bash
# source_guard_units.sh - assertions driver used by case_helpers.sh
#
# Runs as a child interpreter so the sourced script's globals (REENCODED_SET etc.)
# never pollute the caller or the repo. Requires stub flac + metaflac on PATH.
# Env: UNITS_LIB (library root), UNITS_DB (tracking db file).

set -o errexit
set -o nounset
set -o pipefail

fail() { echo "  FAIL: $*" >&2; exit 1; }
pass() { echo "ok"; }

# Source the production script: it must NOT auto-run the interactive menu here.
# shellcheck source=../flac_health_reencode.sh
. "$PROD_SCRIPT"

LIB="$UNITS_LIB"
DB="$UNITS_DB"

# --- is_internal_flac_path ----------------------------------------------------
check_internal() {
    if is_internal_flac_path "$1"; then :; else fail "expected internal: $1"; fi
}
check_real() {
    if is_internal_flac_path "$1"; then fail "expected real path: $1"; fi
}
check_internal "$LIB/Album/backup_FLAC_originals/track one.flac"
check_internal "$LIB/.flac_scan_data/root_internal.flac"
check_internal "$LIB/With Space dir/.flac_scan_data/think.flac"
check_real "$LIB/Real/backup_FLAC_originals_old/song.flac"
check_real "$LIB/Album/track one.flac"
check_real "$LIB/With Space dir/thing.flac"

# --- find_real_flac_files -----------------------------------------------------
mapfile -t found < <(find_real_flac_files "$LIB")
has() { local p; for p in "${found[@]}"; do [ "$p" = "$1" ] && return 0; done; return 1; }

# Presents: root_internal.flac is under .flac_scan_data -> excluded.
has "$LIB/Album/plain.flac"                       || fail "find missed plain.flac"
has "$LIB/Album/track one.flac"                   || fail "find missed the space-named real file"
has "$LIB/Real/backup_FLAC_originals_old/song.flac" || fail "near-miss 'backup_FLAC_originals_old' wrongly excluded"
has "$LIB/Album/backup_FLAC_originals/track one.flac" && fail "find INCLUDED a real backup copy"
has "$LIB/.flac_scan_data/root_internal.flac"     && fail "find INCLUDED .flac_scan_data file"
has "$LIB/.flac_scan_data/tmp/metrics.flac"       && fail "find INCLUDED nested internal file"
has "$LIB/With Space dir/.flac_scan_data/think.flac" && fail "find INCLUDED nested .flac_scan_data"

# -print0 returns the same NUL-safe population.
count0=0
while IFS= read -r -d '' p; do
    has "$p" || fail "-print0 returned unexpected path: $p"
    count0=$((count0 + 1))
done < <(find_real_flac_files "$LIB" -print0)
[ "$count0" -eq "${#found[@]}" ] || fail "-print0 population ($count0) != plain ($(printf '%s' "${#found[@]}"))"

# --- get_file_fingerprint -----------------------------------------------------
fp=$(get_file_fingerprint "$LIB/Album/plain.flac") || fail "fingerprint failed"
# Split the 3-field fingerprint on whitespace. Quoting is deliberately omitted:
# the point is to word-split "<md5> <size> <mtime>" into $1 $2 $3, and each field
# is a plain hex/number token with no spaces, so no globbing can occur.
# shellcheck disable=SC2086
set -- $fp
[ "$#" -eq 3 ]        || fail "fingerprint not 3 fields: <$fp>"
case "$1" in
    *[!0-9a-fA-F]*) fail "md5 field not hex: $1" ;;
esac
[ "${#1}" -eq 32 ]    || fail "md5 field length != 32: ${#1}"
[ "$2" -ge 0 ] 2>/dev/null || fail "size field not a number: $2"
[ "$3" -ge 0 ] 2>/dev/null || fail "mtime field not a number: $3"

# --- DB helpers ----------------------------------------------------------------
load_reencoded_set "$DB"
[ "${#REENCODED_SET[@]}" -eq 1 ] || fail "preseeded 1 db row not loaded (count=${#REENCODED_SET[@]})"

mark_as_reencoded "$DB" "$LIB/Album/plain.flac" || fail "mark_as_reencoded errored"
load_reencoded_set "$DB"
[ "${#REENCODED_SET[@]}" -eq 2 ] || fail "after mark, expected 2 fingerprints (count=${#REENCODED_SET[@]})"

# Path-with-spaces round-trips through the DB (path is the LAST field).
grep -qE 'track one\.flac$' "$DB" || fail "db missing path with spaces"

# --- temp_path_for_file -------------------------------------------------------
# The reencode temp sits beside the original. Normally 'tmp_<base>.part' (unchanged
# from before); for a basename so long that the 9 extra bytes would exceed
# TEMP_NAME_MAX, a fixed-length name hashed from the full path instead - a name the
# kernel can create AND unlink, without which the file could never be re-encoded.
[ "$(temp_path_for_file "/m/Music/A/track.flac")" = "/m/Music/A/tmp_track.flac.part" ] \
    || fail "temp_path_for_file changed the ordinary temp name"
# Spaces and non-ASCII characters are carried verbatim while the name still fits.
[ "$(temp_path_for_file "/m/My Music/Thé Bleu.flac")" = "/m/My Music/tmp_Thé Bleu.flac.part" ] \
    || fail "temp_path_for_file mangled a short name with spaces/accents"
# A slash-less path keeps a directory component (dirname's '.'), never a bare name.
[ "$(temp_path_for_file "track.flac")" = "./tmp_track.flac.part" ] \
    || fail "temp_path_for_file lost the relative directory"

# 255 ASCII bytes: the temp name (264) cannot exist, so a hashed one is used.
# '02 - ' (5) + 245 characters + '.flac' (5) = 255.
LONG_STEM=''
printf -v LONG_STEM '%*s' 245 ''
LONG_ASCII="/m/Music/A/02 - ${LONG_STEM// /x}.flac"
long_tmp=$(temp_path_for_file "$LONG_ASCII") || fail "temp_path_for_file failed on a long name"
[ "$long_tmp" != "$(dirname "$LONG_ASCII")/tmp_$(basename "$LONG_ASCII").part" ] \
    || fail "temp_path_for_file kept the over-long temp name"
[ "$(printf '%s' "${long_tmp##*/}" | wc -c)" -le 255 ] \
    || fail "hashed temp name still exceeds NAME_MAX: ${long_tmp##*/}"
case "${long_tmp##*/}" in
    tmp_*.part) : ;;
    *) fail "hashed temp name does not keep the tmp_*.part convention: ${long_tmp##*/}" ;;
esac
case "${long_tmp##*/}" in
    *[!0-9a-fA-F_.tmp]) fail "hashed temp name is not plain hex: ${long_tmp##*/}" ;;
esac
[ "${long_tmp%/*}" = "/m/Music/A" ] || fail "hashed temp left the album directory: $long_tmp"

# Deterministic: the interrupt sweep and the worker derive it independently, so the
# same file must always yield the same name...
[ "$(temp_path_for_file "$LONG_ASCII")" = "$long_tmp" ] \
    || fail "temp_path_for_file is not deterministic for a long name"
# ...but unique per file, so two long names in ONE album can never share a temp.
# (Only the last character changes, so the replacement name is long as well.)
LONG_OTHER="${LONG_ASCII%x.flac}y.flac"
[ "$(printf '%s' "${LONG_OTHER##*/}" | wc -c)" -eq 255 ] || fail "second long fixture is not 255 bytes"
[ "$(temp_path_for_file "$LONG_OTHER")" != "$long_tmp" ] \
    || fail "two long names in one album collided on the same temp"

# BYTES, not characters: 255 bytes of 2-byte 'é' is 127 characters, so a
# locale-aware length check would keep the 264-byte name and reintroduce the bug.
MB_SEG=''
for (( i = 0; i < 125; i++ )); do MB_SEG="${MB_SEG}é"; done
LONG_MB="/m/Music/A/${MB_SEG}.flac"
[ "$(printf '%s' "${LONG_MB##*/}" | wc -c)" -eq 255 ] || fail "multibyte fixture is not 255 bytes"
[ "$(temp_path_for_file "$LONG_MB")" != "/m/Music/A/tmp_${MB_SEG}.flac.part" ] \
    || fail "temp_path_for_file measured characters, not bytes, for a multibyte name"

# --- derive_backup_path -------------------------------------------------------
# Pure: '<library>_backup', with any trailing slash normalised away first so
# '/media/Music/' cannot yield '/media/Music/_backup'.
[ "$(derive_backup_path "/media/Music")"  = "/media/Music_backup" ]  || fail "derive (plain) wrong"
[ "$(derive_backup_path "/media/Music/")" = "/media/Music_backup" ]  || fail "derive (trailing slash) wrong"
[ "$(derive_backup_path "/m/My Music")"   = "/m/My Music_backup" ]   || fail "derive (space) wrong"

# --- get_backup_target --------------------------------------------------------
# Pure: the library root prefix is replaced by the backup root, preserving the
# relative chain (this is the mirroring contract).
[ "$(get_backup_target "/m/Music" "/m/Music_backup" "/m/Music/2Pac/X/a.flac")" \
    = "/m/Music_backup/2Pac/X/a.flac" ] || fail "get_backup_target mapping wrong"
[ "$(get_backup_target "/m/Music/" "/m/Music_backup/" "/m/Music/A/b.flac")" \
    = "/m/Music_backup/A/b.flac" ] || fail "get_backup_target trailing-slash wrong"
# A file NOT under the library has no backup home: must return 1 and print nothing.
if out=$(get_backup_target "/m/Music" "/m/Music_backup" "/elsewhere/a.flac"); then
    fail "get_backup_target accepted an out-of-library path"
fi
[ -z "$out" ] || fail "get_backup_target printed something for an out-of-library path"

# --- validate_backup_root -----------------------------------------------------
# Refuses the three ancestor arrangements plus relative paths; accepts a sibling.
VB_LIB="$LIB/Album"
validate_backup_root "$VB_LIB" "$VB_LIB"            && fail "accepted backup == library"
validate_backup_root "$VB_LIB" "$VB_LIB/inner"      && fail "accepted backup inside library"
validate_backup_root "$VB_LIB" "$LIB"               && fail "accepted library inside backup"
validate_backup_root "$VB_LIB" "relative_backup"    && fail "accepted a relative backup path"
validate_backup_root "$VB_LIB" ""                   && fail "accepted an empty backup path"
validate_backup_root "$VB_LIB" "$LIB/Album_backup"  || fail "rejected a legitimate sibling backup"
# The near-miss: a SIBLING sharing a name prefix must not be treated as inside.
validate_backup_root "$VB_LIB" "$LIB/Album_backup/sub" || fail "rejected a legitimate sibling subtree"

# --- render_progress (shared progress display) --------------------------------
# Deterministic checks: timings off (so no clock is involved) and a fixed width,
# so the exact frame is predictable. This is the format every long-running option
# shares, so a change here is a change to all of them.
PROGRESS_COLS=80
PROGRESS_WIDTH=30

# Half-way: half the bar filled, the counters and label in the documented shape.
[ "$(render_progress 5 10 2 'failed' 0)" = \
    '[###############---------------]  50% (5/10) | failed: 2' ] || fail "render_progress half-way wrong"

# Start and end states.
case "$(render_progress 0 10 0 'failed' 0)" in
    '[------------------------------]   0% (0/10) | failed: 0') : ;;
    *) fail "render_progress 0/N wrong: $(render_progress 0 10 0 'failed' 0)" ;;
esac
case "$(render_progress 10 10 3 'failed' 0)" in
    '[##############################] 100% (10/10) | failed: 3') : ;;
    *) fail "render_progress N/N wrong: $(render_progress 10 10 3 'failed' 0)" ;;
esac

# A done count above the total is clamped, never overflows the bar.
case "$(render_progress 99 10 0 'failed' 0)" in
    *'100% (10/10)'*) : ;;
    *) fail "render_progress does not clamp done > total" ;;
esac

# A zero/empty total prints nothing at all (it would divide by zero).
[ -z "$(render_progress 0 0 0 'failed' 0)" ] || fail "render_progress printed for total=0"

# The frame always fits the terminal: never wider than PROGRESS_COLS, even on a
# narrow one. Below the width where even the MINIMUM bar plus the counters fit,
# the counters and label win and the bar is dropped entirely, so the line can
# never wrap (a wrapped line is what breaks a single-line '\r' display).
for cols in 40 60 80 200; do
    PROGRESS_COLS=$cols
    line=$(render_progress 123 456 7 'failed' 0)
    [ "${#line}" -le "$cols" ] || fail "render_progress exceeds ${cols} cols (${#line}): $line"
done
# The counters + label + bar alone need ~29 columns; at 28 they still fit once the
# bar is dropped.
PROGRESS_COLS=28
line=$(render_progress 123 456 7 'failed' 0)
if [ "${#line}" -gt 28 ] || [ -z "$line" ]; then
    fail "render_progress exceeds 28 cols: $line"
fi
# At a comfortable width the bar itself is present.
PROGRESS_COLS=80
case "$(render_progress 123 456 7 'failed' 0)" in
    '['*'] '*'(123/456)'*) : ;;
    *) fail "render_progress dropped the bar at 80 cols" ;;
esac
# The counters survive every width, however narrow.
case "$(render_progress 123 456 7 'failed' 0)" in
    *'| failed: 7') : ;;
    *) fail "render_progress lost its counters" ;;
esac

# Timings: none before the first completion (no ETA can exist yet); an ETA is
# present once work has completed, and the elapsed/ETA fields are "M:SS" shaped.
PROGRESS_START=$(date +%s)
case "$(render_progress 0 10 0 'failed' 1)" in
    *ETA*) fail "render_progress shows an ETA before any file completed" ;;
esac
rendered=$(render_progress 5 10 0 'failed' 1)
case "$rendered" in
    *' ETA '*) : ;;
    *) fail "render_progress shows no ETA mid-run: $rendered" ;;
esac
case "$rendered" in
    *'| '[0-9]*:[0-9][0-9]' ETA '[0-9]*:[0-9][0-9]) : ;;
    *) fail "render_progress timing fields malformed: $rendered" ;;
esac

# format_duration: M:SS under an hour, H:MM:SS from an hour, nothing for garbage.
[ "$(format_duration 0)"    = '0:00' ]    || fail "format_duration 0 wrong"
[ "$(format_duration 65)"   = '1:05' ]    || fail "format_duration 65 wrong"
[ "$(format_duration 3600)" = '1:00:00' ] || fail "format_duration 3600 wrong"
[ "$(format_duration 7325)" = '2:02:05' ] || fail "format_duration 7325 wrong"
[ -z "$(format_duration '')" ] || fail "format_duration accepted an empty value"

# progress_* lifecycle: updates outside a run are no-ops; the live display draws
# once per whole percent and always lands on the final N/N state.
#
# stdout here is NOT a terminal, so progress_begin would choose the plain-line
# form. These assertions are about the LIVE (single-line) form, so run with that
# decided and pin the plain form separately below.
PROGRESS_ACTIVE=0
[ -z "$(progress_update 5 10 0)" ] || fail "progress_update drew while inactive"
progress_begin 0 'failed'
[ "$PROGRESS_ACTIVE" -eq 0 ] || fail "progress_begin activated for a zero-length run"

# Plain form (what a captured pooled run gets): one self-terminated line per percent.
progress_begin 4 'failed'
[ "$PROGRESS_ACTIVE" -eq 1 ] || fail "progress_begin did not activate"
[ "$PROGRESS_DRAW_LIVE" -eq 0 ] || fail "progress_begin drew live without a tty"
plain=$(progress_update 1 0)
case "$plain" in
    'Progress: [#'*'  25% (1/4) | failed: 0'*) : ;;
    *) fail "plain progress line malformed: $plain" ;;
esac
case "$plain" in
    *$'\r'*|*$'\033'*) fail "plain progress line contains terminal control bytes" ;;
esac
progress_end

# Live form, with a total large enough that consecutive files share a percent:
# 1/1000 and 2/1000 both round to 0%, so only the FIRST of them may redraw. The
# final update must still render even though 100% arrives right after 99%.
progress_begin 1000 'failed'
PROGRESS_ACTIVE=1
PROGRESS_DRAW_LIVE=1
# Start clean: the plain-form run above left its own high-water marks behind, and
# progress_begin (which normally resets them) chose the plain form without a tty.
PROGRESS_LAST_PCT=-1
PROGRESS_LAST_DONE=-1
# Capture each frame to a file. progress_update keeps its per-percent high-water
# marks in the CURRENT shell, so a call must never sit inside an extra $( ... )
# (it would still print, but the caller would only ever see the first draw).
# A DRAWN live frame always ends with the erase-line escape; compare the raw
# trailing bytes rather than grep, whose bracket expression would misread "\033".
FRAMES=$(mktemp "${TMPDIR:-/tmp}/flac_progress_frames.XXXXXX")
trap 'rm -f "$FRAMES"' EXIT
erase_tail=$'\033[K'
frame_was_drawn() {
    local content
    content=$(cat "$1")
    case "$content" in
        *"$erase_tail") return 0 ;;
        *) return 1 ;;
    esac
}
progress_update 1 0 > "$FRAMES"
frame_was_drawn "$FRAMES" || fail "live progress did not draw the first percent"
progress_update 2 0 > "$FRAMES"
if frame_was_drawn "$FRAMES"; then
    fail "live progress redrew without advancing a percent"
fi
progress_update 10 1 > "$FRAMES"
frame_was_drawn "$FRAMES" || fail "live progress did not draw on the next percent"
progress_update 1000 2 > "$FRAMES"
grep -qF '100% (1000/1000)' "$FRAMES" || fail "live progress did not render the final N/N state"
# The final state is always drawn, even though 100% comes right after 99%.
frame_was_drawn "$FRAMES" || fail "live progress did not land on the final state"
progress_end
[ "$PROGRESS_ACTIVE" -eq 0 ] || fail "progress_end left progress active"

# --- DB record format: NUL-terminated, legacy DBs still readable ---------------
# The tracking DB holds one NUL-terminated record per reencoded file, so a path with
# a newline in it is ONE record instead of two. A DB written by an older version
# (newline-delimited) must still load, and is migrated on the next write.
LEGACY_DB="$LIB/.flac_scan_data/legacy_units.db"
mkdir -p "$(dirname "$LEGACY_DB")"
printf '%s %s %s %s\n' 0123456789abcdef0123456789abcdef 10 1 "$LIB/Album/plain.flac" > "$LEGACY_DB"
db_is_nul_format "$LEGACY_DB" && fail "a legacy newline DB was misdetected as NUL-formatted"
load_reencoded_set "$LEGACY_DB"
[ "${#REENCODED_SET[@]}" -eq 1 ] || fail "legacy DB row not loaded (count=${#REENCODED_SET[@]})"
# The first write migrates it, and the result holds both records, NUL-terminated.
mark_as_reencoded "$LEGACY_DB" "$LIB/Album/track one.flac" || fail "mark_as_reencoded errored on a legacy DB"
db_is_nul_format "$LEGACY_DB" || fail "the legacy DB was not migrated to the NUL record format"
[ "$(tr -d -c '\000' < "$LEGACY_DB" | wc -c)" -eq 2 ] || fail "migrated DB does not hold exactly 2 NUL records"
load_reencoded_set "$LEGACY_DB"
[ "${#REENCODED_SET[@]}" -eq 2 ] || fail "migrated DB did not load both records (count=${#REENCODED_SET[@]})"
# Migration is idempotent: a second call leaves a NUL DB byte-identical.
cp "$LEGACY_DB" "$LEGACY_DB.before"
migrate_reencoded_db "$LEGACY_DB" || fail "migrate_reencoded_db errored on a NUL DB"
cmp -s "$LEGACY_DB" "$LEGACY_DB.before" || fail "migrate_reencoded_db rewrote an already-migrated DB"
rm -f "$LEGACY_DB.before"
# A path holding a NEWLINE is one record, not two - the bug this format removes.
NL_DB="$LIB/.flac_scan_data/newline_units.db"
printf '%s %s %s %s\0' 0123456789abcdef0123456789abcdef 10 1 "$LIB/Album/a"$'\n'"b.flac" > "$NL_DB"
[ "$(tr -d -c '\000' < "$NL_DB" | wc -c)" -eq 1 ] || fail "newline record fixture is not one NUL record"
load_reencoded_set "$NL_DB"
[ "${#REENCODED_SET[@]}" -eq 1 ] || fail "newline-named record did not load as exactly one row"
# No temp file is left behind by a migration.
[ -z "$(find "$LIB/.flac_scan_data" -name '*.migrating.*' 2>/dev/null)" ] || fail "a migration temp file was left behind"
rm -f "$LEGACY_DB" "$NL_DB"

# --- parse_legacy_report_row --------------------------------------------------
# A legacy (CSV) report row is the whole line with exactly ONE surrounding quote
# pair removed. The two bugs this replaced: 'IFS=, read' truncated a path at its
# first comma, and a blanket '"'-strip corrupted any name containing a quote.
LEGACY_REPORT_PATH=''
parse_legacy_report_row '"/m/Music/A, B.flac"' >/dev/null
# Checked through the GLOBAL (a plain command, not $(...)): a command substitution
# would run the parser in a subshell and the caller would never see the assignment -
# which is exactly the reason the option-2 loop calls it as a plain command.
[ "$LEGACY_REPORT_PATH" = '/m/Music/A, B.flac' ] \
    || fail "legacy row lost its comma: <$LEGACY_REPORT_PATH>"
# Interior double quotes survive; only the outer pair is unwrapped. (Double-quoted
# literals: the input is a row holding a real '"' byte, not the two characters \".)
[ "$(parse_legacy_report_row "\"/m/Music/A, B\"c.flac\"")" = '/m/Music/A, B"c.flac' ] \
    || fail "legacy row corrupted an interior quote: $(parse_legacy_report_row "\"/m/Music/A, B\"c.flac\"")"
# A backslash and a single quote are ordinary data.
[ "$(parse_legacy_report_row '"/m/Music/back\slash.flac"')" = '/m/Music/back\slash.flac' ] \
    || fail "legacy row mangled a backslash"
[ "$(parse_legacy_report_row '"/m/Music/back\slash.flac"')" = "/m/Music/back\\slash.flac" ] \
    || fail "legacy row mangled a backslash (comparison)"
[ "$(parse_legacy_report_row "\"/m/Music/it's.flac\"")" = "/m/Music/it's.flac" ] \
    || fail "legacy row mangled a single quote"
# An unquoted row is taken verbatim, so a hand-written report keeps working.
[ "$(parse_legacy_report_row '/m/Music/plain.flac')" = '/m/Music/plain.flac' ] \
    || fail "legacy row mangled an unquoted path"
# The header, a comment and a blank line pass through unchanged, so the caller's
# existing filters still recognise them.
[ "$(parse_legacy_report_row 'filepath')" = 'filepath' ] || fail "legacy header not passed through"
[ "$(parse_legacy_report_row '# Scan Report: x')" = '# Scan Report: x' ] || fail "legacy comment not passed through"
[ -z "$(parse_legacy_report_row '')" ] || fail "legacy blank line not passed through"
# An empty quoted field unwraps to an empty path, which the caller drops.
[ -z "$(parse_legacy_report_row '""')" ] || fail "empty quoted row did not unwrap to empty"

# --- find_latest_scan_report ---------------------------------------------------
# Newest by mtime across BOTH extensions, and nothing at all for a directory that
# does not exist yet (a scan has never run), which must not fail under 'set -e'.
LATEST_DIR="$LIB/.report_latest_test"
mkdir -p "$LATEST_DIR/sub"
[ -z "$(find_latest_scan_report "$LATEST_DIR")" ] || fail "find_latest_scan_report found a report in an empty dir"
[ -z "$(find_latest_scan_report "$LIB/.no_such_reports_dir")" ] || fail "find_latest_scan_report reported a missing dir"
printf '%s\n' '{}' > "$LATEST_DIR/flac_scan_2020-01-01_00-00-00.csv"
printf '%s\n' '{}' > "$LATEST_DIR/flac_scan_2021-01-01_00-00-00.ndjson"
# An unrelated file, and one in a subdirectory, are never candidates.
printf '%s\n' 'x' > "$LATEST_DIR/notes.txt"
printf '%s\n' '{}' > "$LATEST_DIR/sub/flac_scan_2999-01-01_00-00-00.ndjson"
[ "$(find_latest_scan_report "$LATEST_DIR")" = "$LATEST_DIR/flac_scan_2021-01-01_00-00-00.ndjson" ] \
    || fail "find_latest_scan_report did not pick the newest .ndjson: $(find_latest_scan_report "$LATEST_DIR")"
# A newer legacy CSV still wins, so an old-style report is never ignored.
touch "$LATEST_DIR/flac_scan_2020-01-01_00-00-00.csv"
[ "$(find_latest_scan_report "$LATEST_DIR")" = "$LATEST_DIR/flac_scan_2020-01-01_00-00-00.csv" ] \
    || fail "find_latest_scan_report ignored a newer legacy .csv"
rm -rf "$LATEST_DIR"

echo "ok: source-guard units"
