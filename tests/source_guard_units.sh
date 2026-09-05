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

echo "ok: source-guard units"
