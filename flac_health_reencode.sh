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
#   - Parallel reencodes: up to 'jobs' files are processed at once (see the
#     Parallel Reencodes notes below)
#   - Automatic backup of original files before re-encoding (a backup is written
#     only the first time a file is re-encoded, so the pristine original survives
#     re-runs over the same files)
#   - Comprehensive error logging
#   - Persistent 'reencoded' tracking database (avoids redundant full re-encodes)
#
# Parallel Reencodes:
#   The stock 'flac' CLI is single-threaded per file (it has no thread-count
#   option), so the only way to use more than one core is to reencode several
#   FILES at once. All three reencode paths (2/4/5) therefore run up to 'jobs'
#   files concurrently through a shared worker pool (run_reencode_pool).
#   'jobs' is resolved by get_jobs(): $FLAC_HEALTH_JOBS, else the config's
#   "jobs" key, else a default of min(4, nproc). Set it to 1 for the old
#   strictly-sequential behavior; an explicit value is honored as-is, so a user
#   who has measured their storage can ask for more workers than the default.
#   Per-file work is unchanged (temp -> backup -> atomic mv), and each worker
#   logs to its own shard (run log + tracking DB) which the parent merges
#   afterwards, so no two workers ever append to the same file.
#
# Requirements:
#   - bash 4.3+ (associative arrays, 'wait -n' for the worker pool)
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

# Pool state -----------------------------------------------------------------
# POOL_WORKERS_USED is the PARENT-visible output of run_reencode_pool: the
# high-water worker id, i.e. how many per-worker shards the run created. Worker
# ids are allocated per FILE (not per worker slot), so it is normally larger
# than the job count, and it is 0 for a sequential (jobs=1) run, which creates
# no shards at all. Initialised here because callers under 'set -u' read it
# right after the call to decide what merge_reencode_shards must fold in.
declare -g POOL_WORKERS_USED=0

# POOL_PROCESSED / POOL_SUCCESS / POOL_FAIL are run_reencode_pool's completion
# tally. They are re-initialised per run inside the function.
declare -g POOL_PROCESSED=0
declare -g POOL_SUCCESS=0
declare -g POOL_FAIL=0

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
#   $3 - (optional) New worker count (see get_jobs). Omitted leaves the
#        existing "jobs" key untouched, for the same reason as $2. The literal
#        "default" clears the key instead, so get_jobs() re-derives it.
########################################
save_config() {
    local new_path="$1"
    local new_backup="${2:-}"
    local new_jobs="${3:-}"
    if [ -n "$new_backup" ]; then
        config=$(jq --arg path "$new_path" --arg backup "$new_backup" \
            '.library_path = $path | .backup_path = $backup' "$CONFIG_FILE")
    else
        config=$(jq --arg path "$new_path" '.library_path = $path' "$CONFIG_FILE")
    fi
    # 'jobs' is only rewritten when a caller passes one, exactly like
    # backup_path above: a library-only update must not silently reset the
    # user's worker count back to the default. The sentinel "default" deletes the
    # key so the auto-detected value takes over again.
    if [ "$new_jobs" = "default" ]; then
        config=$(jq 'del(.jobs)' <<< "$config")
    elif [ -n "$new_jobs" ]; then
        config=$(jq --argjson jobs "$new_jobs" '.jobs = $jobs' <<< "$config")
    fi
    echo "$config" > "$CONFIG_FILE"
}

########################################
# FUNCTION: get_jobs
# Resolves the number of concurrent reencode workers, in precedence order:
#   1. $FLAC_HEALTH_JOBS  (per-run override)
#   2. the config file's "jobs" key
#   3. a default of min(4, nproc)
# An EXPLICIT value (1 or 2 above) is returned as-is - a user who has measured
# their storage may deliberately ask for more workers than the default. Only a
# value that is absent, non-numeric or < 1 falls back to the default. The
# dependency check runs first, so jq/nproc are guaranteed to exist here.
# Output: a positive integer, 1 meaning "strictly sequential".
########################################
get_jobs() {
    local raw=""

    if [ -n "${FLAC_HEALTH_JOBS:-}" ]; then
        raw="$FLAC_HEALTH_JOBS"
    elif [ -f "$CONFIG_FILE" ]; then
        raw=$(jq -r '(.jobs // empty) | if type == "number" then tostring else . end' "$CONFIG_FILE" 2>/dev/null)
    fi

    if [[ ! "$raw" =~ ^[0-9]+$ ]] || [ "$raw" -lt 1 ]; then
        raw=""
    fi

    # Default: modest even on a big box. Every file moves roughly 3x its size
    # through the filesystem (source read, temp write, backup copy), so an
    # unbounded pool saturates the storage pool - and that pool is usually also
    # serving media players - long before it saturates the CPU.
    if [ -z "$raw" ]; then
        local cores
        cores=$(nproc 2>/dev/null) || cores=2
        [[ "$cores" =~ ^[0-9]+$ ]] || cores=2
        raw=4
        if [ "$cores" -lt "$raw" ]; then
            raw="$cores"
        fi
        [ "$raw" -lt 1 ] && raw=1
    fi

    printf '%s\n' "$raw"
}

