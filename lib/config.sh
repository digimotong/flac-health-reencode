# shellcheck shell=bash
# lib/config.sh - the config file, the worker count, and which library files are
# "real" content. Sourced by flac_health_reencode.sh; the internal-path globs
# (FLAC_INTERNAL_PATH_GLOBS) are a readonly in the entry, next to CONFIG_FILE.

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
# filter non-find inputs, e.g. rows from an older scan report.
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
