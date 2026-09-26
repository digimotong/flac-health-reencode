#!/bin/bash
# FLAC Health Check & Re-encode Utility: scans a library with 'flac -t', then
# re-encodes the failures, backing up every original first.
#
# Requires: bash 4.3+, flac, metaflac (in the flac package) and jq.
# Usage:    ./flac_health_reencode.sh  (menu-driven; see README.md)
#
# Per-file work runs through one operation-agnostic worker pool (run_file_pool),
# shared by the reencode paths (2/4/5) and the scan (1). Worker count comes from
# get_jobs(): $FLAC_HEALTH_JOBS, else the config's "jobs" key, else
# min(4, nproc); 1 means strictly sequential. Each worker writes its own shard
# (run log + tracking DB, or a scan failure list) which the parent merges, so no
# two workers ever append to the same file.

# Configuration file path
CONFIG_FILE="$(dirname "$(realpath "$0")")/flac_health_config.json"

# Terminal colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Progress tracking
PROGRESS_WIDTH=50

# Cached by stdout_is_tty(), so a render loop pays the [ -t 1 ] test once.
declare -g STDOUT_IS_TTY=''

# 1: per-file status lines also go to the terminal. 0: log only - the live
# single-line progress bar would otherwise be scattered by them.
declare -g STATUS_TO_CONSOLE=1

# Pool state: high-water worker id, i.e. how many shards the run created. Ids
# are allocated per FILE, so it usually exceeds the job count, and it is 0 for a
# sequential run. Declared here because 'set -u' callers read it after the call.
declare -g POOL_WORKERS_USED=0

# Interrupt cleanup state. POOL_TEMP_LIST is the run-local list of the in-library
# temp files (tmp_<base>.part) the parent has dispatched, POOL_SEED_LIST is the
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

# Set by run_scan_pool: files that failed verification, and files that could not
# be tested at all. Declared here so 'set -u' callers can always read them.
declare -g POOL_ERRORS=0
declare -g POOL_UNTESTED=0

# Successfully reencoded files, keyed by md5|size (see load_reencoded_set).
declare -A REENCODED_SET

set -o errexit
set -o nounset
set -o pipefail

# Loads the config from file, creating it (empty paths) when missing.
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        jq -n '{library_path: "", backup_path: "", version: "1.1"}' > "$CONFIG_FILE"
    fi
    config=$(cat "$CONFIG_FILE")
    echo "$config"
}

# Saves the config. $2/$3 are optional; omitting one leaves its key untouched,
# so a library-only update cannot drop the backup path or the worker count.
# $3 = "default" deletes the jobs key so get_jobs() re-derives it.
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

# Worker count: $FLAC_HEALTH_JOBS, else the config's "jobs" key, else
# min(4, nproc). An explicit value is honored as-is; only absent/non-numeric/<1
# falls back to the default. Prints a positive integer, 1 = strictly sequential.
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

    # Modest default: every file moves ~3x its size through the filesystem, so
    # an unbounded pool saturates the storage long before the CPU.
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

# Required tools, checked before anything writes the config (a bare
# "jq: command not found" would exit 127 and leave a zero-byte config behind).
# Maps each command to its Debian/Ubuntu package for the install hint.
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

# Paths the script itself creates inside a library; never treated as library
# content. The backup_FLAC_originals entry is legacy (kept for installs upgraded
# from versions that backed up in-library).
readonly FLAC_INTERNAL_PATH_GLOBS=(
    '*backup_FLAC_originals/*'
    '*/.flac_scan_data/*'
)

# Prints a library's real FLAC files, excluding the internal paths above. Extra
# arguments (e.g. -print0) are forwarded to find.
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

# 0 if the path is one of the script's own internal paths, 1 otherwise. Used to
# filter non-find inputs, e.g. rows from an older scan CSV.
is_internal_flac_path() {
    local glob
    # The case patterns must stay UNQUOTED so '*' matches as a glob; quoting them
    # (as SC2254 suggests) would compare literally. An inline directive is not
    # allowed before a single case branch, hence the function-level disable.
    # shellcheck disable=SC2254
    for glob in "${FLAC_INTERNAL_PATH_GLOBS[@]}"; do
        case "$1" in
            $glob) return 0 ;;
        esac
    done
    return 1
}

# 0 while fd 1 is attached to a terminal. The answer is cached in STDOUT_IS_TTY.
stdout_is_tty() {
    [ -z "$STDOUT_IS_TTY" ] && { [ -t 1 ] && STDOUT_IS_TTY=1 || STDOUT_IS_TTY=0; }
    [ "$STDOUT_IS_TTY" = "1" ]
}

# Draws the bar/percent text, with a trailing space so a status label can follow
# on the same row. Emits no carriage return, newline or clearing - callers pick
# the animated (show_progress) or plain form.
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

