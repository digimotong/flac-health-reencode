#!/bin/bash
# FLAC Health Check & Re-encode Utility: scans a library with 'flac -t', then
# re-encodes the failures, backing up every original first.
#
# Requires: bash 4.3+, flac, metaflac (in the flac package), jq and md5sum, on
#           Linux with GNU userland (nproc, stat -c, chmod/chown --reference);
#           see README.md, "Platform support".
# Usage:    ./flac_health_reencode.sh  (menu-driven; see README.md)
#
# Layout: this file is the ENTRY POINT and nothing else - the header, the shared
# globals, the sourced modules, the startup tool gate, the menu and the
# "is this being run or sourced?" guard. The work lives in lib/*.sh beside it (see
# README.md, Development). The modules are plain Bash sourced into this one shell,
# so every global below is visible to all of them and a module is never run on its
# own.
#
# Per-file work runs through one operation-agnostic worker pool (run_file_pool,
# lib/pool.sh), shared by the reencode paths (2/4/5) and the scan (1). Worker count
# comes from get_jobs() (lib/config.sh): $FLAC_HEALTH_JOBS, else the config's "jobs"
# key, else min(4, nproc); 1 means strictly sequential. Each worker writes its own
# shard (run log + tracking DB, or a scan failure list) which the parent merges, so
# no two workers ever append to the same file. Every shard that records a PATH (the
# scan's failure shard and the merged failure list) is NUL-separated and read with
# 'read -r -d ""'; the scan report itself is NDJSON (see write_scan_report).
#
# Every long-running option (1, 2, 4, 5) reports through ONE progress API
# (progress_begin/progress_update/progress_end), driven by COMPLETED files rather
# than dispatched ones. On a terminal that is a single self-updating line
# ("[###---] 42% (420/1000) | failed 3 | 04:12 ETA 02:34"); when stdout is
# redirected it degrades to periodic plain "Progress:" lines. The renderer uses
# only '\r' and ASCII (plus the standard erase-to-end-of-line CSI), so the Debian
# text console and GNOME Terminal both display it correctly; TERM=dumb falls back
# to plain lines.

# Variables only: SCRIPT_DIR (locating lib/ and the config), the terminal colours,
# the progress geometry and cached display state, the pool state, and the tracking
# DB set. Functions live in lib/*.sh, sourced below; this file stays the entry point
# and owns nothing else.

# Resolved from BASH_SOURCE[0], NOT from $0: the test suite SOURCES this file to
# unit-test individual functions, and in that case $0 is the test script while
# BASH_SOURCE[0] is this file. Built from the 'cd'/'pwd' builtins rather than
# realpath so the startup tool gate's hermetic-PATH case still reaches it.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Where the sourced modules live: './lib' beside this file (the normal layout), or
# './script_lib' in a test sandbox, whose 'lib' IS the fake music library. Tested for
# the module FILE, not the directory: an empty 'lib' is exactly what a sandbox's
# music-library root looks like. A full installation only ever needs the first.
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
    MODULE_DIR="$SCRIPT_DIR/lib"
else
    MODULE_DIR="$SCRIPT_DIR/script_lib"
fi

# Configuration file path
CONFIG_FILE="$SCRIPT_DIR/flac_health_config.json"

# Terminal colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Progress bar geometry. PROGRESS_WIDTH is the preferred bar width in columns;
# the renderer shrinks it (down to PROGRESS_MIN_WIDTH) when the terminal is too
# narrow for the counters/label/timings, so the line never wraps.
PROGRESS_WIDTH=30
PROGRESS_MIN_WIDTH=10
PROGRESS_MAX_WIDTH=30

# Cached by stdout_is_tty(), so a render loop pays the [ -t 1 ] test once.
declare -g STDOUT_IS_TTY=''

# 1: per-file status lines also go to the terminal. 0: log only - the live
# single-line progress bar would otherwise be scattered by them.
declare -g STATUS_TO_CONSOLE=1

