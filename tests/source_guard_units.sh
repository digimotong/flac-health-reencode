#!/usr/bin/env bash
###############################################################################
# source_guard_units.sh - executions driver used by case_helpers.sh
#
# Run as a child interpreter whose shell-level globals (REENCODED_SET etc.) are
# let go on exit; sourced-prod-script state never pollutes the caller or the
# repo. Requires on PATH (before sourcing): stub flac + stub metaflac.
# Env: UNITS_LIB (library root), UNITS_DB (tracking db file).
###############################################################################

set -o errexit
set -o nounset
set -o pipefail

fail() { echo "  FAIL: $*" >&2; exit 1; }
pass() { echo "ok"; }

# Source the production script: must NOT auto-run the interactive menu here.
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
# the whole point is to word-split "<md5> <size> <mtime>" into $1 $2 $3 -- each
# field is a plain hex/number token with no spaces, so no globbing can occur.
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

echo "ok: source-guard units"