# Progress bar as one self-updating line on a terminal; a plain text line
# otherwise, so pipes/CI captures stay clean. Must be the last thing drawn
# before an interactive prompt, and no bare status text may be echoed to the
# console between calls (see write_status/STATUS_TO_CONSOLE).
show_progress() {
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

# Erases the bar line. No-op off a terminal (nothing was drawn there).
clear_progress() {
    if stdout_is_tty; then
        printf "\r\033[K"
    fi
}

# Writes one status line to the run log, and to the terminal while
# STATUS_TO_CONSOLE is 1. $1 = the full line, $2 = run log path.
write_status() {
    local line="$1"
    local log_file="$2"
    printf '%s\n' "$line" >> "$log_file"
    if [ "$STATUS_TO_CONSOLE" = "1" ]; then
        printf '%s\n' "$line"
    fi
}

# Path of the reencoded-file tracking DB inside a library.
get_reencoded_db_path() {
    local library_dir="$1"
    printf '%s/.flac_scan_data/reencoded.db\n' "$library_dir"
}

# Prints a file's fingerprint "<md5> <size> <mtime>"; the md5 is the STREAMINFO
# audio md5 (header-only read). Returns 1 on failure, i.e. treat as needing
# reencode. $1 = FLAC file path.
get_file_fingerprint() {
    local file="$1"
    local md5 size mtime

    md5=$(metaflac --show-md5sum "$file" 2>/dev/null) || return 1
    size=$(stat -c %s "$file" 2>/dev/null) || return 1
    mtime=$(stat -c %Y "$file" 2>/dev/null) || return 1

    printf '%s %s %s\n' "$md5" "$size" "$mtime"
}

# Loads the tracking DB into REENCODED_SET, keyed "<md5>|<size>"; blank and
# comment lines are skipped. Sets the array in the CURRENT shell, so call it as
# a plain command, never inside $().
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

# Appends a fingerprint to an ARBITRARY file, not the shared DB: each worker uses
# its own shard so no two processes append to one file (append atomicity is not
# guaranteed on NFS/SMB, where libraries commonly live). Same line format as
# mark_as_reencoded, so a merged shard is indistinguishable from the DB.
# $1 = target file (a shard, or the DB when jobs=1), $2 = FLAC file.
record_reencoded_to() {
    local target_path="$1"
    local file="$2"
    local fp

    fp=$(get_file_fingerprint "$file") || return 1

    mkdir -p "$(dirname "$target_path")"
    printf '%s %s\n' "$fp" "$file" >> "$target_path"
    return 0
}

# Appends the file's fingerprint to the DB and adds it to REENCODED_SET.
# $1 = DB path, $2 = FLAC file. Non-zero if no fingerprint could be made.
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

# Default backup directory for a library: the path with '_backup' appended, so
# it is a sibling of the library ('/media/Music' -> '/media/Music_backup').
derive_backup_path() {
    local library_dir="${1%/}"
    printf '%s_backup\n' "$library_dir"
}

# Echoes the canonical (symlink-resolved) form of an existing directory. Uses
# 'cd -P && pwd' rather than realpath -m/--relative-to, which are GNU-only.
# $1 = directory path; returns 1 if it cannot be entered.
canonical_dir() {
    ( cd "$1" 2>/dev/null && pwd -P )
}

# 0 if the backup directory is a safe destination for originals, 1 (with the
# reason on stderr) otherwise. The backup and the library may share no ancestor
# relationship: equal paths would overwrite each original, a backup inside the
# library would be walked by media scanners, and a library inside the backup
# would be deleted by the documented 'rm -rf "$backup"' cleanup. A relative
# candidate is refused too, since resolving it against the CWD would scatter
# backups unpredictably.
# $1 = library root (must exist), $2 = backup directory
validate_backup_root() {
    local library_dir="${1%/}"
    local backup_root="${2%/}"

    if [ -z "$backup_root" ]; then
        echo "Error: No backup directory configured." >&2
        return 1
    fi

    # An absolute path is required: a relative answer is nearly always a typo,
    # and resolving it against the CWD would scatter backups.
    case "$backup_root" in
        /*) : ;;
        *)
            echo "Error: The backup directory must be an absolute path (got '$backup_root')." >&2
            return 1
            ;;
    esac

    # Canonicalise both sides when they exist; the backup may legitimately not
    # exist yet (resolve_backup_path creates it), so fall back to the spelling.
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

# Maps a library file to its backup path by swapping the library root prefix for
# the backup root, so the backup mirrors the library:
#   ('/m/Music', '/m/Music_backup', '/m/Music/2Pac/X/a.flac') -> '/m/Music_backup/2Pac/X/a.flac'
# Pure, hence directly unit-testable. Returns 1 printing nothing when the file is
# not under the library root - such a path has no backup home.
# $1 = library root, $2 = backup root, $3 = file path
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

# 0 if the backup root exists and accepts a file, 1 otherwise. Probed by WRITING,
# not 'test -w': on a root-squashed NFS export a mode test can report writable
# while every cp fails.
# $1 = backup root directory
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

# Resolves and validates the backup directory for a run: the config's
# backup_path, else a prompt offering the derived '<library>_backup' (persisted
# when accepted; skipped with $2 = --no-prompt). Pure with respect to the backup
# tree - creating the destination is ensure_backup_root's job, so a caller that
# only DISPLAYS the path leaves nothing behind. The path is the only thing on
# stdout; notices/errors go to stderr.
# $1 = library root (must exist)
# Returns 0 with the path on stdout, or 1 with the reason on stderr.
resolve_backup_path() {
    local library_dir="${1%/}"
    local no_prompt="${2:-}"
    local configured derived backup_root

    configured=$(load_config | jq -r '.backup_path // empty')

    if [ -z "$configured" ]; then
        derived="$(derive_backup_path "$library_dir")"
        if [ "$no_prompt" = "--no-prompt" ]; then
            # Derived, and deliberately NOT persisted: only an explicit answer is
            # saved, so the menu's "set with option 3" hint stays honest.
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

# Creates the backup directory and proves it accepts a write. The ONLY place the
# backup tree is created; every reencode path calls it after its final
# confirmation, so a cancelled run leaves no stray directory behind.
# $1 = backup root (already resolved + validated). 0, or 1 with a reason on stderr.
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

# Core single-file reencode: back the original up into the mirrored backup tree,
# run flac with --verify --compression-level-0 --decode-through-errors
# --preserve-modtime, then replace the original with the reencoded temp on
# success. Status lines go to $3 and to the console per STATUS_TO_CONSOLE.
# Parallel-safe: both write targets are PARAMETERS, and the pool hands each
# worker its own log/DB shard, so no two workers append to one file.
# $1 = FLAC file, $2 = tracking file (DB, or this worker's DB shard),
# $3 = log file (run log, or this worker's log shard),
# $4 = library root, $5 = backup root. 0 on success, 1 on failure.
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
    # 'tmp_<base>.part', NOT '*.flac', so a live temp is invisible to
    # find_real_flac_files and an interrupted-run leftover can never be picked
    # up by a later scan or reencode-NEW.
    temp_file="${file_dir}/tmp_${base}.part"

    # flac (without -f) refuses to write an existing output, so clear any
    # leftover temp from an interrupted run. The name is the script's own.
    rm -f "$temp_file"

    # A file outside the library root (possible for a row in a hand-edited or
    # older scan CSV) has nowhere to be backed up, so it is refused rather than
    # re-encoded unprotected.
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

    # mkdir -p builds the whole relative chain, so a fresh backup root needs no
    # pre-created skeleton.
    if ! mkdir -p "$(dirname "$backup_target")"; then
        write_status "WARNING: Failed to create backup directory for $flac_file. Skipping reencode for this file." "$log_file"
        rm -f "$temp_file"
        return 1
    fi

    if [ -e "$backup_target" ]; then
        # A backup already exists (e.g. a re-run over the same CSV, or a file
        # that is already a reencoded version). Keep the EXISTING backup so the
        # pristine original is never overwritten; the reencode still proceeds.
        echo "Backup already exists (keeping original): $backup_target" >> "$log_file"
    elif ! cp -p "$flac_file" "$backup_target"; then
        # -p keeps timestamps/permissions, so the backup is a faithful snapshot.
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
# Directory holding a run's per-worker shards: a 'shards' dir sibling to the run
# log. Never '*.flac' and never under a scanned path, so a stray shard can never
# be mistaken for library content or a reencode temp. $1 = run log path.
shard_dir_for() {
    printf '%s/shards\n' "$(dirname "$1")"
}

# Shard path of one kind for one worker, namespaced by the run log's basename so
# two overlapping runs can never share a shard. $1 = run log, $2 = worker id,
# $3 = 'log', 'db', 'scan' or 'result'.
shard_path_for() {
    local log_file="$1"
    local worker_id="$2"
    local kind="$3"
    local ext

    # Explicit mapping, no fallthrough: a typo'd kind must not alias onto the log
    # shard, which would make several workers append to one file.
    case "$kind" in
        log)    ext="log" ;;
        db)     ext="db" ;;
        # Paths that failed 'flac -t', read back to build the CSV - hence kept
        # distinct from 'log' (human status text) and 'db' (reencode bookkeeping).
        scan)   ext="scan" ;;
        result) ext="result" ;;
        *)
            echo "shard_path_for: unknown shard kind '$kind'" >&2
            return 1
            ;;
    esac

    printf '%s/%s_w%s.%s\n' "$(dirname "$log_file")" \
        "$(basename "$log_file")" "$worker_id" "$ext"
}



# Appends a run's per-worker shards to the real run log and tracking DB, then
# removes them. Runs after every worker has finished, so the merge is
# single-threaded. A DB shard holds exactly the lines record_reencoded_to wrote,
# so this is a plain append that preserves a pre-existing DB; a failed worker
# still contributes its log shard, and a missing/empty DB shard is fine.
# $1 = run log, $2 = tracking DB, $3 = POOL_WORKERS_USED (high-water worker id;
# ids are per FILE, so this usually exceeds the job count).
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

# The shared worker pool behind all four per-file paths (reencodes 2/4/5 and the
# scan 1). Reads NUL-separated paths from the file at $6 and keeps up to $1
# workers busy, calling POOL_WORKER_FN for each file. Operation-agnostic: the
# caller supplies the worker (see _pool_setup_state), so the scan reuses this
# scheduler rather than duplicating the backpressure/pid/shard machinery.
#
# 'wait -n' rather than a wave/barrier pool: a file rescued with
# --decode-through-errors can take an order of magnitude longer than a healthy
# one, and waves would idle the other workers for the rest of every batch.
# Results travel over a pid->worker-id WORKER_EXIT map (guards against pid
# reuse), the per-worker shards and a dispatch-ordered index; the parent tallies
# completions by sweeping pids with 'kill -0', so it never consumes a status it
# could not read.
#
# $1 = worker count (1 = strictly sequential, no children)
# $2 = run log (shard naming derives from it)
# $3 = per-worker result channel (the tracking DB for reencodes)
# $4 = library root, $5 = backup root
# $6 = NUL-separated input list (fully written before the call)
# $7 = output mode: 0 = animated bar, 1 = inline statuses (sequential), 2 = replay
# $8 = label for the bar's tallies
# Sets POOL_PROCESSED, POOL_SUCCESS, POOL_FAIL, POOL_MODE, POOL_WORKERS_USED.
run_file_pool() {
    local jobs="$1"
    local log_file="$2"
    local result_channel="$3"
    local library_dir="${4%/}"
    local backup_root="${5%/}"
    local list_path="$6"
    local label="${8:-Failed}"

    POOL_MODE="$7"
    POOL_PROCESSED=0
    POOL_SUCCESS=0
    POOL_FAIL=0
    # High-water mark published before the tally, for callers that read their own
    # shards back (the scan).
    POOL_WORKERS_USED=0
    # Seams defaulting to a reencode; the scan overrides all three.
    POOL_WORKER_FN="${POOL_WORKER_FN:-_reencode_pool_worker}"
    POOL_CHANNEL_KIND="${POOL_CHANNEL_KIND:-db}"
    # Empty for a reencode: its channel goes straight into $3 (the real DB) on the
    # sequential path.
    POOL_SEQ_CHANNEL_PREFIX="${POOL_SEQ_CHANNEL_PREFIX:-}"
    POOL_TOTAL_FILES=0

    # jobs=1: no children and no shards, equivalent to the pre-parallel behavior.
    # The channel is resolved per FILE via _pool_seq_channel, so ids climb exactly
    # as in the dispatch loop and a caller replaying shards by id stays correct.
    if [ "$jobs" -le 1 ]; then
        local flac_file total_files id
        total_files=$(_count_nul_list "$list_path")
        id=0
        while IFS= read -r -d '' flac_file; do
            POOL_PROCESSED=$((POOL_PROCESSED + 1))
            # No pool redraws the bar on this path, so the caller's cadence rule
            # decides when to render; the scan keeps its historical 50-file/1%
            # rule so its tty animation stays byte-identical.
            if [ "$POOL_MODE" -eq 0 ]; then
                show_progress "$POOL_PROCESSED" "$total_files" "$POOL_FAIL" "$label"
            elif [ -n "${POOL_SEQ_PROGRESS_FN:-}" ]; then
                "$POOL_SEQ_PROGRESS_FN" "$POOL_PROCESSED" "$total_files" "$POOL_FAIL" "$label"
            fi
            local seq_channel
            seq_channel="$(_pool_seq_channel "$id" "$result_channel" "$log_file")"
            if _pool_call_worker "$flac_file" "$seq_channel" "$log_file" "$library_dir" "$backup_root"; then
                POOL_SUCCESS=$((POOL_SUCCESS + 1))
            else
                POOL_FAIL=$((POOL_FAIL + 1))
            fi
            id=$((id + 1))
        done < "$list_path"
        return 0
    fi

    _pool_setup_state "$jobs" "$log_file" "$list_path"
    _pool_dispatch_loop "$list_path" "$jobs" "$log_file" "$result_channel" \
        "$library_dir" "$backup_root" "$label"
    _pool_drain "$label"

    # Tally the workers' result files BEFORE replaying per-file lines, or the
    # replay would appear ahead of the summary it accompanies.
    _pool_tally_results
    if [ "$POOL_MODE" -eq 2 ]; then
        _pool_replay_status_lines
    fi
    # Publish before releasing the per-run state: this is how many shards the run
    # created, and ids are allocated per FILE, not per worker slot.
    POOL_WORKERS_USED="$POOL_NEXT_ID"
    _pool_cleanup_state
    # The run is over, so restore the default signal behavior before returning to
    # the menu (a Ctrl-C there should end the script, not run the pool sweep).
    _pool_disarm_interrupt_trap
    return 0
}

# Counts the NUL-separated records in a file. $1 = file path.
_count_nul_list() {
    local count=0
    while IFS= read -r -d '' _rec <&4; do
        count=$((count + 1))
    done 4< "$1"
    printf '%s\n' "$count"
}

# Counts newline-terminated records in a file, without the off-by-one that
# '$(( $(wc -l) + 1 ))' causes when the last record lacks a trailing newline.
# Empty or absent files count as 0. $1 = file path.
_count_lines() {
    local count=0
    [ -s "$1" ] || { printf '0\n'; return 0; }
    while IFS= read -r _rec <&4; do
        count=$((count + 1))
    done 4< "$1"
    printf '%s\n' "$count"
}

# Creates the shard directory and the parent's in-flight bookkeeping for one
# pooled run: the dispatch index (file order, so the replay is deterministic) and
# the pid -> worker-id map. $1 = worker count, $2 = run log path, $3 = the run's
# NUL-separated work list (recorded so the interrupt handler can remove it).
_pool_setup_state() {
    # shellcheck disable=SC2034  # pool-wide state read by _pool_dispatch_loop
    # and _pool_sweep_finished below, like POOL_PIDS.
    POOL_JOBS="$1"
    POOL_LOG_FILE="$2"
    POOL_SHARD_DIR="$(shard_dir_for "$POOL_LOG_FILE")"
    POOL_INDEX="${POOL_SHARD_DIR}/$(basename "$POOL_LOG_FILE").index"
    # Run-local temp manifest the interrupt handler reads. It lives in the shard
    # dir, so it is namespaced by the run log like every other shard and cannot
    # collide with another run.
    POOL_TEMP_LIST="${POOL_SHARD_DIR}/$(basename "$POOL_LOG_FILE").temps"
    # Kept for the handler's sweep: a transient work list left behind by an
    # interrupted run is dead weight in the user's library.
    # shellcheck disable=SC2034  # read by _pool_interrupt_cleanup
    POOL_SEED_LIST="${3:-}"
    POOL_NEXT_ID=0
    POOL_PIDS=()
    mkdir -p "$POOL_SHARD_DIR"
    : > "$POOL_INDEX"
    : > "$POOL_TEMP_LIST"
    declare -gA POOL_WORKER_EXIT=()
    _pool_install_interrupt_trap
    return 0
}

# Arms the INT/TERM/HUP trap for the duration of a pooled run. Each trap passes its
# OWN signal number to the shared handler, so the reported signal - and the
# 128+signo exit status derived from it - is always correct. A single shared global
# would be overwritten by each `trap` registration and report whichever signal
# happened to be registered last (HUP/1), which is exactly the bug this avoids.
#
# Installed here rather than at script scope so the interactive menu (where Ctrl-C
# should simply end the script) is unaffected, and so the unit tests that SOURCE
# this file never inherit a handler.
_pool_install_interrupt_trap() {
    trap '_pool_interrupt_cleanup 2' INT
    trap '_pool_interrupt_cleanup 15' TERM
    trap '_pool_interrupt_cleanup 1' HUP
    return 0
}

# Restores the default INT/TERM/HUP behavior once the pooled run has completed.
# Idempotent, so calling it on a path where no trap was armed is harmless.
_pool_disarm_interrupt_trap() {
    trap - INT TERM HUP
    # shellcheck disable=SC2034  # latched for re-entrancy by the armed traps
    POOL_INTERRUPT_ARMED=0
    # shellcheck disable=SC2034  # read by _pool_interrupt_cleanup
    POOL_SEED_LIST=''
    return 0
}
# Resolves the result channel on the SEQUENTIAL (jobs=1) path. A reencode caller
# passes its real DB as $3 and keeps writing straight into it, which keeps a
# jobs=1 run shard-free. An operation whose channel is inherently per file (the
# scan's failure list) sets POOL_SEQ_CHANNEL_PREFIX instead, so every file gets
# its own shard named by id, matching the pooled path.
# $1 = worker id (== dispatch index), $2 = the caller's channel ($3 of the pool),
# $3 = run log path.
_pool_seq_channel() {
    local worker_id="$1"
    local caller_channel="$2"
    local log_file="$3"

    if [ -n "${POOL_SEQ_CHANNEL_PREFIX:-}" ]; then
        printf '%s/%s_w%s.%s\n' "$(dirname "$log_file")" \
            "$POOL_SEQ_CHANNEL_PREFIX" "$worker_id" "$POOL_CHANNEL_KIND"
        return 0
    fi
    printf '%s\n' "$caller_channel"
}

# Invokes the configured per-file worker: the one place that decides WHICH
# operation runs, so a new pooled operation only adds a worker and points
# POOL_WORKER_FN at it. $1 = file, $2 = result channel, $3 = log shard,
# $4 = library root, $5 = backup root.
_pool_call_worker() {
    "${POOL_WORKER_FN:-_reencode_pool_worker}" "$@"
}

# Per-file body of a reencode run. Returns the per-file status.
_reencode_pool_worker() {
    reencode_one_file "$1" "$2" "$3" "$4" "$5"
}

# Forks one worker for one file. A FAILED fork is counted as a file failure
# rather than aborting: one momentary resource shortage must not kill a
# multi-hour run. $1 = worker id, $2 = file, $3 = run log, $4 = library root,
# $5 = backup root.
_pool_start_worker() {
    local worker_id="$1"
    local flac_file="$2"
    local log_file="$3"
    local library_dir="$4"
    local backup_root="$5"
    local pid

    # Record the temp this file will use BEFORE forking, so the interrupt handler
    # can sweep it even if the signal lands while the worker is mid-write. The
    # name is the deterministic one reencode_one_file builds, and appending it to
    # the run's manifest (not a bare find -delete) keeps a running sibling's live
    # temp out of the sweep. A scan's worker writes no temp; an extra entry for it
    # would be harmless (the file never exists) but is skipped anyway, since its
    # channel kind is 'scan'.
    if [ "${POOL_CHANNEL_KIND:-db}" = 'db' ] && [ -n "$POOL_TEMP_LIST" ]; then
        printf '%s\n' "${flac_file%/*}/tmp_${flac_file##*/}.part" >> "$POOL_TEMP_LIST"
    fi

    (
        # Shards are LOCAL to the child and passed explicitly, so no shared
        # global decides where a worker writes. The channel kind picks the DB
        # shard (reencode) or the failure list (scan) via the same helper.
        local log_shard result_shard rc
        log_shard="$(shard_path_for "$log_file" "$worker_id" log)"
        result_shard="$(shard_path_for "$log_file" "$worker_id" result)"
        local result_channel
        result_channel="$(shard_path_for "$log_file" "$worker_id" "$POOL_CHANNEL_KIND")"
        # Statuses must never reach the screen while the parent owns the bar line.
        STATUS_TO_CONSOLE=0
        if _pool_call_worker "$flac_file" "$result_channel" "$log_shard" \
                "$library_dir" "$backup_root"; then
            rc=0
        else
            rc=1
        fi
        # Written by the worker so the count reflects what actually ran, and one
        # record per file so the parent's sum is an exact file count.
        printf 'PROCESSED=1\nFAIL=%s\n' "$rc" > "$result_shard"
        exit "$rc"
    ) &
    pid=$!
    # shellcheck disable=SC2034  # read by _pool_sweep_finished (same script scope)
    POOL_WORKER_EXIT["$pid"]="$worker_id"
    POOL_PIDS+=("$pid")
    return 0
}