# Ensure required commands are available. NOTE: jq is required too -
# and a bare "jq: command not found" would kill the script with status 127
# and leave a zero-byte config behind. The package to suggest differs per
# tool, so map the command to its Debian/Ubuntu package.
for cmd in flac metaflac jq; do
    if ! command -v "$cmd" &>/dev/null; then
        case "$cmd" in
            jq) pkg=jq ;;
            *)  pkg=flac ;;   # the flac package also provides metaflac
        esac
        echo "Error: The '$cmd' command is not installed. Please install it (e.g., sudo apt-get install $pkg) and try again."
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
# FUNCTION: record_reencoded_to
# Appends a successfully reencoded file's fingerprint to an ARBITRARY file
# instead of the shared tracking DB. This is what makes parallel workers safe:
# each worker writes its own shard, so no two processes ever append to the same
# file (whose append atomicity is NOT guaranteed anyway on NFS/SMB, where a
# media library commonly lives). The parent concatenates the shards into
# reencoded.db afterwards (see merge_reencode_shards).
# The line format is identical to mark_as_reencoded's, so a shard is
# indistinguishable from a real DB once merged.
# Arguments:
#   $1 - Target file (a per-worker shard, or the DB itself when jobs=1)
#   $2 - FLAC file path
# Returns non-zero if the fingerprint could not be generated.
########################################
record_reencoded_to() {
    local target_path="$1"
    local file="$2"
    local fp

    fp=$(get_file_fingerprint "$file") || return 1

    mkdir -p "$(dirname "$target_path")"
    printf '%s %s\n' "$fp" "$file" >> "$target_path"
    return 0
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
# SUCCESS/FAILURE/WARNING lines are appended to whichever log file is passed in
# and echoed to the terminal depending on STATUS_TO_CONSOLE (see write_status);
# the quieter "Backup created for:" line goes to the log file only.
#
# Parallel safety: the two write targets are PARAMETERS, not globals. The pool
# hands each worker its own per-process log shard (LOG_SHARD) and DB shard
# (DB_SHARD), so concurrent workers never append to the same file and no
# locking or O_APPEND atomicity assumption is needed.
# Arguments:
#   $1 - Absolute path to the FLAC file
#   $2 - Tracking file for successful reencodes: the DB itself when running
#        sequentially, otherwise this worker's DB shard (merged later)
#   $3 - Log file path (the run log, or this worker's log shard)
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
    if ! record_reencoded_to "$db_path" "$flac_file"; then
        # Reencode succeeded but recording failed (should be extremely rare).
        write_status "WARNING: Reencode succeeded but could not record '$flac_file' in the tracking database." "$log_file"
    fi
    return 0
}
########################################
# FUNCTION: shard_dir_for
# Returns the directory holding a run's per-worker shards: a 'shards' directory
# SIBLING to the run log, i.e. '.flac_scan_data/shards'. Never named '*.flac'
# and never under a path find_real_flac_files scans, so a stray shard can never
# be mistaken for library content or for a reencode temp.
# Arguments:
#   $1 - Run log path
########################################
shard_dir_for() {
    printf '%s/shards\n' "$(dirname "$1")"
}

########################################
# FUNCTION: shard_path_for
# Returns the shard path of one kind for one worker, namespaced by the RUN LOG's
# basename. The basename is unique per run, so two overlapping runs (e.g. option 4
# started while an option 5 run is still finishing) can never share a shard -
# the same reasoning that makes reencode temps per-file.
# Arguments:
#   $1 - Run log path
#   $2 - Worker id
#   $3 - 'log', 'db', or 'result'
########################################
shard_path_for() {
    local log_file="$1"
    local worker_id="$2"
    local kind="$3"
    local ext

    # Explicit mapping with no default fallthrough: a typo'd kind must not
    # silently alias onto the log shard, which would make several workers
    # append to one file.
    case "$kind" in
        log)    ext="log" ;;
        db)     ext="db" ;;
        result) ext="result" ;;
        *)
            echo "shard_path_for: unknown shard kind '$kind'" >&2
            return 1
            ;;
    esac

    printf '%s/%s_w%s.%s\n' "$(dirname "$log_file")" \
        "$(basename "$log_file")" "$worker_id" "$ext"
}



