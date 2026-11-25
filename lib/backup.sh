# shellcheck shell=bash
# lib/backup.sh - backup roots and the tracking DB: fingerprinting, the NUL record
# format shared by the DB and the shards, the backup mirroring rules, and the
# in-library temp-path policy. Sourced by flac_health_reencode.sh; REENCODED_SET is
# declared in the entry.

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

# Recording format, shared by the tracking DB and every reencode shard: ONE record
# per reencoded file, NUL-TERMINATED, "<md5> <size> <mtime> <path>\0".
#
# NUL, not a newline: the path is a filesystem name, so a filename containing a
# newline would otherwise split into two rows, and the second one (a fragment that is
# not under the library) would carry no usable fingerprint for option 5. With a NUL
# record the path is opaque data, exactly like the work lists. The three numeric
# fields come first because they never contain a space, so the path is everything
# after the third one.
#
# Migration: DBs written by older versions are newline-delimited
# ("<md5> <size> <mtime> <path>\n"). load_reencoded_set and migrate_reencoded_db both
# still READ that form - a legacy DB is never dropped or refused - and the next
# reencode run rewrites it into the NUL form (see migrate_reencoded_db).

# 0 when the file holds at least one NUL byte, i.e. it is in the NUL record form.
db_is_nul_format() {
    [ -f "$1" ] || return 1
    [ "$(tr -d -c '\000' < "$1" | wc -c)" -gt 0 ]
}

# Loads the tracking DB into REENCODED_SET, keyed "<md5>|<size>"; blank and
# comment lines are skipped. Sets the array in the CURRENT shell, so call it as
# a plain command, never inside $().
# Reads both on-disk forms (see the recording format above), so an upgraded install
# keeps its history and option 5 keeps skipping the files it already processed.
load_reencoded_set() {
    local db_path="$1"
    local md5 size mtime rest record

    REENCODED_SET=()

    if [ ! -f "$db_path" ]; then
        return 0
    fi

    if db_is_nul_format "$db_path"; then
        while IFS= read -r -d '' record; do
            [ -z "$record" ] && continue
            # Field 1..3 are space-free numbers/hashes; the path is the tail.
            read -r md5 size mtime rest <<< "$record"
            [ -z "$md5" ] && continue
            REENCODED_SET["$md5|$size"]=1
        done < "$db_path"
        return 0
    fi

    # Legacy newline form.
    while IFS= read -r record || [ -n "$record" ]; do
        [ -z "$record" ] && continue
        case "$record" in \#*) continue ;; esac
        read -r md5 size mtime rest <<< "$record"
        [ -z "$md5" ] && continue
        REENCODED_SET["$md5|$size"]=1
    done < "$db_path"
}

# Rewrites a legacy (newline-delimited) tracking DB into the NUL record form, in
# place via a temp file and one mv, so a crash mid-rewrite leaves either the old DB
# or the new one - never a truncated file. Idempotent: a DB that is already in the
# NUL form (or does not exist) is left alone, which is also why every shard that is
# about to be merged into it can call this unconditionally.
# MUST run with no writer active: the parent calls it before it forks the pool.
# $1 = DB path. 0 on success (including "nothing to do").
migrate_reencoded_db() {
    local db_path="$1"
    local tmp_path line migrated=0

    [ -f "$db_path" ] || return 0
    [ -s "$db_path" ] || return 0
    db_is_nul_format "$db_path" && return 0

    tmp_path="${db_path}.migrating.$$"
    : > "$tmp_path" || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac
        printf '%s\0' "$line" >> "$tmp_path" || { rm -f "$tmp_path"; return 1; }
        migrated=$((migrated + 1))
    done < "$db_path"

    if ! mv "$tmp_path" "$db_path"; then
        rm -f "$tmp_path"
        return 1
    fi
    return 0
}

# Appends a fingerprint to an ARBITRARY file, not the shared DB: each worker uses
# its own shard so no two processes append to one file (append atomicity is not
# guaranteed on NFS/SMB, where libraries commonly live). Same NUL record format as
# mark_as_reencoded, so a merged shard is indistinguishable from the DB.
# $1 = target file (a shard, or the DB when jobs=1), $2 = FLAC file.
record_reencoded_to() {
    local target_path="$1"
    local file="$2"
    local fp

    fp=$(get_file_fingerprint "$file") || return 1

    mkdir -p "$(dirname "$target_path")"
    printf '%s %s\0' "$fp" "$file" >> "$target_path"
    return 0
}