# Drops every already-exited pid from the in-flight list and reports how many are
# still running (POOL_RUNNING). 'kill -0' is portable and, unlike 'wait -n',
# never consumes a status this function could not report.
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

# Feeds the list to the pool, keeping POOL_JOBS workers in flight. Every
# dispatched path is appended to the index (so a replay keeps file order), and
# completions are swept before each start so finished pids do not pile up.
# $1 = NUL-separated list, $2 = worker count, $3 = run log,
# $4 = result channel, $5 = library root, $6 = backup root, $7 = bar label.
_pool_dispatch_loop() {
    local list_path="$1"
    local jobs="$2"
    local log_file="$3"
    local result_channel="$4"
    local library_dir="$5"
    local backup_root="$6"
    local label="$7"
    local flac_file total_files

    total_files=$(_count_nul_list "$list_path")
    # Read by _pool_drain for its closing N/N render.
    # shellcheck disable=SC2034  # read by _pool_drain (same script scope)
    POOL_TOTAL_FILES="$total_files"

    exec 3< "$list_path"
    while IFS= read -r -d '' flac_file <&3; do
        printf '%s\n' "$flac_file" >> "$POOL_INDEX"

        # Backpressure: block on ANY worker finishing, then sweep, so a freed
        # slot is refilled immediately instead of after the whole batch.
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

        # Redrawn on EVERY dispatch, so the bar reflects real progress rather
        # than merely dispatched work. Guarded on a non-empty list because
        # show_progress divides by the total.
        if [ "$POOL_MODE" -eq 1 ] || [ "$POOL_MODE" -eq 0 ]; then
            [ "$total_files" -gt 0 ] && _pool_report_progress "$total_files" "$label"
        fi
    done
    exec 3<&-
    return 0
}

