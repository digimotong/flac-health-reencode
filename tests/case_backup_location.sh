#!/usr/bin/env bash
###############################################################################
# case_backup_location.sh - integration: backups live OUTSIDE the library, in a
# mirrored backup root; no menu option can delete anything in the library.
#
#   A. A CSV-driven run (option 2) mirrors the original into
#      "<backup>/<relative path>" and leaves no 'backup_FLAC_originals' folder in
#      the library. A row pointing OUTSIDE the library is skipped with a warning
#      instead of being re-encoded without a backup.
#   B. A full-library run (option 4) of a library that still holds LEGACY
#      in-library backups (the version 1.0 layout) must not treat them as
#      content: the count excludes them, they are neither re-encoded nor copied
#      into the backup root, and the .flac_scan_data dir stays untouched.
#   C. Every unsafe backup_path is refused BEFORE any file is touched: equal to
#      the library, inside it, or a parent of it. The library and every original
#      must survive byte-for-byte, with no reencode marker and no backup tree.
###############################################################################

set -o errexit
set -o nounset
set -o pipefail

: "${TESTS_ROOT:?}"
: "${PROD_SCRIPT:?}"
. "$TESTS_ROOT/helpers.sh"

# ===========================================================================
# A. Option 2 mirrors the original outside the library; out-of-library rows skip.
# ===========================================================================
SBX=''
make_sandbox SBX
register_sandbox "$SBX"
LIB="$SBX/lib"
BAK="$SBX/lib_backup"

REAL="$LIB/Album Big/worst.flac"
# A row for a file that is NOT under the library root. It has no home in the
# mirrored tree, so the run must refuse to re-encode it unprotected.
OUTSIDE="$SBX/elsewhere/stray.flac"
mkdir -p "$LIB/Album Big" "$LIB/.flac_scan_data/reports" "$SBX/elsewhere"

write_file "$REAL"    'orig-worst-bytes'
write_file "$OUTSIDE" 'orig-stray-bytes'

MANUAL="$LIB/.flac_scan_data/reports/flac_scan_manual.csv"
{
    printf '# Scan Report: 2026 | Files: 2 | Errors: 2\n'
    printf 'filepath\n'
    printf '"%s"\n' "$REAL"
    printf '"%s"\n' "$OUTSIDE"
} > "$MANUAL"

run_script "$SBX" '2' 'Y' ''

occur_re "Processing file: $REAL"
occur_re "SUCCESS:.*worst\\.flac reencoded successfully"
# The out-of-library row is skipped, so only the real in-library file counts.
occur_re "Skipping path outside the library: $OUTSIDE"
[ "$(captured_count 'Total files processed: ([0-9]+)')" -eq 1 ] || _fail "option2 total != 1"
[ "$(captured_count 'Successful reencodes: ([0-9]+)')"   -eq 1 ] || _fail "option2 success != 1"
occur_re "Backups stored in: $BAK"

# The original bytes now live in the MIRRORED path, with the album-relative
# layout preserved (Album Big/worst.flac -> <backup>/Album Big/worst.flac).
file_eq "$BAK/Album Big/worst.flac" 'orig-worst-bytes' \
    || _fail "mirrored backup does not hold the original bytes"
file_eq "$REAL" "$RE_MARKER" || _fail "real file was not re-encoded"
# No in-library backup folder was created for the new backup.
miss "$LIB/Album Big/backup_FLAC_originals"
# The out-of-library file was left completely alone.
file_eq "$OUTSIDE" 'orig-stray-bytes' || _fail "out-of-library row was re-encoded without a backup"
# Sanity: nothing else was written into the backup root.
[ "$(find "$BAK" -type f | wc -l)" -eq 1 ] || _fail "unexpected extra files in the backup root"

echo "ok: backup_location (option 2 mirrors originals outside the library)"

# ===========================================================================
# B. Legacy in-library backups are content to nobody: option 4 ignores them.
#    The config is deliberately the OLD shape (no backup_path) plus an explicit
#    one, to prove the legacy exclusion still holds in the new layout.
# ===========================================================================
SBX2=''
make_sandbox SBX2
register_sandbox "$SBX2"
LIB2="$SBX2/lib"
BAK2="$SBX2/lib_backup"

R1="$LIB2/Album One/trackA.flac"
R2="$LIB2/Album One/sub/trackB.flac"
LEGACY="$LIB2/Album One/sub/backup_FLAC_originals/trackB.flac"
INTERNAL="$LIB2/.flac_scan_data/metrics.flac"
mkdir -p "$LIB2/Album One/sub/backup_FLAC_originals" "$LIB2/.flac_scan_data"

write_file "$R1"       'orig-A'
write_file "$R2"       'orig-B'
write_file "$LEGACY"   'legacy-B-original'
write_file "$INTERNAL" 'IGNORED'

run_script "$SBX2" '4' 'REENCODE ALL' ''

