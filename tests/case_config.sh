#!/usr/bin/env bash
###############################################################################
# case_config.sh - integration: configuration + menu-navigation paths.
#
# These are the paths a first-time user hits before any audio is touched, and
# they were the least covered part of the script:
#
#   A. load_config creates a default config when none exists (version 1.1, empty
#      library_path AND empty backup_path), and the main menu then says the
#      library is not set (option 3 is the documented fix).
#   B. Option 3 with a NEW path persists it to flac_health_config.json and
#      reports the update; the next launch reports it as the current path.
#   C. Option 3 with BLANK answers keeps both existing values (no rewrite).
#   D. Option 3 with no config at all reports "No library path is currently
#      configured." and then stores the first path.
#   E. 'q' / '6' quit cleanly with "Exiting..." and exit status 0.
#   F. An invalid selection re-prompts instead of exiting, and the menu is
#      redrawn (the documented behaviour in the script header).
###############################################################################

set -o errexit
set -o nounset
set -o pipefail

: "${TESTS_ROOT:?}"
: "${PROD_SCRIPT:?}"
. "$TESTS_ROOT/helpers.sh"

MENU_TITLE='FLAC Health Check & Reencode Script'

# Config the script reads, resolved from wherever the script copy was launched.
cfg_field() { jq -r "$2" "$1/flac_health_config.json"; }

# ===========================================================================
# A. No config on disk -> load_config writes a default; menu says "not set".
# ===========================================================================
SBX=''
make_sandbox SBX
register_sandbox "$SBX"
# make_sandbox pre-seeds a config; delete it to exercise the create-default path.
rm -f "$SBX/flac_health_config.json"

run_script "$SBX" 'q'

exist "$SBX/flac_health_config.json"
[ "$(cfg_field "$SBX" '.version')" = '1.1' ] \
    || _fail "created config does not carry version 1.1"
[ "$(cfg_field "$SBX" '.library_path')" = '' ] \
    || _fail "created config should have an empty library_path"
[ "$(cfg_field "$SBX" '.backup_path')" = '' ] \
    || _fail "created config should have an empty backup_path"

# The menu advertises that no library is set and points at option 3.
occur_re 'Library: \(not set - use option 3\)'

echo "ok: case_config (load_config creates a default config)"

# ===========================================================================
# B. Option 3 sets a path + backup dir, persists both, next run reports them.
# ===========================================================================
SBX2=''
make_sandbox SBX2
register_sandbox "$SBX2"
NEWLIB="$SBX2/new-lib"
mkdir -p "$NEWLIB"
NEWBAK="$SBX2/new-backup"

run_script "$SBX2" '3' "$NEWLIB" "$NEWBAK" 'q'

occur_re "Current library path: $SBX2/lib"
occur_re "Current backup directory: $SBX2/lib_backup"
occur_re "Library path updated to: $NEWLIB"
occur_re "Backup directory updated to: $NEWBAK"
[ "$(cfg_field "$SBX2" '.library_path')" = "$NEWLIB" ] \
    || _fail "option 3 did not persist the new path"
[ "$(cfg_field "$SBX2" '.backup_path')" = "$NEWBAK" ] \
    || _fail "option 3 did not persist the new backup directory"

# A fresh launch loads the updated values into the menu banner.
run_script "$SBX2" 'q'
occur_re "Library: $NEWLIB"
occur_re "Backups: $NEWBAK"

echo "ok: case_config (option 3 persists a new path + backup dir)"

# ===========================================================================
# C. Option 3 with blank answers keeps both current values.
# ===========================================================================
SBX3=''
make_sandbox SBX3
register_sandbox "$SBX3"

run_script "$SBX3" '3' '' '' 'q'

occur_re 'Library path remains unchanged\.'
[ "$(cfg_field "$SBX3" '.library_path')" = "$SBX3/lib" ] \
    || _fail "blank answer must not change the configured path"
[ "$(cfg_field "$SBX3" '.backup_path')" = "$SBX3/lib_backup" ] \
    || _fail "blank answer must not change the configured backup dir"

echo "ok: case_config (option 3 blank keeps current path)"

# ===========================================================================
# D. Option 3 with NO config reports it is unset, then stores the first path.
#    The blank backup answer is filled with the derived sibling suggestion.
# ===========================================================================
SBX4=''
make_sandbox SBX4
register_sandbox "$SBX4"
rm -f "$SBX4/flac_health_config.json"
FIRSTLIB="$SBX4/first-lib"
mkdir -p "$FIRSTLIB"

run_script "$SBX4" '3' "$FIRSTLIB" '' 'q'

occur_re 'No library path is currently configured\.'
occur_re "Library path updated to: $FIRSTLIB"
occur_re "Backup directory updated to: $FIRSTLIB""_backup"
[ "$(cfg_field "$SBX4" '.library_path')" = "$FIRSTLIB" ] \
    || _fail "first-ever path was not stored"
[ "$(cfg_field "$SBX4" '.backup_path')" = "$FIRSTLIB""_backup" ] \
    || _fail "blank backup answer was not filled with the derived default"

# ===========================================================================
# G. Option 3 refuses an overlap between the two paths at the keyboard: the
#    library's own parent (which would erase the library on backup cleanup) must
#    not reach the config, and the old backup dir must survive.
# ===========================================================================
SBX6=''
make_sandbox SBX6
register_sandbox "$SBX6"

run_script "$SBX6" '3' '' "$SBX6" 'q'

occur_re 'Error: The library cannot be inside the backup directory'
occur_re 'Backup directory not changed\.'
[ "$(cfg_field "$SBX6" '.backup_path')" = "$SBX6/lib_backup" ] \
    || _fail "an unsafe backup dir was written to the config"

echo "ok: case_config (option 3 rejects an unsafe backup dir)"

# ===========================================================================
# E. Quit: both 'q' and '6' announce the exit and return status 0.
# ===========================================================================
for quit_key in 'q' '6'; do
    SBXQ=''
    make_sandbox SBXQ
    register_sandbox "$SBXQ"

    run_script "$SBXQ" "$quit_key"

    occur_re 'Exiting\.\.\.'
    [ "$LAST_STATUS" -eq 0 ] \
        || _fail "quit via '$quit_key' exited $LAST_STATUS, expected 0"
    # Nothing was created in the library: quitting must be side-effect free.
    miss "$SBXQ/lib/.flac_scan_data"
done

echo "ok: case_config (q and 6 quit cleanly)"

# ===========================================================================
# F. An invalid selection re-prompts, then a valid one still works.
# ===========================================================================
SBX5=''
make_sandbox SBX5
register_sandbox "$SBX5"

# 'zzz' is invalid -> the menu re-prompts; the second run proves control
# returned to the menu loop rather than exiting the script.
run_script "$SBX5" 'zzz' 'q'

occur_re 'Invalid selection\. Please choose a number from 1-6 \(or q to quit\)\.'
occur_re 'Exiting\.\.\.'
# Banner appears at least twice: initial draw + redraw after the invalid entry.
[ "$(message_count "$MENU_TITLE")" -ge 2 ] \
    || _fail "menu was not redrawn after an invalid selection"

echo "ok: case_config (invalid selection re-prompts)"