########################################
# FUNCTION: merge_reencode_shards
# Concatenates a run's per-worker shards into the real run log and tracking DB,
# then removes them. Runs only AFTER every worker has finished (run_reencode_pool
# drains first), so the merge itself is single-threaded.
# The DB shard holds exactly the "<md5> <size> <mtime> <path>" lines
# record_reencoded_to wrote - byte-identical in format to a directly-appended DB
# line - so the merge is a plain append and a pre-existing DB is preserved.
# A worker that failed a file still writes its log shard (that is the point),
# while its DB shard may be absent or empty; both cases are handled. Only ids
# that actually own a shard are ever touched, so the directory can be cleaned up
# even when other runs' shards are still present.
# Arguments:
#   $1 - Run log path (final destination)
#   $2 - Tracking DB path (final destination)
#   $3 - High-water worker id from the pool (POOL_WORKERS_USED): worker ids are
#        allocated per FILE, so this is usually larger than the job count
########################################
merge_reencode_shards() {
    local log_file="$1"
    local db_path="$2"
    local workers="$3"
    local id db_sh log_sh

    for (( id = 0; id < workers; id++ )); do
        db_sh=$(shard_path_for "$log_file" "$id" db)
        log_sh=$(shard_path_for "$log_file" "$id" log)
        if [ -f "$db_sh" ]; then
            if [ -s "$db_sh" ]; then
                mkdir -p "$(dirname "$db_path")"
                cat "$db_sh" >> "$db_path"
            fi
            rm -f "$db_sh"
        fi
        if [ -f "$log_sh" ]; then
            if [ -s "$log_sh" ]; then
                cat "$log_sh" >> "$log_file"
            fi
            rm -f "$log_sh"
        fi
    done
    # Remove the shard directory if this run was its last user.
    rmdir "$(shard_dir_for "$log_file")" 2>/dev/null || true
}

########################################
# FUNCTION: run_reencode_pool
# The shared worker pool behind ALL three reencode paths (2/4/5). Reads
# NUL-separated file paths from the file at $6, keeps up to $1 workers busy, and
# calls reencode_one_file for each file inside a worker.
#
# 'wait -n' (bash 4.3+) is used rather than a wave/barrier pool on purpose: a
# corrupt file rescued with --decode-through-errors can take an order of
# magnitude longer than a healthy one, so "dispatch N, wait for all, repeat"
# would idle the other workers for the rest of every batch. wait -n backfills
# the moment any single worker exits, and it lets the progress bar advance
# continuously instead of lurching in N-file steps.
#
# Results travel through the two side channels any pool of this shape needs:
# a WORKER_EXIT map from pid to worker id (a guard against pid reuse), and the
# per-worker DB/log shards plus a dispatch-ordered index. The parent tallies
# completions by sweeping pids for liveness ('kill -0'), which never consumes a
# status it could not read.
#
# Arguments:
#   $1 - Worker count (1 = strictly sequential, no children at all)
#   $2 - Run log path (shard naming is derived from it)
#   $3 - Tracking DB path (written directly only on the sequential path)
#   $4 - Library root directory
#   $5 - Backup root directory
#   $6 - NUL-separated input list (must be fully written before the call)
#   $7 - Output mode: 0 = animated single-line bar, 1 = quiet (statuses stay in
#        the log shards), 2 = replay per-file lines from the shards afterwards
#   $8 - Label for the bar's tallies ("Failed" is the historical wording)
# Sets (globals, read by the caller for its summary):
#   POOL_PROCESSED, POOL_SUCCESS, POOL_FAIL, POOL_MODE
########################################
run_reencode_pool() {
    local jobs="$1"
    local log_file="$2"
    local db_path="$3"
    local library_dir="${4%/}"
    local backup_root="${5%/}"
    local list_path="$6"
    local label="${8:-Failed}"

    POOL_MODE="$7"
    POOL_PROCESSED=0
    POOL_SUCCESS=0
    POOL_FAIL=0

    # Sequential mode: no pool at all. This is the 'jobs=1' escape hatch and it
    # is kept equivalent to the pre-parallel behavior - no child processes, no
    # shards, and per-file statuses land in the run log in file order.
    if [ "$jobs" -le 1 ]; then
        local flac_file total_files
        total_files=$(_count_nul_list "$list_path")
        while IFS= read -r -d '' flac_file; do
            POOL_PROCESSED=$((POOL_PROCESSED + 1))
            if [ "$POOL_MODE" -eq 0 ]; then
                show_progress "$POOL_PROCESSED" "$total_files" "$POOL_FAIL" "$label"
            fi
            if reencode_one_file "$flac_file" "$db_path" "$log_file" "$library_dir" "$backup_root"; then
                POOL_SUCCESS=$((POOL_SUCCESS + 1))
            else
                POOL_FAIL=$((POOL_FAIL + 1))
            fi
        done < "$list_path"
        return 0
    fi

    _pool_setup_state "$jobs" "$log_file"
    _pool_dispatch_loop "$list_path" "$jobs" "$log_file" "$db_path" \
        "$library_dir" "$backup_root" "$label"
    _pool_drain "$label"

    # Tally completions from the workers' result files FIRST, then replay the
    # per-file lines: the replay's output would otherwise appear before the
    # summary counts it is meant to accompany.
    _pool_tally_results
    if [ "$POOL_MODE" -eq 2 ]; then
        _pool_replay_status_lines
    fi
    # Publish the pool's high-water worker id BEFORE releasing the per-run state:
    # it is what tells the caller how many shards this run created, and ids are
    # allocated per file rather than per worker slot.
    POOL_WORKERS_USED="$POOL_NEXT_ID"
    _pool_cleanup_state
    return 0
}


