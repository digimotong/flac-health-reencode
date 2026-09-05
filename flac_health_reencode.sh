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
#   - Configurable library paths (stored in JSON)
#   - Automatic backup of original files before re-encoding
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
#      - Manage library path
#      - Clean up backups
#
#   Note: an invalid or empty menu entry re-prompts; type 'q' or '7' to quit.
# Reencoded-file Tracking:
#   After a successful reencode a file is recorded in
#   '<library>/.flac_scan_data/reencoded.db' using its FLAC audio MD5 (from
#   metaflac --show-md5sum), file size and mtime. The 'Reencode NEW FLAC files
#   only' option skips files whose MD5+size are already recorded, so newly added
#   (or freshly downloaded, previously deleted) albums are reliably detected.
#
# Important Notes:
#   - Backups are stored in 'backup_FLAC_originals' subdirectories
#   - Scan reports are saved in '.flac_scan_data/reports'
#   - Operation logs are saved in '.flac_scan_data/logs'
#   - Reencoded-file DB is saved as '.flac_scan_data/reencoded.db'
#   - Uses FLAC's --decode-through-errors for maximum recovery
#   - All real-FLAC operations (scan, reencode-from-CSV, reencode ALL/NEW) skip
#     the script's own 'backup_FLAC_originals' copies and '.flac_scan_data'
#     directory so backup/internal copies are never scanned or re-encoded.
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
# Loads configuration from file or creates default
########################################
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        jq -n '{library_path: "", version: "1.0"}' > "$CONFIG_FILE"
    fi
    config=$(cat "$CONFIG_FILE")
    echo "$config"
}