# Waits for the last in-flight workers, sweeping completions as they land. The
# non-blocking first sweep means an already-empty pool returns immediately.
# $1 = bar label.
_pool_drain() {
    local label="$1"
    while :; do
        _pool_sweep_finished
        [ "$POOL_RUNNING" -eq 0 ] && break
        wait -n "${POOL_PIDS[@]}" 2>/dev/null || true
    done
    # Final render: the last completions land during the drain and would
    # otherwise never be drawn, leaving the bar short of N/N.
    if [ "${POOL_TOTAL_FILES:-0}" -gt 0 ] \
            && { [ "$POOL_MODE" -eq 1 ] || [ "$POOL_MODE" -eq 0 ]; }; then
        _pool_report_progress "$POOL_TOTAL_FILES" "$label"
    fi
    return 0
}

# Renders one progress update from the COMPLETION tally (POOL_PROCESSED/
# POOL_FAIL), so a captured run's footer matches its replayed per-file lines.
# $1 = total file count, $2 = bar label.
_pool_report_progress() {
    local total="$1"
    local label="$2"
    show_progress "$POOL_PROCESSED" "$total" "$POOL_FAIL" "$label"
    return 0
}

# Reads the KEY=VALUE records every worker wrote into its own '<shard>.result'
# and updates POOL_PROCESSED/POOL_SUCCESS/POOL_FAIL. One record per file, written
# by the worker, so each outcome is counted exactly once; files are removed as
# they are read, making this idempotent.
_pool_tally_results() {
    local shard_path result_file key value

    # Ids are handed out per FILE, not per worker slot (8 files on 4 workers own
    # shards w0..w7), hence the high-water id rather than the job count.
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
    # Derived, never tracked separately: every file ends as a success or a
    # failure, which stays consistent even if a worker died before recording.
    POOL_SUCCESS=$((POOL_PROCESSED - POOL_FAIL))
    return 0
}

