#!/bin/bash
###############################################################################
# FLAC Health Check & Re-encode Utility
#
# Purpose:
#   - Scans FLAC files for corruption/errors
#   - Safely re-encodes problematic files while preserving originals
#   - Maintains detailed scan reports and operation logs
#
# Features:
#   - Recursive directory scanning
#   - Progress tracking with visual feedback
#   - Configurable library + backup paths (stored in JSON)
#   - Automatic backup of original files before re-encoding (a backup is written
#     only the first time a file is re-encoded, so the pristine original survives
#     re-runs over the same files)
#   - Comprehensive error logging
#   - Persistent 'reencoded' tracking database (avoids redundant full re-encodes)
#
# Requirements:
#   - bash 4.0+ (associative arrays)
#   - flac command line tool
#   - metaflac (included with the flac package)
#   - jq for JSON processing
#
# Usage:
#   1. Run script: ./flac_health_reencode.sh
#   2. Select operation from menu:
#      - Scan music library for errors
#      - Re-encode problematic files (from the latest scan report)
#      - Reencode ALL FLAC files
#      - Reencode NEW FLAC files only (skip already-processed)
#      - Set/Update the library path and the backup directory
#
#   Note: an invalid or empty menu entry re-prompts; type 'q' or '6' to quit.
# Reencoded-file Tracking:
#   After a successful reencode a file is recorded in
#   '<library>/.flac_scan_data/reencoded.db' using its FLAC audio MD5 (from
#   metaflac --show-md5sum), file size and mtime. The 'Reencode NEW FLAC files
#   only' option skips files whose MD5+size are already recorded, so newly added
#   (or freshly downloaded, previously deleted) albums are reliably detected.
#
# Important Notes:
#   - Backups are stored OUTSIDE the library, in a single backup directory that
#     mirrors the library's layout (library '/m/2Pac/All Eyez on Me (1996)'
#     -> backup '/m_backup/2Pac/All Eyez on Me (1996)'). Keeping them out of the
#     library means no media scanner can ever index a backup copy as a duplicate
#     track, and clearing them is a single 'rm -rf' the user performs directly.
#     When no backup_path is configured the script suggests '<library>_backup';
#     options 2/5 ask before using it, option 4 just shows it in its warning.
#   - Scan reports are saved in '.flac_scan_data/reports'
#   - Operation logs are saved in '.flac_scan_data/logs'
#   - Reencoded-file DB is saved as '.flac_scan_data/reencoded.db'
#   - Uses FLAC's --decode-through-errors for maximum recovery
#   - All real-FLAC operations (scan, reencode-from-CSV, reencode ALL/NEW) skip
#     the script's own internal paths ('backup_FLAC_originals' copies left by
#     older versions, and '.flac_scan_data') so they are never scanned,
#     re-encoded, or backed up a second time.
###############################################################################

# flac_health_reencode.sh

# Configuration file path
CONFIG_FILE="$(dirname "$(realpath "$0")")/flac_health_config.json"

# Terminal colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Progress tracking
PROGRESS_WIDTH=50

# TTY / rendering state ------------------------------------------------------
# STDOUT_IS_TTY is populated lazily by stdout_is_tty() on first use and cached,
# so the many render calls in a loop only pay the [ -t 1 ] syscall once. A whole
# script invocation never flips fd 1 mid-run, so a single cached value is safe.
declare -g STDOUT_IS_TTY=''

# STATUS_TO_CONSOLE toggles whether per-file SUCCESS/FAILURE/WARNING status
# lines are echoed to the terminal (1, default) or only appended to the run log
# (0). The "live single-line progress bar" mode used by reencode ALL/NEW on a
# real terminal must keep status text OFF the screen, otherwise it would glue
# onto / scatter the bar; the statuses still reach the log either way.
declare -g STATUS_TO_CONSOLE=1

# Set of successfully reencoded files, keyed by md5|size (see load_reencoded_set).
# global associative array
declare -A REENCODED_SET

# Exit when a command fails, when a variable is unset, and catch errors in pipelines.
set -o errexit
set -o nounset
set -o pipefail

########################################
# FUNCTION: load_config
# Loads configuration from file or creates default. A missing file is created
# with an EMPTY library_path and EMPTY backup_path, which the menu renders as
# "(not set - use option 3)" and resolve_backup_path turns into a derived
# default on the first re-encode run.
########################################
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        jq -n '{library_path: "", backup_path: "", version: "1.1"}' > "$CONFIG_FILE"
    fi
    config=$(cat "$CONFIG_FILE")
    echo "$config"
}

########################################
# FUNCTION: save_config
# Saves configuration to file.
# Arguments:
#   $1 - New library path
#   $2 - (optional) New backup directory. When omitted the existing backup_path
#        is left untouched, so a caller that only means to change the library
#        (and every pre-existing call site) cannot silently drop the backup
#        location.
########################################
save_config() {
    local new_path="$1"
    local new_backup="${2:-}"
    if [ -n "$new_backup" ]; then
        config=$(jq --arg path "$new_path" --arg backup "$new_backup" \
            '.library_path = $path | .backup_path = $backup' "$CONFIG_FILE")
    else
        config=$(jq --arg path "$new_path" '.library_path = $path' "$CONFIG_FILE")
    fi
    echo "$config" > "$CONFIG_FILE"
}

# Ensure required commands are available.
for cmd in flac metaflac; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: The '$cmd' command is not installed. Please install it (e.g., sudo apt-get install flac) and try again."
        exit 1
    fi
done

# Paths the script itself creates inside a library. These must never be treated
# as real library content: pre-reencode backup copies and the internal
# scan/tracking directory (.flac_scan_data/). Defined once here so callers can
# build consistent find predicates or path tests.
#
# The 'backup_FLAC_originals' entry is LEGACY: current versions write backups to
# the configured backup directory outside the library, but an install that was
# upgraded from an older version still holds its pristine originals in those
# folders. Without this exclusion such a folder would suddenly count as real
# library content, and options 4/5 would happily re-encode it and back up the
# backups. The entry stays until in-library backups are long gone.
readonly FLAC_INTERNAL_PATH_GLOBS=(
    '*backup_FLAC_originals/*'
    '*/.flac_scan_data/*'
)

########################################
# FUNCTION: find_real_flac_files
# Recursively prints a library's real FLAC files, excluding the script's own
# internal paths (backup copies and .flac_scan_data/). Extra arguments (such as
# "-print0") are forwarded to find.
# Arguments:
#   $1 - Directory to search (library root)
########################################
find_real_flac_files() {
    local library_dir="$1"
    shift
    local find_args=("$library_dir" -type f -iname "*.flac")
    local glob
    for glob in "${FLAC_INTERNAL_PATH_GLOBS[@]}"; do
        find_args+=(-not -path "$glob")
    done
    find "${find_args[@]}" "$@"
}