########################################
# FUNCTION: save_config
# Saves configuration to file
# Arguments:
#   $1 - New library path
########################################
save_config() {
    local new_path="$1"
    config=$(jq --arg path "$new_path" '.library_path = $path' "$CONFIG_FILE")
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
# as real library content: pre-reencode backup copies (backup_FLAC_originals/)
# and the internal scan/tracking directory (.flac_scan_data/). Defined once here
# so callers can build consistent find predicates or path tests.
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
# the option 5/6 single-line-bar mode on a live terminal STATUS_TO_CONSOLE is
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
# FUNCTION: reencode_one_file
# Core single-file reencode logic shared by every reencode path.
# Backs up the original to backup_FLAC_originals, runs flac with
# --verify --compression-level-0 --decode-through-errors --preserve-modtime,
# then replaces the original with the reencoded temp file on success.
# SUCCESS/FAILURE/WARNING lines are always appended to the run log and echoed to
# the terminal depending on STATUS_TO_CONSOLE (see write_status); the quieter
# "Backup created for:" line goes to the log file only.
# Arguments:
#   $1 - Absolute path to the FLAC file
#   $2 - Tracking database path (for mark_as_reencoded)
#   $3 - Log file path
# Returns 0 on success, 1 on failure.
########################################
reencode_one_file() {
    local flac_file="$1"
    local db_path="$2"
    local log_file="$3"

    local file_dir base temp_file backup_folder backup_target

    # Determine the file's directory and file name.
    file_dir=$(dirname "$flac_file")
    base=$(basename "$flac_file")
    temp_file="${file_dir}/tmp_${base}"

    # Reencode the file using the specified FLAC parameters.
    if ! flac --verify --compression-level-0 --decode-through-errors --preserve-modtime --silent -o "$temp_file" "$flac_file"; then
        write_status "FAILURE: Reencoding failed for $flac_file" "$log_file"
        [ -f "$temp_file" ] && rm "$temp_file"
        return 1
    fi

    # Create a backup folder in the same directory as the file.
    backup_folder="${file_dir}/backup_FLAC_originals"
    mkdir -p "$backup_folder"
    backup_target="${backup_folder}/${base}"

    if ! cp "$flac_file" "$backup_target"; then
        write_status "WARNING: Failed to backup $flac_file. Skipping reencode for this file." "$log_file"
        rm -f "$temp_file"
        return 1
    fi
    echo "Backup created for: $flac_file -> $backup_target" >> "$log_file"

    # Replace the original file with the reencoded version.
    if ! mv "$temp_file" "$flac_file"; then
        write_status "FAILURE: Could not overwrite $flac_file with the reencoded file." "$log_file"
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
# files using 'flac -t'. The script's own backup_FLAC_originals copies and the
# .flac_scan_data/ tracking dir are excluded. Any file that fails the test is
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
        exit 1
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
            printf "${RED}Error detected in:${NC} %s\n" "$flac_file"
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
    if [ $error_count -gt 0 ]; then
        sed -i "s/| Errors: /| Errors: $error_count/" "$csv_output"
        printf "${GREEN}Scan complete.${NC}\n"
        printf "Scanned ${YELLOW}%d${NC} files in ${YELLOW}%d${NC} seconds\n" "$processed_count" "$duration"
        printf "Found ${RED}%d${NC} errors\n" "$error_count"
        printf "CSV report generated: ${YELLOW}%s${NC}\n" "$csv_output"
        report_line="$csv_output"
    else
        rm -f "$csv_output"
        printf "${GREEN}Scan complete.${NC}\n"
        printf "Scanned ${YELLOW}%d${NC} files in ${YELLOW}%d${NC} seconds\n" "$processed_count" "$duration"
        printf "${GREEN}No errors found.${NC}\n"
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
#   For each file, a backup folder is created within its directory (if not already present)
#   and the original file is backed up there before it is replaced by the reencoded version.
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
        exit 1
    fi

    # Locate the latest CSV file in reports directory (by modification time).
    scan_data_dir="${library_dir}/.flac_scan_data/reports"
    latest_csv=$(find "$scan_data_dir" -type f -iname "flac_scan_*.csv" -printf "%T@ %p\n" \
                 | sort -n \
                 | tail -1 \
                 | cut -d' ' -f2-)

    if [ -z "$latest_csv" ]; then
        echo "No CSV file found in '$library_dir'. Please run a scan first."
        exit 1
    fi

    echo "Latest scan CSV file found: $latest_csv"
    read -rp "Type 'Y' to confirm using this CSV file for reencoding: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "User did not confirm. Aborting reencoding process."
        exit 1
    fi

    # Create scan data directory if needed
    scan_data_dir="${library_dir}/.flac_scan_data"
    mkdir -p "${scan_data_dir}/logs"

    # Tracking database for successfully reencoded files.
    db_path=$(get_reencoded_db_path "$library_dir")

    # Generate a log file for the reencoding process.
    log_file="${scan_data_dir}/logs/reencode_log_$(date +%F_%H-%M-%S).txt"
    echo "Reencoding started at $(date)" > "$log_file"

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

        total_files=$((total_files + 1))
        echo "Processing file: $flac_file"

        if reencode_one_file "$flac_file" "$db_path" "$log_file"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done < "$latest_csv"

    echo "Reencoding complete at $(date)" | tee -a "$log_file"
    echo "Total files processed: $total_files" | tee -a "$log_file"
    echo "Successful reencodes: $success_count" | tee -a "$log_file"
    echo "Failed reencodes: $fail_count" | tee -a "$log_file"
    echo "Detailed log saved as: $log_file"
    read -rp "Press Enter to return to main menu..."
}

########################################
# FUNCTION: reencode_all_files
# Reencodes EVERY "real" FLAC file in the library (not just problematic ones).
# Shows a prominent warning and requires explicit confirmation before proceeding.
# Each original file is backed up to a backup_FLAC_originals folder.
# The script's own backup_FLAC_originals copies and the .flac_scan_data tracking
# dir are excluded (both the count and the processed set) so backups are never
# re-encoded into nested backups themselves.
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
        exit 1
    fi

    # Count real FLAC files (find_real_flac_files skips the script's own backup
    # copies and the .flac_scan_data tracking dir, consistent with reencode_new_files).
    echo "Counting FLAC files..."
    total_files=$(find_real_flac_files "$library_dir" | wc -l)
    
    if [ "$total_files" -eq 0 ]; then
        echo "No FLAC files found in '$library_dir'."
        read -rp "Press Enter to return to main menu..."
        return
    fi

    # Prominent warning
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!                              WARNING                                   !!"
    echo "!!                                                                        !!"
    echo "!!  You are about to reencode ALL $total_files FLAC files in:          !!"
    echo "!!  $library_dir"
    echo "!!                                                                        !!"
    echo "!!  This will:                                                            !!"
    echo "!!    - Reencode every FLAC file (not just corrupted ones)                !!"
    echo "!!    - Create backups in 'backup_FLAC_originals' folders                 !!"
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

    # Create scan data directory and log file
    scan_data_dir="${library_dir}/.flac_scan_data"
    mkdir -p "${scan_data_dir}/logs"

    # Tracking database for successfully reencoded files.
    db_path=$(get_reencoded_db_path "$library_dir")

    log_file="${scan_data_dir}/logs/reencode_all_log_$(date +%F_%H-%M-%S).txt"
    echo "Full library reencode started at $(date)" > "$log_file"
    echo "Library: $library_dir" >> "$log_file"
    echo "Total files to process: $total_files" >> "$log_file"
    echo "" >> "$log_file"

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

        if reencode_one_file "$flac_file" "$db_path" "$log_file"; then
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
        exit 1
    fi

    # Create scan data directory and determine tracking DB path.
    scan_data_dir="${library_dir}/.flac_scan_data"
    mkdir -p "${scan_data_dir}/logs"

    db_path=$(get_reencoded_db_path "$library_dir")
    # NOTE: must be called as a plain command (not $() substitution) so the
    # global REENCODED_SET is populated in THIS shell, not a discarded subshell.
    load_reencoded_set "$db_path"
    db_entries=${#REENCODED_SET[@]}

    # Count real FLAC files (find_real_flac_files skips the script's own backup
    # copies and the .flac_scan_data tracking dir so incremental reencodes stay accurate).
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
        printf "${GREEN}All %d FLAC files have already been reencoded.${NC}\n" "$total_files"
        echo "Nothing to do. If you added new music, run this option again after adding files."
        read -rp "Press Enter to return to main menu..."
        return
    fi

    # Preview + confirmation (destructive-op style, consistent with the script).
    echo ""
    echo "Found ${YELLOW}${new_count}${NC} new FLAC file(s) out of $total_files total that have never been reencoded."
    echo "Each will be reencoded with --verify and backed up to 'backup_FLAC_originals' before replacing."
    read -rp "Reencode these ${new_count} file(s)? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Reencode cancelled."
        read -rp "Press Enter to return to main menu..."
        return
    fi

    # Create log file.
    log_file="${scan_data_dir}/logs/reencode_new_log_$(date +%F_%H-%M-%S).txt"
    echo "New-file reencode started at $(date)" > "$log_file"
    echo "Library: $library_dir" >> "$log_file"
    echo "Total FLAC files found: $total_files" >> "$log_file"
    echo "Already reencoded (skipped): $skipped_count" >> "$log_file"
    echo "New files to process: $new_count" >> "$log_file"
    echo "" >> "$log_file"

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

        if reencode_one_file "$flac_file" "$db_path" "$log_file"; then
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
    echo "Duration: ${duration} seconds" | tee -a "$log_file"
    echo "Detailed log saved as: $log_file"
    read -rp "Press Enter to return to main menu..."
}

########################################
# FUNCTION: cleanup_backups
# Finds and removes all backup_FLAC_originals folders
########################################
cleanup_backups() {
    config=$(load_config)
    library_path=$(echo "$config" | jq -r '.library_path')
    
    if [ -z "$library_path" ] || [ "$library_path" == "null" ]; then
        read -rp "Enter the library path to clean backups from: " library_path
    fi

    if [ ! -d "$library_path" ]; then
        echo "Error: Directory '$library_path' does not exist."
        return 1
    fi

    # Find all backup folders
    backup_folders=()
    while IFS= read -r -d '' folder; do
        backup_folders+=("$folder")
    done < <(find "$library_path" -type d -name "backup_FLAC_originals" -print0)

    if [ ${#backup_folders[@]} -eq 0 ]; then
        echo "No backup folders found in '$library_path'"
        return 0
    fi

    # Calculate total size and count
    total_size=0
    total_files=0
    for folder in "${backup_folders[@]}"; do
        size=$(du -sb "$folder" | cut -f1)
        files=$(find "$folder" -type f | wc -l)
        total_size=$((total_size + size))
        total_files=$((total_files + files))
    done

    # Human readable size
    hr_size=$(numfmt --to=iec --suffix=B $total_size)

    echo "Found ${#backup_folders[@]} backup folders containing $total_files files (total $hr_size)"
    echo "WARNING: This will PERMANENTLY delete all FLAC backups"
    read -rp "Type 'DELETE' to confirm: " confirm
    if [ "$confirm" != "DELETE" ]; then
        echo "Backup cleanup cancelled."
        return 0
    fi

    # Actually delete
    deleted_count=0
    deleted_size=0
    for folder in "${backup_folders[@]}"; do
        echo "Deleting: $folder"
        rm -rf "$folder"
        deleted_count=$((deleted_count + 1))
        size=$(du -sb "$folder" 2>/dev/null | cut -f1 || echo 0)
        deleted_size=$((deleted_size + size))
    done

    hr_deleted_size=$(numfmt --to=iec --suffix=B $deleted_size)
    echo "Deleted $deleted_count backup folders ($hr_deleted_size)"
    read -rp "Press Enter to return to main menu..."
}

########################################
# FUNCTION: set_library_path
# Allows user to set or update the default library path
########################################
set_library_path() {
    config=$(load_config)
    current_path=$(echo "$config" | jq -r '.library_path')
    
    if [ -z "$current_path" ] || [ "$current_path" == "null" ]; then
        echo "No library path is currently configured."
    else
        echo "Current library path: $current_path"
    fi
    
    read -rp "Enter new library path (leave blank to keep current): " new_path
    if [ -n "$new_path" ]; then
        save_config "$new_path"
        echo "Library path updated to: $new_path"
    else
        echo "Library path remains unchanged."
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

    # Show the currently-configured library so the user knows what a bulk
    # operation (options 1/2/5/6) would act on. Colors are only used on a live
    # terminal so captured/redirected output stays plain.
    local config library_path
    config=$(load_config)
    library_path=$(echo "$config" | jq -r '.library_path')
    if [ -z "$library_path" ] || [ "$library_path" == "null" ]; then
        if stdout_is_tty; then
            printf "   ${YELLOW}Library: (not set - use option 3)${NC}\n"
        else
            echo "   Library: (not set - use option 3)"
        fi
    else
        if stdout_is_tty; then
            printf "   ${GREEN}Library: %s${NC}\n" "$library_path"
        else
            echo "   Library: $library_path"
        fi
    fi
    echo "$menu_bar"

    echo " 1) Scan music library for errors"
    echo " 2) Reencode problematic FLAC files (from latest scan)"
    echo " 3) Set/Update default library path"
    echo " 4) Clean up FLAC backups"
    echo " 5) Reencode ALL FLAC files (with backups & warning)"
    echo " 6) Reencode NEW FLAC files only"
    echo " 7) Quit"
    echo "$menu_bar"
    read -rp "Enter your selection (1-7, or q to quit): " selection

    case "$selection" in
        1) scan_library ;;
        2) reencode_library ;;
        3) set_library_path ;;
        4) cleanup_backups ;;
        5) reencode_all_files ;;
        6) reencode_new_files ;;
        7 | q | Q) echo "Exiting..."; exit 0 ;;
        *) echo "Invalid selection. Please choose a number from 1-7 (or q to quit)." ;;
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