# On a captured (non-tty) pooled run, prints the per-file SUCCESS/FAILURE lines in
# FILE ORDER at the end: during the run they went only to the workers' log shards,
# so this gives a piped run the same feedback a sequential one has without
# interleaving worker output. Order comes from the dispatch index.
_pool_replay_status_lines() {
    local flac_file shard_path

    [ -s "$POOL_INDEX" ] || return 0

    while IFS= read -r flac_file; do
        for (( shard = 0; shard < POOL_NEXT_ID; shard++ )); do
            shard_path="$(shard_path_for "$POOL_LOG_FILE" "$shard" log)"
            [ -s "$shard_path" ] || continue
            # Each file is handled by exactly one worker, so grepping this
            # shard for its path pulls just its own line(s), WARNINGs included.
            grep -F -- "$flac_file" "$shard_path" 2>/dev/null || true
        done
    done < "$POOL_INDEX"
    return 0
}

# Releases the parent's per-run pool state (index, pid map, counters) so a later
# run in the same invocation cannot see stale entries, and removes the shard
# directory (idempotent; a no-op while another run's shards exist). POOL_NEXT_ID
# is deliberately left alone: on the sequential path it is still 0, which tells
# the caller there are no shards to merge.
_pool_cleanup_state() {
    rm -f "$POOL_INDEX" 2>/dev/null || true
    rm -f "$POOL_TEMP_LIST" 2>/dev/null || true
    POOL_PIDS=()
    POOL_RUNNING=0
    rmdir "$POOL_SHARD_DIR" 2>/dev/null || true
    return 0
}

# Signal handler for INT/TERM/HUP, installed only while a pooled run is in flight.
#
# WHY: a terminal Ctrl-C signals the whole foreground group, so the workers and
# their 'flac' children usually die on their own - but a `kill -TERM`, `systemctl
# stop` or `pkill` signals ONLY this shell, and then the forked workers keep
# running while the parent dies. They hold shards that will never be merged, hold
# temp files, and can rewrite audio after the user believes the run stopped. This
# handler closes that window.
#
# WHAT it does NOT do: flush the workers' shards into the run log or the tracking
# DB. A half-finished file may already have been replaced while its DB record is
# still only in a shard, or vice versa, and the normal merge is deliberately
# all-or-nothing (see run_file_pool). An interrupted parallel run can therefore
# leave reencoded files and backups with no DB row; option 5 will re-reencode
# those next time, which is safe because an existing backup is never overwritten.
#
# WHAT it does clean, all scoped to THIS run so a concurrent invocation is safe:
# every worker and its 'flac' child, the in-library .part temp of each dispatched
# file, this run's per-worker shards and dispatch index, its temp manifest and its
# seed work list. The partial run log is kept on purpose - it is the only record of
# what the interrupt cut short.
#
# A trap cannot take arguments, but the handler it invokes can: the trap commands
# installed by _pool_install_interrupt_trap pass their own signal number as $1.
_pool_interrupt_cleanup() {
    local signo="${1:-0}"
    # Disarm first: a second signal (or a TERM sent to a worker) must not re-enter.
    # shellcheck disable=SC2034  # latched for re-entrancy by the armed traps
    POOL_INTERRUPT_ARMED=1
    trap '' INT TERM HUP

    local p

    printf '\nInterrupted (signal %s): stopping workers...\n' "$signo" >&2

    # Kill each worker AND its 'flac' grandchild. Killing only the worker leaves a
    # running 'flac' writing to the temp; pkill -P covers the depth. Both calls
    # are best-effort: pkill may be absent (it is procps, not coreutils), and a
    # worker may have exited between the sweep and the kill.
    for p in "${POOL_PIDS[@]}"; do
        if command -v pkill >/dev/null 2>&1; then
            pkill -TERM -P "$p" 2>/dev/null || true
        fi
        kill -TERM "$p" 2>/dev/null || true
    done
    wait 2>/dev/null || true

    # Remove the temps this run dispatched. The manifest is written by the parent at
    # dispatch time, so it names exactly this run's temps - never a concurrent run's
    # live file (unlike a blanket find -delete over the library).
    if [ -n "${POOL_TEMP_LIST:-}" ] && [ -f "$POOL_TEMP_LIST" ]; then
        while IFS= read -r p; do
            if [ -n "$p" ]; then
                rm -f "$p" 2>/dev/null || true
            fi
        done < "$POOL_TEMP_LIST"
        rm -f "$POOL_TEMP_LIST" 2>/dev/null || true
    fi
    # Remove every OTHER artifact of this run. Shards are named
    # '<log basename>_w<N>.<ext>' and live beside the run log, so the run log's
    # basename is the namespace: a CONCURRENT run has its own log basename (it is
    # timestamped) and is therefore untouched, while this run's log/result/DB/scan
    # shards, its dispatch index and its temp manifest all go. The log itself is kept
    # as the audit trail of what happened before the interrupt.
    if [ -n "${POOL_LOG_FILE:-}" ]; then
        local log_base log_dir
        log_base="$(basename "$POOL_LOG_FILE")"
        log_dir="$(dirname "$POOL_LOG_FILE")"
        rm -f "${log_dir}/${log_base}"_w* \
              "${log_dir}/${log_base}".index \
              "${log_dir}/${log_base}".temps \
              2>/dev/null || true
    fi
    # The seed directory holds this run's NUL-separated work list, named from the
    # same log basename. It is transient, so a leftover serves no purpose.
    if [ -n "${POOL_SEED_LIST:-}" ]; then
        rm -f "$POOL_SEED_LIST" 2>/dev/null || true
    fi
    # A 'shards' sibling directory holds this run's shards when the run log lives
    # outside the library; remove it if this run created it. rm -rf (not rmdir) so a
    # killed worker's leftovers inside cannot strand it, and the name is derived from
    # the per-run log path so no other run shares it.
    if [ -n "${POOL_SHARD_DIR:-}" ] && [ -d "$POOL_SHARD_DIR" ]; then
        rm -rf "$POOL_SHARD_DIR" 2>/dev/null || true
    fi

    exit "$((128 + signo))"
}

