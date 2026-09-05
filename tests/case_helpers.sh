#!/usr/bin/env bash
###############################################################################
# case_helpers.sh - SOURCE-GUARD UNIT TEST DRIVER.
#
# Builds an isolated sandbox, then delegates the real assertions to
# source_guard_units.sh running as a CHILD interpreter: the child sources the
# production script (testing the source-guard: no menu auto-run), whose top-
# level `command -v flac/metaflac` presence check is satisfied by the stubs we
# prepend to PATH. Global prod state therefore never bleeds into this case or
# out toward the repo.
###############################################################################

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

# ---- fixture tree ------------------------------------------------------------
mkdir -p "$LIB/Album/backup_FLAC_originals" \
         "$LIB/.flac_scan_data/tmp" \
         "$LIB/Real/backup_FLAC_originals_old" \
         "$LIB/With Space dir/.flac_scan_data"

write_file "$LIB/Album/plain.flac"            'some-flac-bytes'
write_file "$LIB/Album/track one.flac"        'album-tone'
write_file "$LIB/Album/backup_FLAC_originals/track one.flac" 'album-tone'   # backup
write_file "$LIB/.flac_scan_data/root_internal.flac"        'internal-root'
write_file "$LIB/.flac_scan_data/tmp/metrics.flac"          'internal-nested'
write_file "$LIB/With Space dir/.flac_scan_data/think.flac" 'internal-space'
write_file "$LIB/Real/backup_FLAC_originals_old/song.flac"  'real-near-miss'

# Preseed a tracking DB exactly in the format the production mark() writes:
#   "<md532> <size> <mtime> <path-as-last-field>"
DB="$LIB/.flac_scan_data/reencoded.db"
printf '# header comment\n\n' > "$DB"
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 5 100 %s\n' "$LIB/Album/track one.flac" >> "$DB"

# ---- run delegated units -----------------------------------------------------
export TESTS_ROOT PROD_SCRIPT UNITS_LIB="$LIB" UNITS_DB="$DB"
PATH="$SBX/bin:$PATH" bash "$TESTS_ROOT/source_guard_units.sh"