########################################
# FUNCTION: is_internal_flac_path
# Returns 0 if the given path is one of the script's own internal paths (a
# backup copy or something under .flac_scan_data/), 1 otherwise. Used to filter
# non-find inputs (e.g. rows from an older scan CSV).
# Arguments:
#   $1 - Path to test
########################################
is_internal_flac_path() {
    local glob
    # Disable at the FUNCTION level: the case patterns below are deliberately
    # UNQUOTED because the globs in FLAC_INTERNAL_PATH_GLOBS contain '*' and are
    # meant to match as globs. Quoting them (as SC2254 suggests) would make case
    # compare literally and every internal path would stop being recognised.
    # (An inline directive is not allowed in front of a single case branch.)
    # shellcheck disable=SC2254
    for glob in "${FLAC_INTERNAL_PATH_GLOBS[@]}"; do
        case "$1" in
            $glob) return 0 ;;
        esac
    done
    return 1
}

########################################
# FUNCTION: stdout_is_tty
# Returns 0 (true) if fd 1 is attached to a terminal right now, 1 otherwise.
# The result is cached in STDOUT_IS_TTY ('0'/'1') on first use so a rendering
# loop only performs the [ -t 1 ] syscall once (see the STDOUT_IS_TTY note).
########################################
stdout_is_tty() {
    [ -z "$STDOUT_IS_TTY" ] && { [ -t 1 ] && STDOUT_IS_TTY=1 || STDOUT_IS_TTY=0; }
    [ "$STDOUT_IS_TTY" = "1" ]
}

########################################
# FUNCTION: render_progress
# Draws the progress/percent text (with a trailing space so a status label can
# be appended on the same bar row). No carriage return, newline, or clearing is
# emitted here - callers decide between the animated single-line form (via
# show_progress, a real terminal) and the plain text-line form (a non-tty).
# Arguments:
#   $1 - Current count
#   $2 - Total count
#   $3 - Error / failure count
#   $4 - (optional) label for $3 shown after the colon; defaults to "Errors"
########################################
render_progress() {
    local current=$1
    local total=$2
    local errors=$3
    local label="${4:-Errors}"
    local percent=$((current * 100 / total))
    local filled=$((percent * PROGRESS_WIDTH / 100))
    local empty=$((PROGRESS_WIDTH - filled))

    printf "["
    printf "%${filled}s" | tr ' ' '#'
    printf "%${empty}s" | tr ' ' '-'
    printf "] %3d%% (%d/%d) | %s: %d " "$percent" "$current" "$total" "$label" "$errors"
}

########################################
# FUNCTION: show_progress
# Draws the progress bar on a real terminal as a single self-updating line: a
# leading carriage return + clear-to-end-of-line snap the cursor to the start of
# the row the next time anything is emitted, so the bar always overwrites
# itself in place on that one row. This MUST be the last thing drawn before
# control returns to an interactive prompt, and no bare status text is ever
# echoed between calls to it (see reencode_one_file's STATUS_TO_CONSOLE check).
########################################
show_progress() {
    # Only animate on a real terminal. On a non-tty (pipe/redirect/CI) emit a
    # plain, self-terminated text line so output stays readable and undamaged
    # and no stray carriage-return/byte-clearing escapes reach the capture.
    if stdout_is_tty; then
        printf "\r"
        render_progress "$@"
        printf "\033[K"
    else
        printf "Progress: "
        render_progress "$@"
        printf "\n"
    fi
}

########################################
# FUNCTION: clear_progress
# Erases the animated progress-bar line, leaving the cursor on a fresh row.
# No-op when stdout is not a terminal (in that case there is no bar row to
# clear - show_progress never emitted a bare line there).
########################################
clear_progress() {
    if stdout_is_tty; then
        printf "\r\033[K"
    fi
}

########################################
# FUNCTION: write_status
# Outputs one SUCCESS/FAILURE/WARNING status line. The line is ALWAYS appended
# to the run log; it is additionally echoed to the terminal only while
# STATUS_TO_CONSOLE is 1 (the non-tty settings, and all option-2 runs). During
# the option 4/5 single-line-bar mode on a live terminal STATUS_TO_CONSOLE is
# 0, so per-file progress does not glue onto / scatter the bar; the log file
# still receives every line.
# Arguments:
#   $1 - Full status line (already includes its SUCCESS/FAILURE/WARNING prefix)
#   $2 - Run log path
########################################
write_status() {
    local line="$1"
    local log_file="$2"
    printf '%s\n' "$line" >> "$log_file"
    if [ "$STATUS_TO_CONSOLE" = "1" ]; then
        printf '%s\n' "$line"
    fi
}
########################################


# FUNCTION: get_reencoded_db_path
# Returns the full path to the reencoded-file tracking database.
# The DB lives inside the library's own .flac_scan_data directory.
# Arguments:
#   $1 - Library root directory
########################################
get_reencoded_db_path() {
    local library_dir="$1"
    printf '%s/.flac_scan_data/reencoded.db\n' "$library_dir"
}

########################################
# FUNCTION: get_file_fingerprint
# Produces the fingerprint line for a FLAC file: "<md5> <size> <mtime>".
# The md5 is the audio MD5 from the STREAMINFO block (fast, header-only read).
# On any failure (e.g. unreadable/corrupt header) this returns 1 so the caller
# treats the file as needing reencoding.
# Arguments:
#   $1 - FLAC file path
# Output: "<md5> <size> <mtime>"
########################################
get_file_fingerprint() {
    local file="$1"
    local md5 size mtime

    md5=$(metaflac --show-md5sum "$file" 2>/dev/null) || return 1
    size=$(stat -c %s "$file" 2>/dev/null) || return 1
    mtime=$(stat -c %Y "$file" 2>/dev/null) || return 1

    printf '%s %s %s\n' "$md5" "$size" "$mtime"
}

########################################
# FUNCTION: load_reencoded_set
# Loads the tracking database into the global associative array REENCODED_SET.
# Key = "<md5>|<size>". Blank lines and comment lines are skipped.
# NOTE: populate the array in the CURRENT shell, so call this as a plain command
# (never inside $() command substitution, which would run in a subshell and
# discard the array updates). Inspect ${#REENCODED_SET[@]} for the count.
# Arguments:
#   $1 - Tracking database path
########################################
load_reencoded_set() {
    local db_path="$1"
    local md5 size mtime path_line

    REENCODED_SET=()

    if [ ! -f "$db_path" ]; then
        return 0
    fi

    while IFS= read -r path_line || [ -n "$path_line" ]; do
        [ -z "$path_line" ] && continue
        case "$path_line" in \#*) continue ;; esac
        read -r md5 size mtime _rest <<< "$path_line"
        [ -z "$md5" ] && continue
        REENCODED_SET["$md5|$size"]=1
    done < "$db_path"
}

########################################
# FUNCTION: mark_as_reencoded
# Appends the current fingerprint of a successfully reencoded file to the
# tracking database and records it in the in-memory set as well.
# Arguments:
#   $1 - Tracking database path
#   $2 - FLAC file path
# Returns non-zero if the fingerprint could not be generated.
########################################
mark_as_reencoded() {
    local db_path="$1"
    local file="$2"
    local fp md5 size mtime key

    fp=$(get_file_fingerprint "$file") || return 1

    read -r md5 size mtime _rest <<< "$fp"

    mkdir -p "$(dirname "$db_path")"
    # Append "<md5> <size> <mtime> <path>"; path is the LAST field so it may
    # safely contain spaces / special characters.
    printf '%s\n' "$fp $file" >> "$db_path"

    key="${md5}|${size}"
    REENCODED_SET["$key"]=1
}