# 2 real files: the legacy backup copy and the internal file are excluded.
occur_re "You are about to reencode ALL 2 FLAC files"
[ "$(captured_count 'Successful reencodes: ([0-9]+)')" -eq 2 ] || _fail "all: successes != 2"

file_eq "$R1" "$RE_MARKER"
file_eq "$R2" "$RE_MARKER"
# The legacy backup was neither re-encoded nor copied into the new backup tree.
file_eq "$LEGACY" 'legacy-B-original' || _fail "legacy in-library backup was modified"
miss "$BAK2/Album One/sub/backup_FLAC_originals"
file_eq "$INTERNAL" 'IGNORED'

# Both real files were mirrored, and only them: the backup tree mirrors the
# library but contains no legacy and no internal path.
exist "$BAK2/Album One/trackA.flac"
exist "$BAK2/Album One/sub/trackB.flac"
[ "$(find "$BAK2" -type f | wc -l)" -eq 2 ] || _fail "backup root should mirror exactly the 2 real files"
[ -z "$(find "$BAK2" -name 'backup_FLAC_originals' -o -name '.flac_scan_data' | head -n1)" ] \
    || _fail "backup root received a legacy/internal path"

echo "ok: backup_location (legacy in-library backups ignored by option 4)"

# ===========================================================================
# C. Unsafe backup_path values are refused before any file is touched.
#    Each variant goes through option 4 (the run that resolves the backup dir)
#    and must leave the library and every original byte-identical.
# ===========================================================================
check_unsafe() {
    local label="$1" variant="$2" want_re="$3"
    local sbx lib bad_backup
    # NOTE: make_sandbox writes its result through the NAME given as $1, so the
    # variable must not be a local of make_sandbox's own frame here.
    make_sandbox CHECK_SBX
    register_sandbox "$CHECK_SBX"
    sbx="$CHECK_SBX"
    lib="$sbx/lib"
    mkdir -p "$lib/Album" "$lib/inner"
    write_file "$lib/Album/keep.flac" 'PRISTINE'

    # Each variant is expressed relative to THIS sandbox, so the check always
    # compares the sandbox's own library against the unsafe candidate.
    case "$variant" in
        equal)    bad_backup="$lib" ;;
        inside)   bad_backup="$lib/inner" ;;
        parent)   bad_backup="$sbx" ;;
        relative) bad_backup="relative_backup" ;;
        *)        _fail "unknown variant: $variant" ;;
    esac

    printf '{"library_path": "%s", "backup_path": "%s", "version": "1.1"}\n' \
        "$lib" "$bad_backup" > "$sbx/flac_health_config.json"

    run_script "$sbx" '4' 'REENCODE ALL' ''

    occur_re "$want_re"
    # Aborted before the confirmation prompt and before any reencode.
    absent_re 'Starting reencode'
    absent_re 'SUCCESS:'
    file_eq "$lib/Album/keep.flac" 'PRISTINE' || _fail "$label: original was modified"
    # No reencode temp was left behind by the aborted run.
    [ -z "$(find "$sbx" -name 'tmp_*.part' | head -n1)" ] \
        || _fail "$label: a reencode temp was left behind"

    echo "ok: backup_location (refused: $label)"
}

check_unsafe 'backup == library'     equal \
    'Error: The backup directory cannot be the library itself'
check_unsafe 'backup inside library' inside \
    'Error: The backup directory cannot be inside the library'
check_unsafe 'library inside backup' parent \
    'Error: The library cannot be inside the backup directory'
check_unsafe 'relative backup path'  relative \
    'Error: The backup directory must be an absolute path'

# ===========================================================================
# D. A config with NO backup_path at all falls back to the derived sibling
#    '<library>_backup'; an accepted prompt answer is persisted there.
#    Option 5 (NEW) is used because it is the path that ASKS.
# ===========================================================================
SBX3=''
make_sandbox SBX3
register_sandbox "$SBX3"
LIB3="$SBX3/lib"
mkdir -p "$LIB3/Album"
write_file "$LIB3/Album/new.flac" 'DERIVE-ME'
# Old-shape config: no backup_path key whatsoever.
printf '{"library_path": "%s", "version": "1.0"}\n' "$LIB3" \
    > "$SBX3/flac_health_config.json"

# 'y' confirms the reencode; the EMPTY line accepts the derived default.
run_script "$SBX3" '5' 'y' '' ''

occur_re 'Backup directory not set'
DERIVED="$LIB3""_backup"
occur_re "Backup directory set to: $DERIVED"
occur_re "Backups will be written to: $DERIVED"
# The derived path was persisted and actually used for the mirror.
[ "$(jq -r '.backup_path' "$SBX3/flac_health_config.json")" = "$DERIVED" ] \
    || _fail "the accepted derived backup path was not persisted"
file_eq "$DERIVED/Album/new.flac" 'DERIVE-ME' \
    || _fail "derived backup root does not hold the original"
file_eq "$LIB3/Album/new.flac" "$RE_MARKER"

echo "ok: backup_location (derived '<library>_backup' default)"