# Progress state, all owned by the progress_* API below. PROGRESS_ACTIVE is 0
# outside a run's begin/end window, which is what makes progress_update a no-op
# for code (and child processes) that is not drawing a bar. PROGRESS_DRAW_LIVE is
# 1 when the display can be rewritten in place (a real terminal), 0 for the plain
# periodic-line fallback (pipe, redirect, TERM=dumb). The LAST_* fields are the
# redraw high-water marks, so a run renders at most ~100 times (one per whole
# percent) however many files it has.
declare -g PROGRESS_ACTIVE=0
declare -g PROGRESS_DRAW_LIVE=0
declare -g PROGRESS_TOTAL=0
declare -g PROGRESS_DONE=0
declare -g PROGRESS_FAIL=0
declare -g PROGRESS_LABEL='Failed'
declare -g PROGRESS_START=0
declare -g PROGRESS_COLS=80
declare -g PROGRESS_LAST_PCT=-1
declare -g PROGRESS_LAST_DONE=-1

# Pool state: high-water worker id, i.e. how many shards the run created. Ids
# are allocated per FILE, so it usually exceeds the job count, and it is 0 for a
# sequential run. Declared here because 'set -u' callers read it after the call.
declare -g POOL_WORKERS_USED=0

# Interrupt cleanup state. POOL_TEMP_LIST is the run-local list of the in-library
# temp files (see temp_path_for_file) the parent has dispatched, POOL_SEED_LIST is the
# run's NUL-separated work list, and POOL_INTERRUPT_ARMED latches so the handler
# runs its sweep once. All three are only meaningful while a pooled run is in
# flight: a scan dispatches no reencode temps and simply leaves POOL_TEMP_LIST
# empty.
declare -g POOL_TEMP_LIST=''
declare -g POOL_SEED_LIST=''
declare -g POOL_INTERRUPT_ARMED=0

# run_file_pool's completion tally, re-initialised per run.
declare -g POOL_PROCESSED=0
declare -g POOL_SUCCESS=0
declare -g POOL_FAIL=0

# Path of the run-lock directory this process holds, or ''. Empty means no lock is
# held (see acquire_run_lock / release_run_lock).
declare -g RUN_LOCK_DIR=''

# Set by run_scan_pool: files that failed verification, and files that could not
# be tested at all. Declared here so 'set -u' callers can always read them.
declare -g POOL_ERRORS=0
declare -g POOL_UNTESTED=0

# Written by parse_legacy_report_row, which 'set -u' callers read back. It holds ONE
# path, so a newline inside a filename is harmless here (unlike a list).
declare -g LEGACY_REPORT_PATH=''

# Successfully reencoded files, keyed md5|size (see load_reencoded_set). Owned by
# lib/backup.sh, declared here so every sourced module can read it.
declare -A REENCODED_SET

# Paths the script itself creates inside a library; never treated as library
# content. The backup_FLAC_originals entry is legacy (kept for installs upgraded
# from versions that backed up in-library). Read by lib/config.sh.
readonly FLAC_INTERNAL_PATH_GLOBS=(
    '*backup_FLAC_originals/*'
    '*/.flac_scan_data/*'
)

set -o errexit
set -o nounset
set -o pipefail

# ---------------------------------------------------------------------------
# Modules. Sourced, not executed: everything below shares this one shell's globals
# (the pool seams, the progress counters, REENCODED_SET), so the ORDER is the only
# ordering that matters. They are found through MODULE_DIR (above), which is why the
# path is a variable; the `source=` directive above each line is what lets ShellCheck
# resolve the file, and tests/lint.sh also analyses lib/*.sh directly.
#
# What each module provides, in dependency order:
#   common    the tty probe and format_duration
#   config    config file, worker count, find_real_flac_files, is_internal_flac_path
#   backup    backup roots, fingerprints and the tracking DB
#   progress  render_progress, the progress_* API and write_status
#   pool      shard helpers, run_file_pool, the run lock and the interrupt trap
#   scan      select_pool_mode, run_reencode_pool, the scan report writer/readers,
#             run_scan_pool and scan_library
#   reencode  reencode_one_file, options 2/4/5 and set_paths
# ---------------------------------------------------------------------------
# shellcheck source=lib/common.sh
. "$MODULE_DIR/common.sh"
# shellcheck source=lib/config.sh
. "$MODULE_DIR/config.sh"
# shellcheck source=lib/backup.sh
. "$MODULE_DIR/backup.sh"
# shellcheck source=lib/progress.sh
. "$MODULE_DIR/progress.sh"
# shellcheck source=lib/pool.sh
. "$MODULE_DIR/pool.sh"
# shellcheck source=lib/scan.sh
. "$MODULE_DIR/scan.sh"
# shellcheck source=lib/reencode.sh
. "$MODULE_DIR/reencode.sh"