# The sequential scan's ORIGINAL cadence (every 50 files, or on a whole-percent
# advance), preserved verbatim because the tty rendering is pinned by tests.
# SCAN_LAST_PERCENT is script-scope state the caller initialises.
# $1 = processed, $2 = total, $3 = errors, $4 = label (ignored: a scan bar has none)
_scan_seq_progress() {
    local processed="$1"
    local total="$2"
    local errors="$3"

    if (( processed % 50 == 0 || processed * 100 / total > SCAN_LAST_PERCENT )); then
        show_progress "$processed" "$total" "$errors"
        SCAN_LAST_PERCENT=$((processed * 100 / total))
    fi
    return 0
}

# Per-file body of a pooled scan: verify one file with 'flac -t'. A failing
# file's PATH (not status text) goes to this worker's own 'scan' shard in dispatch
# order, so the parent rebuilds the CSV in file order; one writer per file, so no
# locking is needed. $1 = file, $2 = scan shard, $3 = log shard (unused),
# $4/$5 = library/backup root (unused, kept for signature symmetry).
_scan_pool_worker() {
    local flac_file="$1"
    local scan_shard="$2"

    if flac -t "$flac_file" &>/dev/null; then
        return 0
    fi
    # The ONLY record the worker makes: the machine-readable path list the parent
    # replays. It deliberately skips the log shard, which the pooled path
    # replays verbatim and write_status would echo on the sequential path, so a
    # line there would print a second/third copy of what the parent already emits
    # in file order.
    printf '%s\n' "$flac_file" >> "$scan_shard"
    return 1
}

# Verifies a NUL-separated list with 'flac -t', up to 'jobs' at a time, reusing
# run_file_pool with the scan worker plugged into its seam.
# Output contract (the same either way): failing paths are reported after the run
# in FILE ORDER, and POOL_PROCESSED/POOL_ERRORS are left for the caller's summary.
# A file whose worker could not even be forked is reported separately
# (POOL_UNTESTED) rather than counted as clean or corrupt.
# $1 = worker count, $2 = NUL-separated list, $3 = run log (names the shard dir),
# $4 = library root.
# Sets POOL_PROCESSED, POOL_ERRORS, POOL_UNTESTED, SCAN_FAILED_PATHS,
# SCAN_FAILURES_FILE (the caller owns and removes that temp file).
run_scan_pool() {
    local jobs="$1"
    local list_path="$2"
    local log_file="$3"
    local library_dir="${4%/}"
    local mode

    # A scan has no per-file status text of its own to hide: this function prints
    # its errors from the shards, in order. Mode 1 = sequential (progress via the
    # hook below), mode 2 = pooled with worker output replayed afterwards. The
    # bar itself is owned by scan_library.
    mode=2
    if [ "$jobs" -le 1 ]; then
        mode=1
    fi

    POOL_WORKER_FN="_scan_pool_worker"
    POOL_CHANNEL_KIND="scan"
    # A PER-FILE failure list, so even the sequential path needs one shard per
    # file (named from the run-log basename, like the pooled path).
    POOL_SEQ_CHANNEL_PREFIX="$(basename "$log_file")"
    # Only the sequential path uses this hook; the pooled path redraws per dispatch.
    POOL_SEQ_PROGRESS_FN="_scan_seq_progress"
    # Collected into a temp file, not a variable, because a path may contain any
    # byte but NUL and a newline-containing path would look like two entries.
    SCAN_FAILURES_FILE="$(mktemp "${TMPDIR:-/tmp}/flac_scan_fail.XXXXXX")"
    run_file_pool "$jobs" "$log_file" "" "$library_dir" "" \
        "$list_path" "$mode" "Errors"

    # Collect the failure lists: ids match dispatch order, so replaying them in
    # ascending order reproduces sequential report order. run_file_pool stops at
    # POOL_WORKERS_USED on the pooled path and at the processed count on the
    # sequential one (POOL_WORKERS_USED is 0 there), so unify the two bounds.
    local bound="$POOL_WORKERS_USED"
    [ "$bound" -gt 0 ] || bound="$POOL_PROCESSED"

    SCAN_FAILED_PATHS=""
    local id shard
    for (( id = 0; id < bound; id++ )); do
        shard="$(shard_path_for "$log_file" "$id" scan)"
        if [ -s "$shard" ]; then
            cat "$shard"
            rm -f "$shard"
        fi
    done > "$SCAN_FAILURES_FILE"

    POOL_ERRORS=0
    if [ -s "$SCAN_FAILURES_FILE" ]; then
        POOL_ERRORS=$(_count_lines "$SCAN_FAILURES_FILE")
    fi
    # A failed fork is a pool failure with no path behind it; surface it so the
    # summary never implies those files were verified.
    POOL_UNTESTED=$((POOL_FAIL - POOL_ERRORS))
    [ "$POOL_UNTESTED" -lt 0 ] && POOL_UNTESTED=0

    # Report the errors in file order. The caller has already cleared its bar.
    if [ "$POOL_ERRORS" -gt 0 ]; then
        local err_path
        while IFS= read -r err_path; do
            SCAN_FAILED_PATHS+="${err_path}"$'\n'
            if stdout_is_tty; then
                printf '%b%s\n' "${RED}Error detected in:${NC} " "$err_path"
            else
                echo "Error detected in: $err_path"
            fi
        done < "$SCAN_FAILURES_FILE"
    fi
    return 0
}