########################################
# FUNCTION: derive_backup_path
# Returns the default backup directory for a library: the library path with
# '_backup' appended, i.e. '/media/Music' -> '/media/Music_backup'. Sibling of
# the library, so the backups land on the same storage pool by default (the user
# can point the backup directory anywhere, including another disk).
# Arguments:
#   $1 - Library root directory
########################################
derive_backup_path() {
    local library_dir="${1%/}"
    printf '%s_backup\n' "$library_dir"
}

########################################
# FUNCTION: canonical_dir
# Echoes the canonical (symlink-resolved, absolute) form of a directory that
# EXISTS. Uses 'cd -P && pwd' rather than 'realpath --relative-to' so the helper
# stays portable: realpath's --relative-to and -m are GNU coreutils extensions,
# while 'cd -P'/pwd is POSIX and works on the macOS/BSD boxes the README also
# targets. Returns 1 if the directory cannot be entered.
# Arguments:
#   $1 - Directory path
########################################
canonical_dir() {
    ( cd "$1" 2>/dev/null && pwd -P )
}

########################################
# FUNCTION: validate_backup_root
# Returns 0 if the backup directory is a safe place to write originals, 1 (with
# the reason on stderr) otherwise. The library and backup may share NO ancestor
# relationship at all:
#   * identical paths would make every backup overwrite the file it backs up;
#   * a backup INSIDE the library would recreate the media-scanner problem this
#     layout exists to solve, and would be walked by the scanner;
#   * a library INSIDE the backup is worse still - the user's own cleanup (the
#     documented 'rm -rf "$backup"') would then delete the library itself.
# A RELATIVE candidate is rejected outright as well: it is nearly always a
# mis-typed answer to the prompt rather than a deliberate choice, and resolving
# it against the caller's CWD would scatter backups unpredictably.
# Canonicalises both sides when they exist so symlinked spellings of the same
# location are caught too.
# Arguments:
#   $1 - Library root directory (must exist)
#   $2 - Backup directory
########################################
validate_backup_root() {
    local library_dir="${1%/}"
    local backup_root="${2%/}"

    if [ -z "$backup_root" ]; then
        echo "Error: No backup directory configured." >&2
        return 1
    fi

    # A relative candidate is almost always a mis-typed answer to the prompt
    # (e.g. a 'y' meant for the confirmation that follows). Resolving it against
    # the CWD would silently scatter backups into the working directory, so an
    # absolute path is required. The derived default is always absolute because
    # it is built from the library path, so this costs an honest user nothing.
    case "$backup_root" in
        /*) : ;;
        *)
            echo "Error: The backup directory must be an absolute path (got '$backup_root')." >&2
            return 1
            ;;
    esac

    # Canonicalise when possible; fall back to the given spelling (the backup
    # directory legitimately may not exist yet - resolve_backup_path creates it).
    local lib_real bak_real
    lib_real="$(canonical_dir "$library_dir")" || lib_real="$library_dir"
    bak_real="$(canonical_dir "$backup_root")" || bak_real="$backup_root"

    if [ "$lib_real" = "$bak_real" ]; then
        echo "Error: The backup directory cannot be the library itself ($bak_real)." >&2
        return 1
    fi
    case "$bak_real" in
        "$lib_real"/*)
            echo "Error: The backup directory cannot be inside the library ($bak_real is under $lib_real)." >&2
            return 1
            ;;
    esac
    case "$lib_real" in
        "$bak_real"/*)
            echo "Error: The library cannot be inside the backup directory ($lib_real is under $bak_real)." >&2
            return 1
            ;;
    esac
    return 0
}

########################################
# FUNCTION: get_backup_target
# Maps a library file onto its backup path: the library root prefix is replaced
# by the backup root, so the backup tree mirrors the library exactly.
#   library '/m/Music', backup '/m/Music_backup', file '/m/Music/2Pac/X/a.flac'
#   -> '/m/Music_backup/2Pac/X/a.flac'
# PURE: touches nothing on disk, which is what makes it directly unit-testable.
# Returns 1 (printing nothing) when the file is not under the library root - a
# path outside the library has no backup home (see reencode_one_file, which
# refuses to re-encode without a backup).
# Arguments:
#   $1 - Library root directory
#   $2 - Backup root directory
#   $3 - File path
########################################
get_backup_target() {
    local library_dir="${1%/}"
    local backup_root="${2%/}"
    local file="$3"
    local rel

    rel="${file#"$library_dir"/}"
    if [ "$rel" = "$file" ] || [ -z "$rel" ]; then
        # The prefix did not strip: the file is not under the library root.
        return 1
    fi
    printf '%s/%s\n' "$backup_root" "$rel"
}

########################################
# FUNCTION: backup_root_writable
# Returns 0 if the backup root exists and accepts a real file, 1 otherwise.
# Probed by WRITING, not by 'test -w': on a root-squashed NFS export (common on
# a NAS, which is exactly where these libraries live) a mode test can claim the
# directory is writable while every cp still fails. Creating and deleting a
# uniquely-named probe file answers the question that actually matters.
# Arguments:
#   $1 - Backup root directory (must already exist)
########################################
backup_root_writable() {
    local backup_root="${1%/}"
    local probe="${backup_root}/.flac_health_write_test.$$"
    if ! mkdir -p "$backup_root" 2>/dev/null; then
        return 1
    fi
    if ! : > "$probe" 2>/dev/null; then
        return 1
    fi
    rm -f "$probe"
    return 0
}

########################################
# FUNCTION: resolve_backup_path
# Decides WHICH backup directory a re-encode run will use, and validates it.
# Deliberately PURE with respect to the backup tree: it may read the config and
# prompt, but it never creates a directory. Creating the destination is
# ensure_backup_root's job, so a caller that is merely DISPLAYING the path - e.g.
# option 4's warning panel, which the user may still cancel - cannot leave an
# empty stray directory behind.
# Order of operations:
#   1. read backup_path from the config;
#   2. if unset, offer the derived '<library>_backup' as the prompt default and
#      persist whatever is accepted - unless prompting is suppressed;
#   3. validate against validate_backup_root (rejecting the unsafe ancestor
#      arrangements and relative paths).
# It DOES write to the config (an accepted prompt answer is persisted), which is
# why the config write stays here rather than moving to ensure_backup_root: the
# answer is the user's choice about configuration, not a side effect of run
# preparation, and it must survive even if the run is abandoned afterwards.
# On ANY failure the reason is printed and nothing is returned, so every caller
# aborts before touching a single audio file.
# Progress/notice lines and any error go to STDERR; the returned path is the only
# thing on STDOUT. That split is what lets callers do
# 'backup_root=$(resolve_backup_path ...)' without capturing chatter, and it is
# why an interactive prompt here is safe to call from a command substitution.
# Arguments:
#   $1 - Library root directory (must exist)
#   $2 - Optional '--no-prompt': never read from the terminal. When the config
#        has no backup_path, the DERIVED default is used silently. Callers that
#        must not interrupt a confirmation flow (e.g. option 4, which resolves
#        before its warning but creates only after the user commits) pass this.
# Returns 0 with the resolved path on stdout, or 1 with the error on stderr.
########################################
resolve_backup_path() {
    local library_dir="${1%/}"
    local no_prompt="${2:-}"
    local configured derived backup_root

    configured=$(load_config | jq -r '.backup_path // empty')

    if [ -z "$configured" ]; then
        derived="$(derive_backup_path "$library_dir")"
        if [ "$no_prompt" = "--no-prompt" ]; then
            # Nothing to ask: fall back to the derived sibling. NOT persisted -
            # only an explicit user answer is written to the config, so the
            # menu's "(derived; set with option 3)" hint keeps telling the truth
            # about the user never having chosen a directory.
            backup_root="$derived"
        else
            echo "Backup directory not set. Original files are kept outside the library." >&2
            read -rp "Backup directory [$derived]: " backup_root
            if [ -z "$backup_root" ]; then
                backup_root="$derived"
            fi
            backup_root="${backup_root%/}"
            if ! validate_backup_root "$library_dir" "$backup_root"; then
                return 1
            fi
            save_config "$library_dir" "$backup_root"
            echo "Backup directory set to: $backup_root" >&2
        fi
    else
        backup_root="${configured%/}"
        if ! validate_backup_root "$library_dir" "$backup_root"; then
            echo "Fix it with option 3 (Set/Update library & backup paths)." >&2
            return 1
        fi
    fi

    printf '%s\n' "$backup_root"
}

########################################
# FUNCTION: ensure_backup_root
# Creates the backup directory (with any missing parents) and proves it actually
# accepts a write. This is the ONLY function that creates the backup tree, and
# every re-encode path calls it after its final confirmation and before the first
# flac invocation - so the "nothing is re-encoded without a backup" guarantee is
# unchanged, while a run the user cancels leaves no stray directory behind.
# Failure is reported and returned, never fatal to the shell, so the caller can
# print its own "return to menu" prompt.
# Arguments:
#   $1 - Backup root directory (already resolved + validated)
# Returns 0 on success, 1 with the reason on stderr.
########################################
ensure_backup_root() {
    local backup_root="${1%/}"

    if ! mkdir -p "$backup_root"; then
        echo "Error: Could not create the backup directory '$backup_root'." >&2
        return 1
    fi
    if ! backup_root_writable "$backup_root"; then
        echo "Error: The backup directory '$backup_root' is not writable." >&2
        return 1
    fi
    return 0
}

########################################
# FUNCTION: reencode_one_file
# Core single-file reencode logic shared by every reencode path.
# Backs the original up into the mirrored backup tree, runs flac with
# --verify --compression-level-0 --decode-through-errors --preserve-modtime,
# then replaces the original with the reencoded temp file on success.
# SUCCESS/FAILURE/WARNING lines are always appended to the run log and echoed to
# the terminal depending on STATUS_TO_CONSOLE (see write_status); the quieter
# "Backup created for:" line goes to the log file only.
# Arguments:
#   $1 - Absolute path to the FLAC file
#   $2 - Tracking database path (for mark_as_reencoded)
#   $3 - Log file path
#   $4 - Library root directory (prefix stripped to build the backup path)
#   $5 - Backup root directory (mirrored copy of the library)
# Returns 0 on success, 1 on failure.
########################################
reencode_one_file() {
    local flac_file="$1"
    local db_path="$2"
    local log_file="$3"
    local library_dir="${4%/}"
    local backup_root="${5%/}"

    local file_dir base temp_file backup_target

    # Determine the file's directory and file name.
    file_dir=$(dirname "$flac_file")
    base=$(basename "$flac_file")
    # The reencode temp is named 'tmp_<base>.part' (NOT '*.flac') so it can
    # never be mistaken for real library content: find_real_flac_files feeds on
    # '*.flac', which keeps a live temp out of a concurrent option-4 find stream
    # and keeps an interrupted-run leftover out of the next scan / reencode-NEW.
    temp_file="${file_dir}/tmp_${base}.part"

    # A leftover 'tmp_<base>.part' from an earlier INTERRUPTED run would cause
    # flac (without -f) to refuse writing: "output file ... already exists."
    # That temp lives in the script's own namespace, so deleting it first is
    # always safe: no stale residue can ever block a fresh run.
    rm -f "$temp_file"

    # Mirror the file's library path into the backup tree. A file that is not
    # under the library root (possible for a row in a hand-edited/older scan CSV)
    # has nowhere to be backed up, so it is refused rather than re-encoded
    # unprotected: every reencode in this script is preceded by a backup.
    backup_target="$(get_backup_target "$library_dir" "$backup_root" "$flac_file")"
    if [ -z "$backup_target" ]; then
        write_status "WARNING: $flac_file is not under the library ($library_dir); cannot back it up. Skipping reencode." "$log_file"
        return 1
    fi

    # Reencode the file using the specified FLAC parameters.
    if ! flac --verify --compression-level-0 --decode-through-errors --preserve-modtime --silent -o "$temp_file" "$flac_file"; then
        write_status "FAILURE: Reencoding failed for $flac_file" "$log_file"
        [ -f "$temp_file" ] && rm "$temp_file"
        return 1
    fi

    # Create the mirrored backup folder, i.e. '<backup_root>/<artist>/<album>'.
    # mkdir -p builds the whole relative chain in one go, so a fresh backup root
    # needs no pre-created skeleton.
    if ! mkdir -p "$(dirname "$backup_target")"; then
        write_status "WARNING: Failed to create backup directory for $flac_file. Skipping reencode for this file." "$log_file"
        rm -f "$temp_file"
        return 1
    fi

    if [ -e "$backup_target" ]; then
        # A backup already exists for this file (e.g. a re-run over the same
        # CSV or the full-library pass, where the current file may already be
        # a reencoded version). Keep the EXISTING backup so the pristine
        # original is never overwritten; the reencode below still proceeds.
        echo "Backup already exists (keeping original): $backup_target" >> "$log_file"
    elif ! cp -p "$flac_file" "$backup_target"; then
        # -p keeps timestamps/permissions, so the backup is a faithful snapshot
        # that 'diff'/'rsync' can compare against, and a restored file keeps its
        # original mtime (which is what --preserve-modtime aims for too).
        write_status "WARNING: Failed to backup $flac_file. Skipping reencode for this file." "$log_file"
        rm -f "$temp_file"
        return 1
    else
        echo "Backup created for: $flac_file -> $backup_target" >> "$log_file"
    fi

    # Replace the original file with the reencoded version.
    if ! mv "$temp_file" "$flac_file"; then
        write_status "FAILURE: Could not overwrite $flac_file with the reencoded file." "$log_file"
        rm -f "$temp_file"
        return 1
    fi

    write_status "SUCCESS: $flac_file reencoded successfully." "$log_file"
    if ! mark_as_reencoded "$db_path" "$flac_file"; then
        # Reencode succeeded but recording failed (should be extremely rare).
        write_status "WARNING: Reencode succeeded but could not record '$flac_file' in the tracking database." "$log_file"
    fi
    return 0
}

########################################
# FUNCTION: scan_library
# Prompts for a music library directory, then recursively scans all real FLAC
# files using 'flac -t'. The script's own internal paths (legacy
# backup_FLAC_originals copies) and the .flac_scan_data/ tracking dir are
# excluded. Any file that fails the test is
# recorded (with quotes) in a CSV file stored in the library directory.
########################################
scan_library() {
    config=$(load_config)
    library_path=$(echo "$config" | jq -r '.library_path')
    
    if [ -z "$library_path" ] || [ "$library_path" == "null" ]; then
        read -rp "Enter the full path to your music library directory: " library_path
        save_config "$library_path"
    fi

    library_dir="$library_path"
    
    # Validate the directory.
    if [ ! -d "$library_dir" ]; then
        echo "Error: The directory '$library_dir' does not exist."
        read -rp "Press Enter to return to main menu..."
        return 0
    fi

    # Create scan data directory structure
    scan_data_dir="${library_dir}/.flac_scan_data"
    mkdir -p "${scan_data_dir}/reports" "${scan_data_dir}/logs"
    
    # Generate CSV + summary-log filenames with a shared timestamp so a run's
    # report and summary pair up. The CSV is the machine-readable manifest fed
    # to "Reencode problematic FLAC files (from latest scan)"; it is only
    # written when errors exist. The summary log is written on EVERY scan, clean
    # or not, so each run leaves a small human-readable audit record.
    timestamp=$(date +%F_%H-%M-%S)
    csv_output="${scan_data_dir}/reports/flac_scan_${timestamp}.csv"
    scan_log="${scan_data_dir}/logs/scan_log_${timestamp}.txt"

    echo "Scanning FLAC files in: $library_dir"
    echo "Counting FLAC files..."
    total_files=$(find_real_flac_files "$library_dir" | wc -l)
    echo "Found $total_files FLAC files to scan"
    
    error_count=0
    processed_count=0
    start_time=$(date +%s)
    last_update=0

    while IFS= read -r -d '' flac_file; do
        processed_count=$((processed_count + 1))
        # Update progress every 50 files or 1% progress
        if (( processed_count % 50 == 0 || processed_count * 100 / total_files > last_update )); then
            show_progress "$processed_count" "$total_files" "$error_count"
            last_update=$((processed_count * 100 / total_files))
        fi

        # Test the FLAC file
        if ! flac -t "$flac_file" &>/dev/null; then
            # Create CSV file if first error
            if [ $error_count -eq 0 ]; then
                echo "# Scan Report: $(date -u +%FT%TZ) | Files: $total_files | Errors: " > "$csv_output"
                echo "filepath" >> "$csv_output"
            fi
            # Log problematic file
            echo "\"${flac_file}\"" >> "$csv_output"
            error_count=$((error_count + 1))
            if stdout_is_tty; then
                # On a live terminal the bar is cleared before the error line so
                # it reaches its own row; the bar is then redrawn beneath.
                clear_progress
            fi
            # On a pipe / redirect there is no animated bar row to protect: the
            # error and latest progress are just plain text lines. (On a TTY the
            # initial show_progress above + the redraw below keep the animation.)
            if stdout_is_tty; then
                printf '%b%s\n' "${RED}Error detected in:${NC} " "$flac_file"
            else
                echo "Error detected in: $flac_file"
            fi
            show_progress "$processed_count" "$total_files" "$error_count"
        fi
    done < <(find_real_flac_files "$library_dir" -print0)

    # Clear progress line
    clear_progress

    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Finalize the report. The CSV only exists (and only makes sense) when errors
    # were found; a clean scan removes the never-populated placeholder so option 2
    # ("reencode problematic files from latest scan") never sees an empty manifest.
    if [ "$error_count" -gt 0 ]; then
        sed -i "s/| Errors: /| Errors: $error_count/" "$csv_output"
        if stdout_is_tty; then
            printf '%b\n' "${GREEN}Scan complete.${NC}"
            printf "Scanned ${YELLOW}%d${NC} files in ${YELLOW}%d${NC} seconds\n" "$processed_count" "$duration"
            printf "Found ${RED}%d${NC} errors\n" "$error_count"
            printf "CSV report generated: ${YELLOW}%s${NC}\n" "$csv_output"
        else
            echo "Scan complete."
            echo "Scanned $processed_count files in $duration seconds"
            echo "Found $error_count errors"
            echo "CSV report generated: $csv_output"
        fi
        report_line="$csv_output"
    else
        rm -f "$csv_output"
        if stdout_is_tty; then
            printf '%b\n' "${GREEN}Scan complete.${NC}"
            printf "Scanned ${YELLOW}%d${NC} files in ${YELLOW}%d${NC} seconds\n" "$processed_count" "$duration"
            printf '%b\n' "${GREEN}No errors found.${NC}"
        else
            echo "Scan complete."
            echo "Scanned $processed_count files in $duration seconds"
            echo "No errors found."
        fi
        report_line="(none - no errors found)"
    fi

    # Every scan, clean or not, writes a small human-readable summary next to the
    # reports/logs the reencode flows already use, so each run leaves an audit trail.
    {
        echo "# Scan Summary: $(date -u +%FT%TZ)"
        echo "Library: $library_dir"
        echo "Files scanned: $processed_count"
        echo "Errors found: $error_count"
        echo "Duration: ${duration}s"
        echo "Report: $report_line"
    } > "$scan_log"

    echo "Scan summary saved to: $scan_log"
    read -rp "Press Enter to return to main menu..."
}

########################################
# FUNCTION: reencode_library
# Reads the most recent scan CSV from the supplied library directory, confirms
# with the user, and re-encodes each problematic file listed in it.
#
# The scan-report metadata row and header are skipped, as are any paths that
# point into the script's own internal area (backup copies under
# backup_FLAC_originals/ or .flac_scan_data/), e.g. from an older/exported CSV.
#
# Backup Behavior:
#   The backup directory is resolved once (see resolve_backup_path) and each file
#   is mirrored into it - the library root prefix is replaced by the backup root,
#   so 'Album/song.flac' is backed up as '<backup>/Album/song.flac'. Originals
#   are never stored inside the library, so a media scanner cannot pick them up
#   as duplicate tracks.
########################################
reencode_library() {
    config=$(load_config)
    library_path=$(echo "$config" | jq -r '.library_path')
    
    if [ -z "$library_path" ] || [ "$library_path" == "null" ]; then
        read -rp "Enter the directory containing your FLAC scan CSV files (typically your music library): " library_path
        save_config "$library_path"
    fi

    library_dir="$library_path"
    
    if [ ! -d "$library_dir" ]; then
        echo "Error: The directory '$library_dir' does not exist."
        read -rp "Press Enter to return to main menu..."
        return 0
    fi

    # Locate the latest CSV file in reports directory (by modification time).
    scan_data_dir="${library_dir}/.flac_scan_data/reports"
    latest_csv=$(find "$scan_data_dir" -type f -iname "flac_scan_*.csv" -printf "%T@ %p\n" \
                 | sort -n \
                 | tail -1 \
                 | cut -d' ' -f2-)

    if [ -z "$latest_csv" ]; then
        echo "No CSV file found in '$library_dir'. Please run a scan first."
        read -rp "Press Enter to return to main menu..."
        return 0
    fi

    echo "Latest scan CSV file found: $latest_csv"
    read -rp "Type 'Y' to confirm using this CSV file for reencoding: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "User did not confirm. Aborting reencoding process."
        read -rp "Press Enter to return to main menu..."
        return 0
    fi

    # Resolve/create/validate the backup directory BEFORE any file is touched.
    # A failure here (unsafe location, unwritable export) aborts the run rather
    # than re-encoding a single file without a backup. Resolution and creation are
    # two steps (see resolve_backup_path / ensure_backup_root) purely so callers
    # that only DISPLAY a path cannot create anything; here both happen up front
    # because the user already confirmed the CSV ('Y' immediately above).
    backup_root=""
    if ! backup_root=$(resolve_backup_path "$library_dir"); then
        read -rp "Press Enter to return to main menu..."
        return 0
    fi
    if ! ensure_backup_root "$backup_root"; then
        read -rp "Press Enter to return to main menu..."
        return 0
    fi

    # Create scan data directory if needed
    scan_data_dir="${library_dir}/.flac_scan_data"
    mkdir -p "${scan_data_dir}/logs"

    # Tracking database for successfully reencoded files.
    db_path=$(get_reencoded_db_path "$library_dir")

    # Generate a log file for the reencoding process.
    log_file="${scan_data_dir}/logs/reencode_log_$(date +%F_%H-%M-%S).txt"
    {
        echo "Reencoding started at $(date)"
        echo "Library: $library_dir"
        echo "Backups: $backup_root"
        echo "CSV: $latest_csv"
        echo ""
    } > "$log_file"

    total_files=0
    success_count=0
    fail_count=0

    # Process each problematic file listed in the CSV.
    while IFS=, read -r flac_file; do
        # Remove any surrounding quotes.
        flac_file=${flac_file//\"/}

        # Skip the header row and the scan-report metadata line (scan_library
        # writes a leading '# Scan Report: ...' row that is not a file path).
        if [[ "$flac_file" == "filepath" ]] || [[ "$flac_file" == \#* ]]; then
            continue
        fi

        # Skip any rows that point into the script's own internal area (backup
        # copies or .flac_scan_data/) — these should never be re-encoded.
        if is_internal_flac_path "$flac_file"; then
            echo "Skipping internal/backup path: $flac_file"
            continue
        fi

        # A path outside the library has no home in the mirrored backup tree, so
        # it cannot be backed up. Skip it loudly instead of re-encoding it
        # unprotected (this is also how the internal-path filter above behaves).
        if ! get_backup_target "$library_dir" "$backup_root" "$flac_file" >/dev/null; then
            echo "Skipping path outside the library: $flac_file"
            continue
        fi

        total_files=$((total_files + 1))
        echo "Processing file: $flac_file"

        if reencode_one_file "$flac_file" "$db_path" "$log_file" "$library_dir" "$backup_root"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done < "$latest_csv"

    echo "Reencoding complete at $(date)" | tee -a "$log_file"
    echo "Total files processed: $total_files" | tee -a "$log_file"
    echo "Successful reencodes: $success_count" | tee -a "$log_file"
    echo "Failed reencodes: $fail_count" | tee -a "$log_file"
    echo "Backups stored in: $backup_root" | tee -a "$log_file"
    echo "Detailed log saved as: $log_file"
    read -rp "Press Enter to return to main menu..."
}

########################################
# FUNCTION: reencode_all_files
# Reencodes EVERY "real" FLAC file in the library (not just problematic ones).
# Shows a prominent warning and requires explicit confirmation before proceeding.
# Each original file is mirrored into the configured backup directory (outside
# the library) before it is replaced.
# The script's own internal paths (legacy 'backup_FLAC_originals' copies and the
# .flac_scan_data tracking dir) are excluded (both the count and the processed
# set) so they are never re-encoded or backed up a second time.
########################################
reencode_all_files() {
    config=$(load_config)
    library_path=$(echo "$config" | jq -r '.library_path')
    
    if [ -z "$library_path" ] || [ "$library_path" == "null" ]; then
        read -rp "Enter the full path to your music library directory: " library_path
        save_config "$library_path"
    fi

    library_dir="$library_path"

    if [ ! -d "$library_dir" ]; then
        echo "Error: The directory '$library_dir' does not exist."
        read -rp "Press Enter to return to main menu..."
        return 0
    fi

    # Count real FLAC files (find_real_flac_files skips the script's own internal
    # paths and the .flac_scan_data tracking dir, consistent with reencode_new_files).
    echo "Counting FLAC files..."
    total_files=$(find_real_flac_files "$library_dir" | wc -l)
    
    if [ "$total_files" -eq 0 ]; then
        echo "No FLAC files found in '$library_dir'."
        read -rp "Press Enter to return to main menu..."
        return
    fi

    # RESOLVE the backup directory before any file is touched, so the warning can
    # show the concrete destination. Resolution alone creates nothing (see
    # resolve_backup_path), so cancelling the warning leaves no stray directory:
    # the actual mkdir happens below, after 'REENCODE ALL' is typed, and still
    # before the first flac invocation.
    # '--no-prompt' because an interactive question here would appear before the
    # warning that justifies it (and before the 'REENCODE ALL' confirmation,
    # which would then have its answer swallowed). An unset backup_path therefore
    # resolves to the derived default here, and options 2/5 still offer to ask.
    backup_root=""
    if ! backup_root=$(resolve_backup_path "$library_dir" --no-prompt); then
        read -rp "Press Enter to return to main menu..."
        return
    fi
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!                              WARNING                                   !!"
    echo "!!                                                                        !!"
    echo "!!  You are about to reencode ALL $total_files FLAC files in:          !!"
    echo "!!  $library_dir"
    echo "!!                                                                        !!"
    echo "!!  This will:                                                            !!"
    echo "!!    - Reencode every FLAC file (not just corrupted ones)                !!"
    echo "!!    - Mirror each original into:                                        !!"
    echo "!!      $backup_root"
    echo "!!    - Replace each original with the reencoded version                  !!"
    echo "!!                                                                        !!"
    echo "!!  This process can take a VERY LONG TIME for large libraries.           !!"
    echo "!!  Make sure you have enough disk space for backups.                     !!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
    read -rp "Type 'REENCODE ALL' to confirm: " confirm
    if [ "$confirm" != "REENCODE ALL" ]; then
        echo "Reencode cancelled."
        read -rp "Press Enter to return to main menu..."
        return
    fi

    # The user has committed: create + write-probe the destination now. Still
    # before ANY file is touched, so an unwritable NAS export aborts here rather
    # than after audio has been rewritten.
    if ! ensure_backup_root "$backup_root"; then
        read -rp "Press Enter to return to main menu..."
        return
    fi

    # Create scan data directory and log file
    scan_data_dir="${library_dir}/.flac_scan_data"
    mkdir -p "${scan_data_dir}/logs"

    # Tracking database for successfully reencoded files.
    db_path=$(get_reencoded_db_path "$library_dir")

    log_file="${scan_data_dir}/logs/reencode_all_log_$(date +%F_%H-%M-%S).txt"
    {
        echo "Full library reencode started at $(date)"
        echo "Library: $library_dir"
        echo "Backups: $backup_root"
        echo "Total files to process: $total_files"
        echo ""
    } > "$log_file"

    echo ""
    echo "Starting reencode of all $total_files FLAC files..."
    echo ""

    success_count=0
    fail_count=0
    processed_count=0
    start_time=$(date +%s)
    last_update=0

    # Render mode: on a real terminal we keep one single-line animated bar that
    # never moves (see show_progress) and keep per-file status text off the
    # screen (STATUS_TO_CONSOLE=0) so nothing glues onto it; on a pipe / redirect
    # all per-file SUCCESS/FAILURE lines are printed as normal text and the bar
    # degrades to plain progress lines. Either way the run log gets every status
    # line. We resolve stdout's tty state once up front rather than in the loop.
    # STATUS_TO_CONSOLE is restored on exit.
    local live_tty
    if stdout_is_tty; then live_tty=1; else live_tty=0; fi
    # It only makes sense to echo per-file SUCCESS/FAILURE lines to the terminal
    # when no animated single-line bar is on the screen to protect, i.e. on a
    # pipe/redirect request (live_tty==0). On a real terminal the statuses stay
    # in the log so the bar keeps redrawing cleanly in place.
    STATUS_TO_CONSOLE=$(( 1 - live_tty ))

    # Recursively find .flac files (using -print0 to handle spaces).
    while IFS= read -r -d '' flac_file; do
        processed_count=$((processed_count + 1))
        if [ "$live_tty" = "1" ]; then
            # Redraw the animated bar in place on every file so it stays put.
            show_progress "$processed_count" "$total_files" "$fail_count" "Failed"
        elif (( processed_count % 50 == 0 || processed_count * 100 / total_files > last_update )); then
            show_progress "$processed_count" "$total_files" "$fail_count" "Failed"
            last_update=$((processed_count * 100 / total_files))
        fi

        if reencode_one_file "$flac_file" "$db_path" "$log_file" "$library_dir" "$backup_root"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done < <(find_real_flac_files "$library_dir" -print0)

    # Clear progress line and restore console status output for later echoes.
    clear_progress
    STATUS_TO_CONSOLE=1

    end_time=$(date +%s)
    duration=$((end_time - start_time))

    echo ""
    echo "Reencode complete at $(date)" | tee -a "$log_file"
    echo "Total files processed: $processed_count" | tee -a "$log_file"
    echo "Successful reencodes: $success_count" | tee -a "$log_file"
    echo "Failed reencodes: $fail_count" | tee -a "$log_file"
    echo "Backups stored in: $backup_root" | tee -a "$log_file"
    echo "Duration: ${duration} seconds" | tee -a "$log_file"
    echo "Detailed log saved as: $log_file"
    read -rp "Press Enter to return to main menu..."
}
########################################
# FUNCTION: reencode_new_files
# Reencodes only the FLAC files that have never been successfully reencoded
# into the original format by this script (i.e. not present in the tracking DB).
# Newly added albums and freshly re-downloaded (previously deleted) albums are
# detected via MD5+size and reencoded; everything else is skipped.
# Each original file is mirrored into the configured backup directory (outside
# the library) before it is replaced.
########################################
reencode_new_files() {
    config=$(load_config)
    library_path=$(echo "$config" | jq -r '.library_path')

    if [ -z "$library_path" ] || [ "$library_path" == "null" ]; then
        read -rp "Enter the full path to your music library directory: " library_path
        save_config "$library_path"
    fi

    library_dir="$library_path"

    if [ ! -d "$library_dir" ]; then
        echo "Error: The directory '$library_dir' does not exist."
        read -rp "Press Enter to return to main menu..."
        return 0
    fi

    # NOTE: the backup directory is NOT resolved here. resolve_backup_path may
    # PROMPT (when no backup_path is configured yet), and prompting before the
    # user has confirmed the destructive operation would both interrupt the flow
    # and swallow a line of stdin meant for the confirmation below. It runs
    # after the confirmation instead - still before any file is touched.

    # Create scan data directory and determine tracking DB path.
    scan_data_dir="${library_dir}/.flac_scan_data"
    mkdir -p "${scan_data_dir}/logs"

    db_path=$(get_reencoded_db_path "$library_dir")
    # NOTE: must be called as a plain command (not $() substitution) so the
    # global REENCODED_SET is populated in THIS shell, not a discarded subshell.
    load_reencoded_set "$db_path"
    db_entries=${#REENCODED_SET[@]}

    # Count real FLAC files (find_real_flac_files skips the script's own internal
    # paths and the .flac_scan_data tracking dir so incremental reencodes stay accurate).
    echo "Counting FLAC files..."
    total_files=$(find_real_flac_files "$library_dir" | wc -l)

    if [ "$total_files" -eq 0 ]; then
        echo "No FLAC files found in '$library_dir'."
        read -rp "Press Enter to return to main menu..."
        return
    fi

    # Discovery pass: gather files absent from the tracking DB.
    echo "Checking which FLAC files have never been reencoded ($db_entries entry/entries in '$db_path')..."
    new_files=()
    skipped_count=0
    while IFS= read -r -d '' flac_file; do
        # Guard on the exit status (not just a non-empty string): an unreadable/
        # corrupt fingerprint makes get_file_fingerprint return 1, and the file
        # is then treated as new/needing reencode below.
        if fp=$(get_file_fingerprint "$flac_file"); then
            read -r md5 size mtime _rest <<< "$fp"
            key="${md5}|${size}"
            if [[ -n "${REENCODED_SET[$key]+x}" ]]; then
                skipped_count=$((skipped_count + 1))
                continue
            fi
        fi
        # Either fingerprint could not be read or this exact MD5+size is unknown:
        # treat the file as new/needing reencode.
        new_files+=("$flac_file")
    done < <(find_real_flac_files "$library_dir" -print0)

    new_count=${#new_files[@]}

    if [ "$new_count" -eq 0 ]; then
        echo ""
        if stdout_is_tty; then
            printf '%b\n' "${GREEN}All $total_files FLAC files have already been reencoded.${NC}"
        else
            echo "All $total_files FLAC files have already been reencoded."
        fi
        echo "Nothing to do. If you added new music, run this option again after adding files."
        read -rp "Press Enter to return to main menu..."
        return
    fi

    # Preview + confirmation (destructive-op style, consistent with the script).
    echo ""
    if stdout_is_tty; then
        echo "Found ${YELLOW}${new_count}${NC} new FLAC file(s) out of $total_files total that have never been reencoded."
    else
        echo "Found $new_count new FLAC file(s) out of $total_files total that have never been reencoded."
    fi
    echo "Each will be reencoded with --verify and its original mirrored into the backup directory."
    read -rp "Reencode these ${new_count} file(s)? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Reencode cancelled."
        read -rp "Press Enter to return to main menu..."
        return
    fi

    # Resolve/create/validate the backup directory now that the user has
    # committed to the run. Still before any file is touched: an unsafe or
    # unwritable destination aborts here rather than after audio has been
    # rewritten.
    backup_root=""
    if ! backup_root=$(resolve_backup_path "$library_dir"); then
        read -rp "Press Enter to return to main menu..."
        return
    fi
    echo "Backups will be written to: $backup_root"

    # The user committed to the reencode just above, so create + write-probe the
    # destination now - still before any file is touched.
    if ! ensure_backup_root "$backup_root"; then
        read -rp "Press Enter to return to main menu..."
        return
    fi

    # Create log file.
    log_file="${scan_data_dir}/logs/reencode_new_log_$(date +%F_%H-%M-%S).txt"
    {
        echo "New-file reencode started at $(date)"
        echo "Library: $library_dir"
        echo "Backups: $backup_root"
        echo "Total FLAC files found: $total_files"
        echo "Already reencoded (skipped): $skipped_count"
        echo "New files to process: $new_count"
        echo ""
    } > "$log_file"

    echo ""
    echo "Starting reencode of $new_count new FLAC files..."
    echo ""

    success_count=0
    fail_count=0
    processed_count=0
    start_time=$(date +%s)
    last_update=0

    # Process the discovered new files (two-phase: find already completed above,
    # so live temp files created here can never be picked up mid-run).
    # Render mode mirrors reencode_all_files(): single moving-proof animated bar
    # on a real terminal, plain status lines + interval progress otherwise.
    local live_tty
    if stdout_is_tty; then live_tty=1; else live_tty=0; fi
    # Same echo logic as reencode_all_files: echo per-file status lines to the
    # terminal only when there is no animated bar row to protect (non-tty run).
    STATUS_TO_CONSOLE=$(( 1 - live_tty ))

    for flac_file in "${new_files[@]}"; do
        processed_count=$((processed_count + 1))
        if [ "$live_tty" = "1" ]; then
            # Redraw the animated bar in place on every file so it stays put.
            show_progress "$processed_count" "$new_count" "$fail_count" "Failed"
        elif (( processed_count % 50 == 0 || processed_count * 100 / new_count > last_update )); then
            show_progress "$processed_count" "$new_count" "$fail_count" "Failed"
            last_update=$((processed_count * 100 / new_count))
        fi

        if reencode_one_file "$flac_file" "$db_path" "$log_file" "$library_dir" "$backup_root"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done

    # Clear progress line and restore console status output for later echoes.
    clear_progress
    STATUS_TO_CONSOLE=1

    end_time=$(date +%s)
    duration=$((end_time - start_time))

    echo ""
    echo "Reencode complete at $(date)" | tee -a "$log_file"
    echo "Total FLAC files in library: $total_files" | tee -a "$log_file"
    echo "Already reencoded (skipped): $skipped_count" | tee -a "$log_file"
    echo "New files found: $new_count" | tee -a "$log_file"
    echo "New files processed: $processed_count" | tee -a "$log_file"
    echo "Successful reencodes: $success_count" | tee -a "$log_file"
    echo "Failed reencodes: $fail_count" | tee -a "$log_file"
    echo "Backups stored in: $backup_root" | tee -a "$log_file"
    echo "Duration: ${duration} seconds" | tee -a "$log_file"
    echo "Detailed log saved as: $log_file"
    read -rp "Press Enter to return to main menu..."
}

########################################
# FUNCTION: set_paths
# Allows the user to set or update BOTH the library path and the backup
# directory. Either prompt accepts a blank answer to keep the current value.
# Changing the library with a blank backup keeps the existing backup directory
# (save_config leaves the key alone), so the two can be edited independently.
# The candidate backup path is validated before it is written to the config: an
# unsafe value is refused here, at the keyboard, rather than at the start of a
# long re-encode run.
########################################
set_paths() {
    config=$(load_config)
    current_path=$(echo "$config" | jq -r '.library_path')
    current_backup=$(echo "$config" | jq -r '.backup_path // empty')

    if [ -z "$current_path" ] || [ "$current_path" == "null" ]; then
        echo "No library path is currently configured."
    else
        echo "Current library path: $current_path"
    fi
    if [ -n "$current_backup" ]; then
        echo "Current backup directory: $current_backup"
    else
        echo "No backup directory is currently configured (will be derived as '<library>_backup')."
    fi

    read -rp "Enter new library path (leave blank to keep current): " new_path
    if [ -z "$new_path" ]; then
        new_path="$current_path"
        if [ -n "$current_path" ] && [ "$current_path" != "null" ]; then
            echo "Library path remains unchanged."
        fi
    fi

    read -rp "Enter new backup directory (leave blank to keep current): " new_backup
    if [ -z "$new_backup" ]; then
        # Blank keeps the current value. When nothing was configured either, the
        # derived sibling is offered as the value that will actually be used.
        if [ -z "$current_backup" ] && [ -n "$new_path" ] && [ "$new_path" != "null" ]; then
            new_backup="$(derive_backup_path "${new_path%/}")"
            echo "Using derived backup directory: $new_backup"
        else
            new_backup="$current_backup"
        fi
    fi
    new_backup="${new_backup%/}"

    if [ -z "$new_path" ] || [ "$new_path" == "null" ]; then
        echo "Error: A library path is required."
        read -rp "Press Enter to return to main menu..."
        return 1
    fi

    # The library may be entered for the first time here, so an existence check
    # gives the error message the user needs to fix the typo.
    if [ ! -d "$new_path" ]; then
        echo "Error: The directory '$new_path' does not exist."
        read -rp "Press Enter to return to main menu..."
        return 1
    fi

    if [ -n "$new_backup" ] && ! validate_backup_root "$new_path" "$new_backup"; then
        echo "Backup directory not changed."
        read -rp "Press Enter to return to main menu..."
        return 1
    fi

    save_config "$new_path" "$new_backup"
    echo "Library path updated to: $new_path"
    if [ -n "$new_backup" ]; then
        echo "Backup directory updated to: $new_backup"
    else
        echo "Backup directory will be derived on the next re-encode: $(derive_backup_path "${new_path%/}")"
    fi
    read -rp "Press Enter to return to main menu..."
}

########################################
# MAIN MENU
# Displays a simple menu to select either scanning or reencoding.
########################################
main_menu() {
    local menu_bar="=========================================================="
    echo "$menu_bar"
    echo "   FLAC Health Check & Reencode Script"
    echo "$menu_bar"

    # Show the currently-configured library and backup directory so the user
    # knows what a bulk operation would act on. Colors are only used on a live
    # terminal so captured/redirected output stays plain.
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


# Start the script by displaying the main menu in a loop. The BASH_SOURCE guard
# keeps the menu from auto-running when this file is sourced (the test suite
# sources it to unit-test individual functions directly).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    while true; do
        main_menu
    done
fi
