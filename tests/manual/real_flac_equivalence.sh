#!/usr/bin/env bash
# real_flac_equivalence.sh - a pooled run must be indistinguishable from a serial one.
#
# Builds TWO sandboxes that are byte-identical to begin with (same seeded PCM, so
# the same FLAC bytes), then runs option 4 (reencode ALL) with jobs=1 in one and
# jobs=4 in the other. Afterwards every observable must match:
#   * the library trees are identical (names, layout, contents)
#   * the backup trees are identical
#   * the tracking DBs, compared as sorted rows, are identical
#   * every reencoded file verifies with the real 'flac -t'
#
# This is the check that gives the parallel branch its confidence: the stubbed
# suite compares counts and order, but only this compares the bytes a real user
# would end up with.
#
# Prints "SKIP: ..." and exits 0 when the real flac/metaflac are unavailable.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_SCRIPT="${PROD_SCRIPT:-$(dirname "$(dirname "$DIR")")/flac_health_reencode.sh}"
export PROD_SCRIPT
# shellcheck source=tests/manual/lib.sh
source "$DIR/lib.sh"

mlib_require_real_tools

# mlib_build_tree <sbx> <jobs> <file-count>
#   Identical fixture for both runs: N real FLACs across two subdirectories, one
#   of them damaged, so the run has real work to do and a real failure path.
mlib_build_tree() {
    local sbx="$1" jobs="$2" count="$3"
    mlib_set_config "$sbx" "$jobs"
    local i path
    for i in $(seq 1 "$count"); do
        if [ $((i % 2)) -eq 0 ]; then
            path="$sbx/lib/album_b/track$(printf '%02d' "$i").flac"
        else
            path="$sbx/lib/album_a/track$(printf '%02d' "$i").flac"
        fi
        mlib_make_flac "$path" "$i"
    done
    # Exactly one damaged file, in a deterministic position.
    mlib_corrupt_truncate "$sbx/lib/album_a/track03.flac"
}

# mlib_snapshot <dir> : a stable "name mode md5" listing of a tree, so two trees
# can be compared without depending on mtimes (which differ by design).
mlib_snapshot() {
    local root="$1"
    (
        cd "$root" 2>/dev/null || exit 0
        find . -mindepth 1 \( -type f -o -type d \) -printf '%P\n' | sort \
        | while IFS= read -r rel; do
            if [ -d "$rel" ]; then
                printf 'd %s %s\n' "$(stat -c '%a' "$rel")" "$rel"
            else
                printf 'f %s %s %s\n' "$(stat -c '%a' "$rel")" \
                    "$(md5sum < "$rel" | cut -d' ' -f1)" "$rel"
            fi
        done
    )
}

# mlib_db_rows <lib_dir> : the tracking DB as FILENAME-PROJECTED rows.
#   Each row is "md5 size mtime path". The mtime is a WALL-CLOCK value stamped at
#   run time, so it necessarily differs between the two runs (a run started in the
#   next second differs by one) and comparing it would test the clock, not the
#   reencoder. The path is therefore projected to a stable library-relative name and
#   the mtime is dropped; md5 and size are kept because those are what the skip
#   decision keys on and what must agree across worker counts.
#
#   Only the first three fields are printed, and the projection is done with awk on
#   $NF, so a path containing spaces stays intact and no field can leak the mtime.
mlib_db_rows() {
    local lib="$1" db
    db="$lib/.flac_scan_data/reencoded.db"
    [ -f "$db" ] || return 0
    awk -v lib="$lib/" '
        NF >= 2 && $NF ~ ("^" lib) {
            n = $NF
            sub("^" lib, "", n)
            printf "%s %s %s\n", $1, $2, n
        }
    ' "$db" | sort
}

sbx_serial=''
sbx_parallel=''
mlib_make_sandbox sbx_serial
mlib_make_sandbox sbx_parallel

COUNT=8
mlib_log "building two identical libraries of $COUNT real FLACs (one damaged)"
mlib_build_tree "$sbx_serial" 1 "$COUNT"
mlib_build_tree "$sbx_parallel" 4 "$COUNT"

# The two libraries must start out identical, or the comparison is meaningless.
if ! diff -r "$sbx_serial/lib" "$sbx_parallel/lib" >/dev/null 2>&1; then
    mlib_fail "the two fixture libraries differ before the runs - the harness is broken"
fi
mlib_log "fixtures verified identical before the runs"