# files using 'flac -t'. The script's own internal paths (legacy
# backup_FLAC_originals copies) and the .flac_scan_data/ tracking dir are
# excluded. Any file that fails the test is
# recorded (with quotes) in a CSV file stored in the library directory.
########################################
_count_nul_list() {
    local count=0
    while IFS= read -r -d '' _rec <&4; do
        count=$((count + 1))
    done 4< "$1"
    printf '%s\n' "$count"
}

########################################
# FUNCTION: _pool_setup_state
# Creates the shard directory and initialises the parent's in-flight bookkeeping
# for one pooled run: the dispatch index (file order, used to make the replay
# deterministic) and the pid -> worker-id map.
# Arguments:
#   $1 - Worker count
#   $2 - Run log path
########################################
_pool_setup_state() {
    # shellcheck disable=SC2034  # POOL_JOBS/POOL_WORKER_EXIT are pool-wide state
    # read by _pool_dispatch_loop and _pool_sweep_finished below: they are the
    # in-flight bookkeeping shared through script scope, like POOL_PIDS.
    POOL_JOBS="$1"
    POOL_LOG_FILE="$2"
    POOL_SHARD_DIR="$(shard_dir_for "$POOL_LOG_FILE")"
    POOL_INDEX="${POOL_SHARD_DIR}/$(basename "$POOL_LOG_FILE").index"
    POOL_NEXT_ID=0
    POOL_PIDS=()
    mkdir -p "$POOL_SHARD_DIR"
    : > "$POOL_INDEX"
    declare -gA POOL_WORKER_EXIT=()
    return 0
}
########################################
# FUNCTION: _pool_start_worker
# Forks one worker for one file. A FAILED fork (not a failed reencode) is counted
# as a failure rather than aborting: one momentary resource shortage must not
# kill a multi-hour run. The worker re-encodes the file writing to ITS OWN shards
# and exits with the per-file status, which the dispatch loop harvests by pid.
# Arguments:
#   $1 - Worker id
#   $2 - FLAC file path
#   $3 - Run log path
#   $4 - Library root directory
#   $5 - Backup root directory
########################################
_pool_start_worker() {
    local worker_id="$1"
    local flac_file="$2"
    local log_file="$3"
    local library_dir="$4"
    local backup_root="$5"
    local pid

    (
        # Bind this worker's shards. They are LOCAL to the child and passed
        # explicitly to reencode_one_file, so no shared global decides where a
        # worker writes.
        local log_shard db_shard result_shard rc
        log_shard="$(shard_path_for "$log_file" "$worker_id" log)"
        db_shard="$(shard_path_for "$log_file" "$worker_id" db)"
        result_shard="$(shard_path_for "$log_file" "$worker_id" result)"
        # Per-file status text must never reach the screen while the parent owns
        # the animated bar line; every status still reaches the log shard.
        STATUS_TO_CONSOLE=0
        if reencode_one_file "$flac_file" "$db_shard" "$log_shard" \
                "$library_dir" "$backup_root"; then
            rc=0
        else
            rc=1
        fi
        # Publish this worker's outcome for the parent to tally. Written by the
        # worker (not the parent) so the count reflects what actually ran, and
        # one record per file so the parent's sum is an exact file count. A
        # failed worker still records FAIL, so nothing is lost.
        printf 'PROCESSED=1\nFAIL=%s\n' "$rc" > "$result_shard"
        exit "$rc"
    ) &
    pid=$!
    # shellcheck disable=SC2034  # read by _pool_sweep_finished (same script scope)
    POOL_WORKER_EXIT["$pid"]="$worker_id"
    POOL_PIDS+=("$pid")
    return 0
}