# Prompts for a library directory, then scans it recursively with 'flac -t',
# skipping the script's own internal paths (FLAC_INTERNAL_PATH_GLOBS). Failing
# files are recorded, quoted, in a CSV under the library's .flac_scan_data.
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

    # Same timestamp for both, so a run's CSV and summary log pair up. The CSV is
    # the machine-readable manifest for option 2 and exists only when errors do;
    # the summary log is written on EVERY scan so each run leaves an audit record.
    timestamp=$(date +%F_%H-%M-%S)
    csv_output="${scan_data_dir}/reports/flac_scan_${timestamp}.csv"
    scan_log="${scan_data_dir}/logs/scan_log_${timestamp}.txt"

    echo "Scanning FLAC files in: $library_dir"
    echo "Counting FLAC files..."

    # Materialise the list ONCE, NUL-separated, for both the count and the pool:
    # walking the tree twice (count, then scan) doubled the metadata cost and let
    # the two walks disagree, so the progress denominator could differ from the
    # number of files actually tested.
    scan_list_file="$(mktemp "${TMPDIR:-/tmp}/flac_scan_list.XXXXXX")"
    find_real_flac_files "$library_dir" -print0 > "$scan_list_file"
    total_files=$(_count_nul_list "$scan_list_file")
    echo "Found $total_files FLAC files to scan"

    error_count=0
    start_time=$(date +%s)
    # Whole-percent high-water mark for the sequential progress cadence
    # (see _scan_seq_progress), kept in script scope across the run.
    SCAN_LAST_PERCENT=0

    # jobs=1 keeps the historical strictly-sequential behavior, and its output is
    # byte-identical to it: same progress cadence, same interleaved error lines.
    # jobs>1 runs the pool, whose worker ids match dispatch order, so the errors
    # it reports afterwards come out in exactly this same file order.
    jobs="$(get_jobs)"
    if [ "$jobs" -gt 1 ]; then
        echo ""
        echo "Scanning with $jobs worker(s)..."
        echo ""
    fi
    run_scan_pool "$jobs" "$scan_list_file" "$scan_log" "$library_dir"
    processed_count="$POOL_PROCESSED"

    # Clear progress line
    clear_progress

    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Build the CSV from the pool's failure list with the same order and quoting
    # the sequential loop used, so option 2 consumes either run identically. Only
    # written when failures exist, so a clean scan leaves no manifest behind.
    if [ "$POOL_ERRORS" -gt 0 ]; then
        {
            echo "# Scan Report: $(date -u +%FT%TZ) | Files: $total_files | Errors: "
            echo "filepath"
            while IFS= read -r flac_file; do
                [ -n "$flac_file" ] || continue
                echo "\"${flac_file}\""
            done < "$SCAN_FAILURES_FILE"
        } > "$csv_output"
        error_count="$POOL_ERRORS"
    fi

    rm -f "$scan_list_file" "$SCAN_FAILURES_FILE"

    # The CSV only exists when errors were found; remove the never-populated
    # placeholder so option 2 never sees an empty manifest.
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

    # Every scan, clean or not, leaves a human-readable audit trail alongside the
    # reports/logs the reencode flows use.
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