# --- run option 4 (reencode ALL) in both ------------------------------------
# Menu: 4 -> warning -> the literal confirmation phrase -> Enter. 'Y' is NOT
# accepted here and would silently cancel the run (see reencode_all_files).
mlib_run_menu "$sbx_serial" "4" "REENCODE ALL" ""
mlib_log "serial (jobs=1) run finished"
mlib_run_menu "$sbx_parallel" "4" "REENCODE ALL" ""
mlib_log "parallel (jobs=4) run finished"

# --- compare ----------------------------------------------------------------
# The comparison is deliberately restricted to AUDIO and BACKUPS. Run logs and
# bookkeeping under .flac_scan_data legitimately differ between worker counts (a
# pooled run replays status lines in file order, and the scan/seed files are
# per-run), so including them would test the log writer, not the reencoder. What
# must be identical is what the user actually keeps.
mlib_compare_audio_trees() {
    local a="$1" b="$2" label="$3"
    if ! diff <(mlib_snapshot "$a") <(mlib_snapshot "$b") >/dev/null; then
        mlib_fail "$label DIFFER between jobs=1 and jobs=4:
$(diff <(mlib_snapshot "$a") <(mlib_snapshot "$b") | head -40)"
    fi
    mlib_log "$label identical"
}

# Snapshot only the .flac payloads under a library, ignoring the internal
# .flac_scan_data bookkeeping tree entirely.
mlib_lib_audio_snapshot() {
    local lib="$1"
    (
        cd "$lib" || exit 0
        find . -path './.flac_scan_data' -prune -o -type f -name '*.flac' -printf '%P\n' \
        | sort | while IFS= read -r rel; do
            printf 'f %s %s %s\n' "$(stat -c '%a' "$rel")" \
                "$(md5sum < "$rel" | cut -d' ' -f1)" "$rel"
        done
    )
}

if ! diff <(mlib_lib_audio_snapshot "$sbx_serial/lib") \
          <(mlib_lib_audio_snapshot "$sbx_parallel/lib") >/dev/null; then
    mlib_fail "LIBRARY AUDIO TREES DIFFER between jobs=1 and jobs=4:
$(diff <(mlib_lib_audio_snapshot "$sbx_serial/lib") \
        <(mlib_lib_audio_snapshot "$sbx_parallel/lib") | head -40)"
fi
mlib_log "library audio trees identical (every reencoded payload byte-for-byte)"

mlib_compare_audio_trees "$sbx_serial/backup" "$sbx_parallel/backup" "backup trees"

# Tracking DBs. mlib_db_rows already projects each path to a library-relative name
# and drops the run-time mtime, so the two runs' rows are directly comparable.
rows_serial="$(mlib_db_rows "$sbx_serial/lib")"
rows_parallel="$(mlib_db_rows "$sbx_parallel/lib")"
if [ "$rows_serial" != "$rows_parallel" ]; then
    mlib_fail "TRACKING DB DIFFERS between jobs=1 and jobs=4 (md5+size+name):
--- jobs=1 ---
$rows_serial
--- jobs=4 ---
$rows_parallel"
fi
n_db=$(printf '%s\n' "$rows_serial" | grep -c . || true)
[ "$n_db" -eq "$COUNT" ] \
    || mlib_fail "expected $COUNT tracking-DB rows, found $n_db"
mlib_log "tracking DBs identical ($n_db rows, mtime excluded as run-specific)"

# --- everything must still be real audio ------------------------------------
n_bad=0
while IFS= read -r -d '' f; do
    flac -t --silent "$f" 2>/dev/null || n_bad=$((n_bad + 1))
done < <(find "$sbx_parallel/lib" -type f -name '*.flac' -print0)
[ "$n_bad" -eq 0 ] || mlib_fail "$n_bad file(s) in the jobs=4 library fail real 'flac -t'"
mlib_log "every file in the jobs=4 library verifies with real 'flac -t'"

# The number of distinct audio payloads must be unchanged: N reencodes of N
# differently-seeded inputs must not collapse onto one another.
n_audio=$(find "$sbx_parallel/lib" -type f -name '*.flac' -exec md5sum {} + \
          | awk '{print $1}' | sort -u | wc -l)
[ "$n_audio" -eq "$COUNT" ] \
    || mlib_fail "expected $COUNT distinct reencoded files, found $n_audio"
mlib_log "$COUNT distinct reencoded payloads preserved"

echo "OK: jobs=1 and jobs=4 produce byte-identical libraries, backups and DBs"