# Appends the file's fingerprint to the DB and adds it to REENCODED_SET.
# A legacy DB is migrated first, so an append can never mix the two record forms.
# $1 = DB path, $2 = FLAC file. Non-zero if no fingerprint could be made.
mark_as_reencoded() {
    local db_path="$1"
    local file="$2"
    local fp md5 size mtime rest key

    fp=$(get_file_fingerprint "$file") || return 1

    read -r md5 size mtime rest <<< "$fp"

    mkdir -p "$(dirname "$db_path")"
    migrate_reencoded_db "$db_path" || true
    # Append "<md5> <size> <mtime> <path>" as ONE NUL-terminated record; the path is
    # the LAST field and the terminator is NUL, so the name may contain any byte.
    printf '%s %s\0' "$fp" "$file" >> "$db_path"

    key="${md5}|${size}"
    # REENCODED_SET is declared in the entry and read by reencode_new_files
    # (lib/reencode.sh), so this module only ever writes it.
    # shellcheck disable=SC2034
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

    # A backup at the filesystem root is refused, including the spellings that do not
    # look like it: '/tmp/..' collapses to '/', and '//' survives as a spelling in its
    # own right (a stored '//' reaches this check as '///', after one trailing slash is
    # stripped). Mirroring a library there would scatter originals across the root
    # filesystem, and the '<backup>/<rel>' prefix test below cannot see it - for '//'
    # its pattern is "//*", which never matches. All-slash spellings are therefore
    # refused together.
    case "$bak_real" in
        *[!/]*|'') : ;;                              # has a non-slash: a real path
        *)
            echo "Error: The backup directory cannot be the filesystem root." >&2
            return 1
            ;;
    esac

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

# Longest derived file NAME, in BYTES. 255 is the NAME_MAX ext4, XFS, Btrfs, ZFS
# and the usual NFS/SMB servers agree on.
readonly TEMP_NAME_MAX=255

# Prints the in-library temp path a reencode of $1 will use. The ONE source of
# truth: reencode_one_file creates it and _pool_start_worker records it for the
# interrupt sweep, so the two can never disagree.
#
# Normally '<dir>/tmp_<base>.part', NOT '*.flac', so a live temp is invisible to
# find_real_flac_files and an interrupted-run leftover can never be picked up by a
# later scan or reencode-NEW. That name is 9 bytes LONGER than the original, so a
# basename near NAME_MAX - Lidarr copies a long track title verbatim - yields a name
# the kernel can neither create (flac: "ERROR initializing encoder", state
# FLAC__STREAM_ENCODER_IO_ERROR) nor unlink (rm: "File name too long"), and the file
# could never be reencoded. When the name does not fit, use
# 'tmp_<md5 of the full path>.part' instead: fixed length, unique per file (two
# workers in one directory can never share a temp) and deterministic, so the
# pre-delete in reencode_one_file still clears a leftover from an interrupted run.
# Returns 1 if no hash could be computed (only possible on the long-name path).
temp_path_for_file() {
    local flac_file="$1"
    local file_dir base name digest
    # Byte semantics, like the kernel's own limit: in a UTF-8 locale ${#name}
    # counts multi-byte characters as one each, so it under-reports the on-disk
    # length (a 255-byte name of 'é's looks like 128 characters).
    local LC_ALL=C

    # Same result as dirname/basename for a normal absolute path, without two forks
    # per file. A slash-less path keeps '.' as dirname would; a '*/' basename also
    # falls back to '.' rather than printing an empty one.
    case "$flac_file" in
        */*) file_dir=${flac_file%/*}; base=${flac_file##*/} ;;
        *)   file_dir='.';              base=$flac_file ;;
    esac
    [ -n "$file_dir" ] || file_dir='/'
    [ -n "$base" ] || base='.'

    name="tmp_${base}.part"
    if [ "${#name}" -gt "$TEMP_NAME_MAX" ]; then
        digest=$(printf '%s' "$flac_file" | md5sum 2>/dev/null) || return 1
        # md5sum prefixes its "<hex>  -" output; the hex is all that is kept.
        digest=${digest%% *}
        if ! [[ "$digest" =~ ^[0-9a-fA-F]+$ ]]; then
            return 1
        fi
        name="tmp_${digest}.part"
    fi
    printf '%s/%s\n' "$file_dir" "$name"
}