########################################
# FUNCTION: _pool_sweep_finished
# Removes every pid that has already exited from the in-flight list and returns
# how many were still running (in POOL_RUNNING). Uses 'kill -0' as the liveness
# probe: portable, and unlike 'wait -n' it never consumes a status that this
# function would then be unable to report.
########################################
_pool_sweep_finished() {
    local remaining=() p
    for p in "${POOL_PIDS[@]}"; do
        if kill -0 "$p" 2>/dev/null; then
            remaining+=("$p")
        else
            unset 'POOL_WORKER_EXIT[$p]'
        fi
    done
    POOL_PIDS=("${remaining[@]}")
    POOL_RUNNING=${#POOL_PIDS[@]}
    return 0
}

########################################
# FUNCTION: _pool_dispatch_loop
# Feeds the file list to the pool, keeping exactly POOL_JOBS workers in flight.
# Every dispatched path is appended to the index (so a replayed status list keeps
# file order), and completions are swept before each new file is started so a
# long-running file cannot leave finished workers' pids sitting in the list.
# Arguments:
#   $1 - NUL-separated input list
#   $2 - Worker count
#   $3 - Run log path
#   $4 - DB path (unused by the parent here; kept for call-site symmetry)
#   $5 - Library root directory
#   $6 - Backup root directory
#   $7 - Bar label
########################################
_pool_dispatch_loop() {
    local list_path="$1"
    local jobs="$2"
    local log_file="$3"
    local library_dir="$5"
    local backup_root="$6"
    local label="$7"
    local flac_file total_files

    total_files=$(_count_nul_list "$list_path")

    exec 3< "$list_path"
    while IFS= read -r -d '' flac_file <&3; do
        printf '%s\n' "$flac_file" >> "$POOL_INDEX"

        # Backpressure: once the pool is full, block on ANY single worker
        # finishing (wait -n) and then sweep, so the freed slot is refilled
        # immediately instead of after the whole batch.
        while :; do
            _pool_sweep_finished
            [ "$POOL_RUNNING" -lt "$jobs" ] && break
            wait -n "${POOL_PIDS[@]}" 2>/dev/null || true
        done

        if ! _pool_start_worker "$POOL_NEXT_ID" "$flac_file" "$log_file" \
                "$library_dir" "$backup_root"; then
            POOL_FAIL=$((POOL_FAIL + 1))
            POOL_PROCESSED=$((POOL_PROCESSED + 1))
        fi
        POOL_NEXT_ID=$((POOL_NEXT_ID + 1))

        # The bar is redrawn on EVERY dispatch in non-tty mode (cheap, plain
        # text lines) and ONLY on completions in tty mode, so the animated line
        # always reflects finished files rather than merely dispatched ones.
        if [ "$POOL_MODE" -eq 1 ]; then
            _pool_report_progress "$total_files" "$label"
        elif [ "$POOL_MODE" -eq 0 ]; then
            :
        fi
    done
    exec 3<&-
    return 0
}

########################################
# FUNCTION: _pool_drain
# Waits for the last in-flight workers, sweeping completions as they land. A
# non-blocking first sweep means a pool whose workers all finished before this
# call returns immediately instead of blocking on a phantom wait.
# Arguments:
#   $1 - Bar label
########################################
_pool_drain() {
    local label="$1"
    while :; do
        _pool_sweep_finished
        [ "$POOL_RUNNING" -eq 0 ] && break
        wait -n "${POOL_PIDS[@]}" 2>/dev/null || true
    done
    return 0
}

########################################
# FUNCTION: _pool_report_progress
# Renders one progress update on a non-tty destination from the COMPLETION
# tally (POOL_PROCESSED/POOL_FAIL) plus the dispatched-file index count, so a
# captured run's footer numbers match the per-file lines it replays.
# Arguments:
#   $1 - Total file count
#   $2 - Bar label
########################################
_pool_report_progress() {
    local total="$1"
    local label="$2"
    show_progress "$POOL_PROCESSED" "$total" "$POOL_FAIL" "$label"
    return 0
}

########################################
# FUNCTION: _pool_tally_results
# Reads the KEY=VALUE result records every worker wrote into its own
# '<shard>.result' file and updates POOL_PROCESSED/POOL_SUCCESS/POOL_FAIL. One
# record per file, written by the worker itself, so a worker's outcome is
# accounted exactly once and a crash cannot double-count or lose a file.
# The files are removed as they are read, making this idempotent.
########################################
_pool_tally_results() {
    local shard_path result_file key value

    # Worker ids are handed out per FILE, not per worker slot, so a run that
    # processes 8 files with 4 workers owns the shards w0..w7. Hence the
    # high-water id (POOL_NEXT_ID) rather than the job count.
    for (( shard = 0; shard < POOL_NEXT_ID; shard++ )); do
        result_file="$(shard_path_for "$POOL_LOG_FILE" "$shard" result)"
        [ -s "$result_file" ] || continue
        while IFS='=' read -r key value; do
            case "$key" in
                PROCESSED) POOL_PROCESSED=$((POOL_PROCESSED + ${value:-0})) ;;
                FAIL)      POOL_FAIL=$((POOL_FAIL + ${value:-0})) ;;
            esac
        done < "$result_file"
        rm -f "$result_file"
    done
    # Successes are derived, never tracked separately: every file ends as
    # either a success or a failure, so this keeps the three numbers
    # consistent even if a worker died before recording its result.
    POOL_SUCCESS=$((POOL_PROCESSED - POOL_FAIL))
    return 0
}