# Required tools, checked before anything writes the config (a bare
# "jq: command not found" would exit 127 and leave a zero-byte config behind).
# Maps each command to its Debian/Ubuntu package for the install hint.
for cmd in flac metaflac jq md5sum; do
    if ! command -v "$cmd" &>/dev/null; then
        case "$cmd" in
            jq) pkg=jq ;;
            md5sum) pkg=coreutils ;;   # hashes the temp name of an over-long basename
            *)  pkg=flac ;;   # the flac package also provides metaflac
        esac
        echo "Error: The '$cmd' command is not installed. Please install it (e.g., sudo apt-get install $pkg) and try again."
        exit 1
    fi
done

# MAIN MENU: lets the user pick a scan or a reencode.
main_menu() {
    local menu_bar="=========================================================="
    echo "$menu_bar"
    echo "   FLAC Health Check & Reencode Script"
    echo "$menu_bar"

    # Show the configured paths so the user knows what a bulk operation would act
    # on. Colors only on a live terminal, so captured output stays plain.
    local config library_path backup_path
    config=$(load_config)
    library_path=$(echo "$config" | jq -r '.library_path')
    backup_path=$(echo "$config" | jq -r '.backup_path // empty')
    if [ -z "$library_path" ] || [ "$library_path" == "null" ]; then
        if stdout_is_tty; then
            printf '%b\n' "   ${YELLOW}Library: (not set - use option 3)${NC}"
        else
            echo "   Library: (not set - use option 3)"
        fi
    else
        if stdout_is_tty; then
            printf '%b\n' "   ${GREEN}Library: $library_path${NC}"
        else
            echo "   Library: $library_path"
        fi
    fi
    if [ -z "$backup_path" ]; then
        if [ -n "$library_path" ] && [ "$library_path" != "null" ]; then
            echo "   Backups: ${library_path%/}_backup (derived; set with option 3)"
        else
            echo "   Backups: (derived from the library; set with option 3)"
        fi
    else
        echo "   Backups: $backup_path"
    fi

    # Options 1/2/4/5 all use this value, and it decides how hard the run hits the
    # storage, so it is worth surfacing before a multi-hour operation. Name
    # FLAC_HEALTH_JOBS when it is what decided the value, since an env override is
    # easy to forget.
    if [ -n "${FLAC_HEALTH_JOBS:-}" ]; then
        echo "   Workers: $(get_jobs) (from FLAC_HEALTH_JOBS)"
    else
        echo "   Workers: $(get_jobs)"
    fi
    echo "$menu_bar"

    echo " 1) Scan music library for errors"
    echo " 2) Reencode problematic FLAC files (from latest scan)"
    echo " 3) Set/Update library path & backup directory"
    echo " 4) Reencode ALL FLAC files (with backups & warning)"
    echo " 5) Reencode NEW FLAC files only"
    echo " 6) Quit"
    echo "$menu_bar"
    read -rp "Enter your selection (1-6, or q to quit): " selection

    case "$selection" in
        1) scan_library ;;
        2) reencode_library ;;
        3) set_paths ;;
        4) reencode_all_files ;;
        5) reencode_new_files ;;
        6 | q | Q) echo "Exiting..."; exit 0 ;;
        *) echo "Invalid selection. Please choose a number from 1-6 (or q to quit)." ;;
    esac
}


# Loop the menu. The BASH_SOURCE guard keeps it from auto-running when the file
# is sourced (the test suite sources it to unit-test individual functions).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # The run lock a menu operation took is released however this process ends: a
    # normal return, 'q', errexit, or a signal handler that exits. A run killed in a
    # way that skips this trap (kill -9) leaves a stale lock that the next run breaks
    # by checking the recorded pid (see acquire_run_lock).
    trap 'release_run_lock' EXIT
    while true; do
        main_menu
    done
fi