# Reads the newest scan CSV from the library, confirms with the user, then
# re-encodes each file it lists. Skips the report metadata row and header, and
# any path in the script's own internal area (older/exported CSVs may contain
# them).
# The backup root is resolved once (resolve_backup_path) and each file is
# mirrored into it, originals never living inside the library.
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

    # Resolve, then create/validate, the backup root before touching any file: a
    # failure here (unsafe location, unwritable export) aborts rather than
    # re-encoding anything unprotected. The split exists only so callers that
    # merely DISPLAY a path create nothing; here the user already confirmed.
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

    # Worker count for this run (see get_jobs and the header's pool notes).
    jobs="$(get_jobs)"

    # Run log for the reencoding process.
    log_file="${scan_data_dir}/logs/reencode_log_$(date +%F_%H-%M-%S).txt"
    {
        echo "Reencoding started at $(date)"
        echo "Library: $library_dir"
        echo "Backups: $backup_root"
        echo "CSV: $latest_csv"
        echo "Workers: $jobs"
        echo ""
    } > "$log_file"

    # Discovery pass: build the filtered, DEDUPLICATED work list, keeping the
    # CSV's own order. A hand-edited or merged report can repeat a path, and two
    # workers must never race the same file, so duplicates are reported and dropped.
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

        # Skip the header row and scan_library's leading '# Scan Report: ...' row.
        if [[ "$flac_file" == "filepath" ]] || [[ "$flac_file" == \#* ]]; then
            continue
        fi

        # Never re-encode rows pointing into the script's internal area.
        if is_internal_flac_path "$flac_file"; then
            printf '%s\n' "Skipping internal/backup path: $flac_file" >> "$filter_log"
            continue
        fi

        # A path outside the library has no home in the mirrored backup tree, so
        # skip it loudly rather than re-encoding it unprotected.
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

    # Per-file status text and a single-line animated bar cannot share a live
    # terminal, so reporting depends on the destination and the worker count:
    #   mode 1 - jobs=1: historical behavior, statuses echoed as each file is done.
    #   mode 0 - pooled on a terminal: statuses stay in the shards, merged into the
    #            run log later, so nothing glues onto the animated bar.
    #   mode 2 - pooled on a pipe/redirect: no bar to protect, so per-file lines
    #            are replayed in FILE ORDER once the pool drains.
    local pool_mode
    if [ "$jobs" -le 1 ]; then
        pool_mode=1
    elif stdout_is_tty; then
        pool_mode=0
    else
        pool_mode=2
    fi

    # The work list is fully materialised before the pool starts, so a worker's
    # temp file can never be picked up mid-run.
    echo ""
    echo "Processing $total_files file(s) with $jobs worker(s)..."
    echo ""
    run_file_pool "$jobs" "$log_file" "$db_path" "$library_dir" "$backup_root" \
        "$seed_list" "$pool_mode" "Failed"
    success_count=$POOL_SUCCESS
    fail_count=$POOL_FAIL

    # Fold each worker's log and DB shards into the run log and the real DB, then
    # discard the work list.
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

# Re-encodes EVERY real FLAC file in the library, after a prominent warning and
# an explicit confirmation. Each original is mirrored into the backup directory
# first. Internal paths are excluded from both the count and the processed set.
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

    # find_real_flac_files skips the internal paths, consistent with
    # reencode_new_files.
    echo "Counting FLAC files..."
    total_files=$(find_real_flac_files "$library_dir" | wc -l)
    
    if [ "$total_files" -eq 0 ]; then
        echo "No FLAC files found in '$library_dir'."
        read -rp "Press Enter to return to main menu..."
        return
    fi

    # Resolve only, so the warning can name the concrete destination and a
    # cancelled warning leaves no stray directory; the mkdir happens after the
    # confirmation. '--no-prompt' because a question here would come before the
    # warning that justifies it, and would swallow the 'REENCODE ALL' answer.
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

    # The user has committed: create and write-probe the destination, still before
    # any file is touched, so an unwritable export aborts before audio is rewritten.
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

    # Render mode: on a terminal keep one fixed single-line bar and hold status
    # text off the screen (STATUS_TO_CONSOLE=0); on a pipe print every
    # SUCCESS/FAILURE line as text. Either way the log gets every status. stdout's
    # tty state is resolved once here, not in the loop.
    local live_tty
    if stdout_is_tty; then live_tty=1; else live_tty=0; fi

    # Materialise the work list FIRST: find_real_flac_files excludes the script's
    # own paths, but not a temp file written into a library directory during the
    # run, and a live "find | pool" pipe could hand such a temp to a worker.
    seed_dir="${scan_data_dir}/seed"
    seed_list="${seed_dir}/$(basename "$log_file").paths"
    mkdir -p "$seed_dir"
    find_real_flac_files "$library_dir" -print0 > "$seed_list"

    if [ "$jobs" -le 1 ]; then
        pool_mode=1
    else
        # A single-line bar and per-file status text cannot share a terminal, so
        # pooled tty runs keep statuses in the log (mode 0) and rely on the bar,
        # while pooled captured runs replay them in file order (mode 2).
        if [ "$live_tty" = "1" ]; then pool_mode=0; else pool_mode=2; fi
    fi
    if [ "$pool_mode" -eq 1 ]; then
        STATUS_TO_CONSOLE=$(( 1 - live_tty ))
    fi

    echo "Processing $total_files file(s) with $jobs worker(s)..."
    run_file_pool "$jobs" "$log_file" "$db_path" "$library_dir" "$backup_root" \
        "$seed_list" "$pool_mode" "Failed"
    processed_count=$POOL_PROCESSED
    success_count=$POOL_SUCCESS
    fail_count=$POOL_FAIL

    # Fold each worker's log + DB shards into the run log and the real tracking
    # DB, then discard the work list.
    merge_reencode_shards "$log_file" "$db_path" "$POOL_WORKERS_USED"
    rm -f "$seed_list"
    rmdir "$seed_dir" 2>/dev/null || true

    # Clear the progress line and restore console status output.
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
# Re-encodes only the files absent from the tracking DB, so newly added or
# re-downloaded albums (detected by MD5+size) are processed and everything else
# is skipped. Each original is mirrored into the backup directory first.
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

    # The backup directory is deliberately NOT resolved here: resolve_backup_path
    # may PROMPT, which would interrupt the flow and swallow a line of stdin meant
    # for the confirmation below. It runs after the confirmation instead, still
    # before any file is touched.

    # Create scan data directory and determine tracking DB path.
    scan_data_dir="${library_dir}/.flac_scan_data"
    mkdir -p "${scan_data_dir}/logs"

    db_path=$(get_reencoded_db_path "$library_dir")
    # Must be a plain command, not $(), so the global REENCODED_SET is populated
    # in THIS shell rather than a discarded subshell.
    load_reencoded_set "$db_path"
    db_entries=${#REENCODED_SET[@]}

    # Worker count for this run (see get_jobs and the header's pool notes).
    jobs="$(get_jobs)"

    # find_real_flac_files skips the internal paths, keeping incremental reencodes
    # accurate.
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
        # Guard on the exit status, not on a non-empty string: an unreadable or
        # corrupt fingerprint makes get_file_fingerprint return 1, and the file is
        # then treated as new below.
        if fp=$(get_file_fingerprint "$flac_file"); then
            read -r md5 size mtime _rest <<< "$fp"
            key="${md5}|${size}"
            if [[ -n "${REENCODED_SET[$key]+x}" ]]; then
                skipped_count=$((skipped_count + 1))
                continue
            fi
        fi
        # No fingerprint, or an unknown MD5+size: treat as new.
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

    # Like reencode_all_files: resolve, then create/validate, now that the user
    # committed. Still before any file is touched, so an unsafe or unwritable
    # destination aborts rather than after audio has been rewritten.
    backup_root=""
    if ! backup_root=$(resolve_backup_path "$library_dir"); then
        read -rp "Press Enter to return to main menu..."
        return
    fi
    echo "Backups will be written to: $backup_root"

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

    # The list was classified in the discovery pass above, so a temp file a worker
    # creates can never be picked up as "new" mid-run. Serialise it NUL-separated.
    seed_dir="${scan_data_dir}/seed"
    seed_list="${seed_dir}/$(basename "$log_file").paths"
    mkdir -p "$seed_dir"
    : > "$seed_list"
    for flac_file in "${new_files[@]}"; do
        printf '%s\0' "$flac_file" >> "$seed_list"
    done

    # Render mode as in reencode_all_files(): one animated bar on a terminal
    # (statuses stay in the log), replayed status lines in file order otherwise.
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
    run_file_pool "$jobs" "$log_file" "$db_path" "$library_dir" "$backup_root" \
        "$seed_list" "$pool_mode" "Failed"
    processed_count=$POOL_PROCESSED
    success_count=$POOL_SUCCESS
    fail_count=$POOL_FAIL

    # Fold each worker's log + DB shards into the run log and the real tracking
    # DB, then discard the work list.
    merge_reencode_shards "$log_file" "$db_path" "$POOL_WORKERS_USED"
    rm -f "$seed_list"
    rmdir "$seed_dir" 2>/dev/null || true

    # Clear the progress line and restore console status output.
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

# Sets or updates the library path and the backup directory. A blank answer keeps
# the current value, so the two can be edited independently (save_config leaves
# an omitted key alone). The backup candidate is validated here, at the keyboard,
# rather than at the start of a long re-encode run.
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
        # Blank keeps the current value; when nothing was configured either, offer
        # the derived sibling that would actually be used.
        if [ -z "$current_backup" ] && [ -n "$new_path" ] && [ "$new_path" != "null" ]; then
            new_backup="$(derive_backup_path "${new_path%/}")"
            echo "Using derived backup directory: $new_backup"
        else
            new_backup="$current_backup"
        fi
    fi
    new_backup="$(printf '%s' "$new_backup" | sed 's:/$::')"

    # Blank (or 0) clears the key so get_jobs() re-derives it. A non-numeric
    # answer is refused rather than written: a junk value in the config would be
    # silently ignored at run time and the user would never learn that.
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

    # The library may be entered for the first time here, so check it exists to
    # give the user an actionable error message.
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
    while true; do
        main_menu
    done
fi
