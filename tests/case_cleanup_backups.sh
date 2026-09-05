#!/usr/bin/env bash
###############################################################################
# case_cleanup_backups.sh - integration: option 4 (Clean up FLAC backups)
#
#   A. With backups present: reports them, demands the 'DELETE' phrase, removes
#      ONLY the backup_FLAC_originals dirs, and leaves every real FLAC + the
#      .flac_scan_data directory untouched.
#   B. With no backups: prints 'No backup folders found' and changes nothing.
###############################################################################

set -o errexit
set -o nounset
set -o pipefail

: "${TESTS_ROOT:?}"
: "${PROD_SCRIPT:?}"
. "$TESTS_ROOT/helpers.sh"

# ---------------------------------------------------------------------------
# A: library with two backup dirs + real files + internal dir
# ---------------------------------------------------------------------------
SBX=''
make_sandbox SBX
register_sandbox "$SBX"
LIB="$SBX/lib"
mkdir -p "$LIB/Album/backup_FLAC_originals" "$LIB/Album2/deeper/backup_FLAC_originals" "$LIB/.flac_scan_data/reports"

write_file "$LIB/Album/song.flac"                      'REAL-A'
write_file "$LIB/Album/backup_FLAC_originals/song.flac" 'BAK-A'
write_file "$LIB/Album2/deeper/track.flac"              'REAL-B'
write_file "$LIB/Album2/deeper/backup_FLAC_originals/track.flac" 'BAK-B'
write_file "$LIB/.flac_scan_data/reports/internal.flac" 'INTERNAL-NOT-BACKUP'

run_script "$SBX" '4' 'DELETE' ''

occur_re 'Found 2 backup folders'
occur_re "WARNING: This will PERMANENTLY delete all FLAC backups"
occur_re 'Deleted 2 backup folders'

# The two backup dirs are gone...
miss "$LIB/Album/backup_FLAC_originals"
miss "$LIB/Album2/deeper/backup_FLAC_originals"
# ...while real FLACs + internal data survive.
file_eq "$LIB/Album/song.flac" 'REAL-A'
file_eq "$LIB/Album2/deeper/track.flac" 'REAL-B'
file_eq "$LIB/.flac_scan_data/reports/internal.flac" 'INTERNAL-NOT-BACKUP'

echo "ok: cleanup_backups (folders removed, library preserved)"

# ---------------------------------------------------------------------------
# B: no backups anywhere -> early "no backups" notice, nothing deleted.
# ---------------------------------------------------------------------------
SBX2=''
make_sandbox SBX2
register_sandbox "$SBX2"
LIB2="$SBX2/lib"
mkdir -p "$LIB2/Albums"
write_file "$LIB2/Albums/only.flac" 'keep'
write_file "$LIB2/Albums/only.txt"  'notes'

run_script "$SBX2" '4' ''

occur_re "No backup folders found in '$LIB2'"
file_eq "$LIB2/Albums/only.flac" 'keep'
file_eq "$LIB2/Albums/only.txt"  'notes'

echo "ok: cleanup_backups (empty library notice)"