########################################
# FUNCTION: _pool_replay_status_lines
# For a captured (non-tty) pooled run, prints the per-file SUCCESS/FAILURE lines
# in FILE ORDER at the end. During the run they went only to the workers' log
# shards (which merge_reencode_shards then folds into the run log), so this
# gives a piped run the same visible per-file feedback a sequential run has,
# without letting out-of-order worker output interleave on the terminal.
# Ordering comes from the dispatch index, not from completion order.
########################################
_pool_replay_status_lines() {
    local flac_file shard_path

    [ -s "$POOL_INDEX" ] || return 0

    while IFS= read -r flac_file; do
        for (( shard = 0; shard < POOL_NEXT_ID; shard++ )); do
            shard_path="$(shard_path_for "$POOL_LOG_FILE" "$shard" log)"
            [ -s "$shard_path" ] || continue
            # The shard's SUCCESS/FAILURE lines are per-FILE, and each file is
            # handled by exactly one worker, so a grep against this file's path
            # pulls just its line(s) - including any WARNING lines it produced.
            grep -F -- "$flac_file" "$shard_path" 2>/dev/null || true
        done
    done < "$POOL_INDEX"
    return 0
}

########################################
# FUNCTION: _pool_cleanup_state
# Releases the parent's per-run pool state (index, pid map, id counter) once a
# run is fully accounted for, so a later run in the same invocation cannot see
# stale entries. The shard DIRECTORY is removed by merge_reencode_shards.
# POOL_NEXT_ID is deliberately NOT cleared on the sequential path, where it is
# still 0 and tells the caller that no shards exist to merge.
########################################
_pool_cleanup_state() {
    rm -f "$POOL_INDEX" 2>/dev/null || true
    POOL_PIDS=()
    POOL_RUNNING=0
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

    # Worker count for this run (see get_jobs / the Parallel Reencodes notes).
    jobs="$(get_jobs)"

    # Generate a log file for the reencoding process.
    log_file="${scan_data_dir}/logs/reencode_log_$(date +%F_%H-%M-%S).txt"
    {
        echo "Reencoding started at $(date)"
        echo "Library: $library_dir"
        echo "Backups: $backup_root"
        echo "CSV: $latest_csv"
        echo "Workers: $jobs"
        echo ""
    } > "$log_file"

    # ------------------------------------------------------------------
    # Discovery pass: build the filtered, DEDUPLICATED work list.
    # Option 2 keeps the CSV's own order (the scan that produced it wrote
    # problematic files in find order) and can still contain duplicates if a
    # report was hand-edited or merged, so a repeated path is reported and
    # dropped: two workers must never race the same file.
    # ------------------------------------------------------------------
    local filter_log="${log_file}.filter.log"
    local flac_file
    seed_dir="${scan_data_dir}/seed"
    seed_list="${seed_dir}/$(basename "$log_file").paths"
    mkdir -p "$seed_dir"
    : > "$seed_list"

    total_files=0
    success_count=0
    fail_count=0
    duplicate_count=0
    declare -A SEEN_LIST=()
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
            printf '%s\n' "Skipping internal/backup path: $flac_file" >> "$filter_log"
            continue
        fi

        # A path outside the library has no home in the mirrored backup tree, so
        # it cannot be backed up. Skip it loudly instead of re-encoding it
        # unprotected (this is also how the internal-path filter above behaves).
        if ! get_backup_target "$library_dir" "$backup_root" "$flac_file" >/dev/null; then
            printf '%s\n' "Skipping path outside the library: $flac_file" >> "$filter_log"
            continue
        fi

        if [[ -n "${SEEN_LIST[$flac_file]+x}" ]]; then
            duplicate_count=$((duplicate_count + 1))
            continue
        fi
        SEEN_LIST["$flac_file"]=1

        total_files=$((total_files + 1))
        printf '%s\0' "$flac_file" >> "$seed_list"
    done < "$latest_csv"

    unset SEEN_LIST
    [ -s "$filter_log" ] && cat "$filter_log"
    rm -f "$filter_log"
    if [ "$duplicate_count" -gt 0 ]; then
        echo "Ignored $duplicate_count duplicate row(s) in the CSV."
        printf '%s\n' "Ignored $duplicate_count duplicate row(s) in the CSV." >> "$log_file"
    fi

    if [ "$total_files" -eq 0 ]; then
        echo "No files to process - nothing to do."
        echo "No files to process - nothing to do." >> "$log_file"
        rm -f "$seed_list"
        rmdir "$seed_dir" 2>/dev/null || true
        read -rp "Press Enter to return to main menu..."
        return 0
    fi

    # A live terminal cannot host per-file status text AND a single-line
    # animated bar at once, so how per-file statuses are reported depends on
    # both the destination and the worker count:
    #   mode 1 - jobs=1: historical behavior, statuses echoed to the terminal as
    #            each file is processed (the bar is a plain re-rendered line).
    #   mode 0 - pooled on a real terminal: statuses stay in the log shards and
    #            are folded into the run log afterwards, so nothing glues onto
    #            the animated single-line bar; only the bar moves.
    #   mode 2 - pooled on a pipe/redirect: no animated bar to protect, so the
    #            per-file lines are replayed in FILE ORDER when the pool drains.
    local pool_mode
    if [ "$jobs" -le 1 ]; then
        pool_mode=1
    elif stdout_is_tty; then
        pool_mode=0
    else
        pool_mode=2
    fi

    # Process the problematic files. The work list is fully materialised before
    # the pool starts, so nothing a worker creates (a temp in one of the
    # library's own directories) can be picked up mid-run.
    echo ""
    echo "Processing $total_files file(s) with $jobs worker(s)..."
    echo ""
    run_reencode_pool "$jobs" "$log_file" "$db_path" "$library_dir" "$backup_root" \
        "$seed_list" "$pool_mode" "Failed"
    success_count=$POOL_SUCCESS
    fail_count=$POOL_FAIL

    # Fold each worker's log + DB shards into the run log and the real tracking
    # DB, then discard the work list.
    merge_reencode_shards "$log_file" "$db_path" "$POOL_WORKERS_USED"
    rm -f "$seed_list"
    rmdir "$seed_dir" 2>/dev/null || true

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

    # Worker count for this run (see get_jobs / the Parallel Reencodes notes).
    jobs="$(get_jobs)"

    log_file="${scan_data_dir}/logs/reencode_all_log_$(date +%F_%H-%M-%S).txt"
    {
        echo "Full library reencode started at $(date)"
        echo "Library: $library_dir"
        echo "Backups: $backup_root"
        echo "Total files to process: $total_files"
        echo "Workers: $jobs"
        echo ""
    } > "$log_file"

    echo ""
    echo "Starting reencode of all $total_files FLAC files..."
    echo ""

    start_time=$(date +%s)

    # Render mode: on a real terminal we keep one single-line animated bar that
    # never moves (see show_progress) and keep per-file status text off the
    # screen (STATUS_TO_CONSOLE=0) so nothing glues onto it; on a pipe / redirect
    # all per-file SUCCESS/FAILURE lines are printed as normal text. Either way
    # the run log gets every status line. We resolve stdout's tty state once up
    # front rather than in the loop. STATUS_TO_CONSOLE is restored on exit.
    local live_tty
    if stdout_is_tty; then live_tty=1; else live_tty=0; fi

    # Materialise the work list FIRST. find_real_flac_files excludes the
    # script's own paths, but a temp file it writes inside a library directory
    # during a run is not covered by that filter, and a live "find | pool" pipe
    # could hand such a temp to a worker. Building the list up front closes that
    # window: the pool only ever sees paths that existed before it started.
    seed_dir="${scan_data_dir}/seed"
    seed_list="${seed_dir}/$(basename "$log_file").paths"
    mkdir -p "$seed_dir"
    find_real_flac_files "$library_dir" -print0 > "$seed_list"

    if [ "$jobs" -le 1 ]; then
        pool_mode=1
    else
        # A live terminal cannot host per-file status text and a single-line bar
        # at the same time, so pooled tty runs keep the statuses in the log
        # (mode 0) and rely on the bar, while pooled captured runs replay them in
        # file order (mode 2). See run_reencode_pool.
        if [ "$live_tty" = "1" ]; then pool_mode=0; else pool_mode=2; fi
    fi
    if [ "$pool_mode" -eq 1 ]; then
        STATUS_TO_CONSOLE=$(( 1 - live_tty ))
    fi

    echo "Processing $total_files file(s) with $jobs worker(s)..."
    run_reencode_pool "$jobs" "$log_file" "$db_path" "$library_dir" "$backup_root" \
        "$seed_list" "$pool_mode" "Failed"
    processed_count=$POOL_PROCESSED
    success_count=$POOL_SUCCESS
    fail_count=$POOL_FAIL

    # Fold each worker's log + DB shards into the run log and the real tracking
    # DB, then discard the work list.
    merge_reencode_shards "$log_file" "$db_path" "$POOL_WORKERS_USED"
    rm -f "$seed_list"
    rmdir "$seed_dir" 2>/dev/null || true

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

    # Worker count for this run (see get_jobs / the Parallel Reencodes notes).
    jobs="$(get_jobs)"

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
        echo "Workers: $jobs"
        echo ""
    } > "$log_file"

    echo ""
    echo "Starting reencode of $new_count new FLAC files..."
    echo ""

    start_time=$(date +%s)

    # The work list was built in the discovery pass above (two-phase: find and
    # classify FIRST, so a temp file any worker creates can never be picked up
    # as a "new" file mid-run). Serialise it NUL-separated for the pool.
    seed_dir="${scan_data_dir}/seed"
    seed_list="${seed_dir}/$(basename "$log_file").paths"
    mkdir -p "$seed_dir"
    : > "$seed_list"
    for flac_file in "${new_files[@]}"; do
        printf '%s\0' "$flac_file" >> "$seed_list"
    done

    # Render mode mirrors reencode_all_files(): single animated bar on a real
    # terminal (statuses stay in the log), plain status lines replayed in file
    # order otherwise.
    local live_tty
    if stdout_is_tty; then live_tty=1; else live_tty=0; fi
    if [ "$jobs" -le 1 ]; then
        pool_mode=1
        STATUS_TO_CONSOLE=$(( 1 - live_tty ))
    elif [ "$live_tty" = "1" ]; then
        pool_mode=0
    else
        pool_mode=2
    fi

    echo "Processing $new_count file(s) with $jobs worker(s)..."
    run_reencode_pool "$jobs" "$log_file" "$db_path" "$library_dir" "$backup_root" \
        "$seed_list" "$pool_mode" "Failed"
    processed_count=$POOL_PROCESSED
    success_count=$POOL_SUCCESS
    fail_count=$POOL_FAIL

    # Fold each worker's log + DB shards into the run log and the real tracking
    # DB, then discard the work list.
    merge_reencode_shards "$log_file" "$db_path" "$POOL_WORKERS_USED"
    rm -f "$seed_list"
    rmdir "$seed_dir" 2>/dev/null || true

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
    echo "Current reencode workers: $(get_jobs) (0 uses the default)"

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
    new_backup="$(printf '%s' "$new_backup" | sed 's:/$::')"

    # Worker count. Blank (or 0) clears the key so get_jobs() falls back to its
    # default; a non-numeric answer is refused rather than written, because a
    # junk value in the config would otherwise be silently ignored at run time
    # and the user would never learn their setting had no effect.
    read -rp "Enter reencode workers (leave blank or 0 for default): " new_jobs
    new_jobs="${new_jobs// /}"
    case "$new_jobs" in
        ''|0) new_jobs='default' ;;
        *[!0-9]*)
            echo "Error: '$new_jobs' is not a positive number of workers."
            read -rp "Press Enter to return to main menu..."
            return 1
            ;;
    esac

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

    save_config "$new_path" "$new_backup" "$new_jobs"
    echo "Library path updated to: $new_path"
    if [ -n "$new_backup" ]; then
        echo "Backup directory updated to: $new_backup"
    else
        echo "Backup directory will be derived on the next re-encode: $(derive_backup_path "${new_path%/}")"
    fi
    if [ -n "$new_jobs" ] && [ "$new_jobs" != 'default' ]; then
        echo "Reencode workers updated to: $new_jobs"
    else
        echo "Reencode workers reset to the default ($(get_jobs))."
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

    # Show how many files will be reencoded at once. Options 2/4/5 all use this
    # value, and it is the one knob that decides how hard the run hits the
    # storage holding the library, so it is worth surfacing before the user
    # starts a multi-hour operation. FLAC_HEALTH_JOBS is shown when it is what
    # decided the value, since an env override is easy to forget about.
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


# Start the script by displaying the main menu in a loop. The BASH_SOURCE guard
# keeps the menu from auto-running when this file is sourced (the test suite
# sources it to unit-test individual functions directly).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    while true; do
        main_menu
    done
fi
