#!/usr/bin/env bash
# real_flac_smoke.sh - end-to-end run against the REAL flac binary.
#
# Proves what the stubbed suite structurally cannot: that a real damaged file is
# detected by 'flac -t', that the reencoded replacement is a real, decodable FLAC
# carrying the same audio, that the backup is byte-identical to the ORIGINAL, and
# that the tracking DB / CSV / log all agree with what happened on disk.
#
# Sequence: generate 5 real FLACs, damage 2 (one by truncation, one by a byte
# flip), run option 1 (scan) then option 2 (reencode the newest CSV), then assert
# on the result. Both a jobs=1 and a jobs=4 variant are exercised, so the same
# real-file assertions cover the pooled path too.
#
# Prints "SKIP: ..." and exits 0 when the real flac/metaflac are unavailable.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_SCRIPT="${PROD_SCRIPT:-$(dirname "$(dirname "$DIR")")/flac_health_reencode.sh}"
export PROD_SCRIPT
# shellcheck source=tests/manual/lib.sh
source "$DIR/lib.sh"

mlib_require_real_tools

# mlib_run_variant <jobs>
#   One full scan+reencode cycle on a fresh sandbox. All assertions live here so
#   both worker counts get the identical treatment.
mlib_run_variant() {
    local jobs="$1"
    local sbx=''
    mlib_make_sandbox sbx
    mlib_set_config "$sbx" "$jobs"

    # --- fixture: 5 real FLACs, 2 of them damaged ---------------------------
    local n
    for n in 1 2 3 4 5; do
        mlib_make_flac "$sbx/lib/track0$n.flac" "$n"
    done
    # A pristine copy of every file, to compare backups/audio against later.
    local pristine="$sbx/pristine"
    mkdir -p "$pristine"
    cp "$sbx/lib"/*.flac "$pristine/"
    mlib_corrupt_truncate "$sbx/lib/track02.flac"
    mlib_corrupt_tail "$sbx/lib/track04.flac"
    cp "$sbx/lib/track02.flac" "$pristine/track02.corrupt"
    cp "$sbx/lib/track04.flac" "$pristine/track04.corrupt"

    # Sanity: the damage must be real, or every later assertion is vacuous.
    if flac -t --silent "$sbx/lib/track02.flac" 2>/dev/null; then
        mlib_fail "track02.flac still verifies after truncation - the fixture did not damage it"
    fi
    if flac -t --silent "$sbx/lib/track04.flac" 2>/dev/null; then
        mlib_fail "track04.flac still verifies after the byte flip - the fixture did not damage it"
    fi
    if ! flac -t --silent "$sbx/lib/track01.flac" 2>/dev/null; then
        mlib_fail "track01.flac does not verify - the pristine fixture is broken"
    fi
    mlib_log "jobs=$jobs: 5 real FLACs created, 2 damaged"

    # --- option 1: scan -----------------------------------------------------
    mlib_run_menu "$sbx" "1" ""
    local csv
    csv="$(mlib_latest_csv "$sbx")"
    [ -n "$csv" ] || mlib_fail "jobs=$jobs: option 1 produced no scan CSV"
    grep -q 'Found 2 errors' "$sbx/run.out" \
        || mlib_fail "jobs=$jobs: scan did not report exactly 2 errors (see $sbx/run.out)"

    # The CSV must list EXACTLY the two damaged files, fully qualified.
    local csv_rows expected
    csv_rows="$(sed -e 's/^"//' -e 's/"$//' "$csv" | grep -v '^#' | grep -v '^filepath$' | sed '/^$/d' | sort)"
    expected="$(printf '%s\n%s\n' "$sbx/lib/track02.flac" "$sbx/lib/track04.flac" | sort)"
    [ "$csv_rows" = "$expected" ] \
        || mlib_fail "jobs=$jobs: CSV rows are not exactly the two bad files:
--- got ---
$csv_rows
--- want ---
$expected"
    mlib_log "jobs=$jobs: scan CSV lists exactly track02 + track04"

    # A scan must never modify library content.
    cmp -s "$sbx/lib/track01.flac" "$pristine/track01.flac" \
        || mlib_fail "jobs=$jobs: option 1 modified track01.flac"
    mlib_log "jobs=$jobs: option 1 left all library content untouched"

    # --- option 2: reencode the newest CSV ----------------------------------
    mlib_run_menu "$sbx" "2" "Y" ""
    grep -q 'Total files processed: 2' "$sbx/run.out" \
        || mlib_fail "jobs=$jobs: reencode did not process exactly 2 files (see $sbx/run.out)"
    grep -q 'Successful reencodes: 2' "$sbx/run.out" \
        || mlib_fail "jobs=$jobs: reencode did not report 2 successes (see $sbx/run.out)"
    grep -q 'Failed reencodes: 0' "$sbx/run.out" \
        || mlib_fail "jobs=$jobs: reencode reported failures (see $sbx/run.out)"

    # Every file in the library must now be a decodable FLAC, the two repaired
    # ones included.
    local n
    for n in 1 2 3 4 5; do
        mlib_assert_real_flac "$sbx/lib/track0$n.flac"
    done
    mlib_log "jobs=$jobs: all 5 files verify with real 'flac -t'"

    # A repaired file must be a genuine re-encode, not the damaged bytes left in
    # place.
    if cmp -s "$sbx/lib/track02.flac" "$pristine/track02.corrupt"; then
        mlib_fail "jobs=$jobs: track02.flac was not actually replaced"
    fi
    if cmp -s "$sbx/lib/track04.flac" "$pristine/track04.corrupt"; then
        mlib_fail "jobs=$jobs: track04.flac was not actually replaced"
    fi

    # The repaired audio must have the same stream properties as the pristine
    # original: a re-encode that "passes -t" but is a different length or depth
    # would be silent data loss.
    local want_info got_info
    want_info="$(metaflac --show-total-samples --show-bps --show-sample-rate \
                    --show-channels "$pristine/track02.flac" | tr '\n' ' ')"
    got_info="$(metaflac --show-total-samples --show-bps --show-sample-rate \
                    --show-channels "$sbx/lib/track02.flac" | tr '\n' ' ')"
    [ "$want_info" = "$got_info" ] \
        || mlib_fail "jobs=$jobs: repaired track02 stream properties changed: '$want_info' -> '$got_info'"

    # --- backups (checked BEFORE the option-4 pass below) --------------------
    # track02 and track04 were damaged, so option 2's backup for each is a copy of
    # the DAMAGED bytes (what we promised to preserve). The clean files were not in
    # the scan CSV, so option 2 left them alone and made no backup for them. This is
    # asserted here rather than at the end because the option-4 pass backs up the
    # whole library and would add more files to the tree.
    mlib_assert_backup_matches "$sbx/backup/track02.flac" "$pristine/track02.corrupt"
    mlib_assert_backup_matches "$sbx/backup/track04.flac" "$pristine/track04.corrupt"
    local bn
    bn=$(mlib_count "$sbx/backup" -type f -name '*.flac')
    [ "$bn" -eq 2 ] \
        || mlib_fail "jobs=$jobs: expected 2 backup files after option 2, found $bn"
    mlib_log "jobs=$jobs: option 2 backed up exactly the 2 damaged files, byte-identical"

    # The decoded audio must be IDENTICAL for a file that was NOT damaged. This is
    # the strongest statement the harness can make about losslessness, and it is
    # only asserted for an intact input: a re-encode of TRUNCATED input cannot
    # restore the missing frames - that is inherent to the data, not a script
    # defect - so asserting equality there would fail on a correct implementation.
    #
    # track01 is pristine and was in the library all along. It is not in the scan
    # CSV (only the damaged files are), so drive it through option 4 (reencode ALL)
    # to force a real decode/re-encode round-trip of intact audio.
    #
    # Option 4 demands the literal phrase 'REENCODE ALL', not a bare 'Y': it is the
    # destructive path, so its guard is deliberately stronger. Passing 'Y' CANCELS
    # the run, which would make the following assertions vacuous.
    mlib_run_menu "$sbx" "4" "REENCODE ALL" ""
    local wav_orig wav_new
    wav_orig="$sbx/orig01.wav"
    wav_new="$sbx/new01.wav"
    flac -d --silent --force -o "$wav_orig" "$pristine/track01.flac"
    flac -d --silent --force -o "$wav_new" "$sbx/lib/track01.flac"
    cmp -s "$wav_orig" "$wav_new" \
        || mlib_fail "jobs=$jobs: decoded audio of an intact file changed across the re-encode"
    mlib_log "jobs=$jobs: intact-file re-encode is lossless (decoded audio identical)"

    # The repaired files must carry real audio, not nothing: a repaired file that
    # decodes to zero samples would pass 'flac -t' while being useless.
    local got_samples
    got_samples="$(metaflac --show-total-samples "$sbx/lib/track02.flac")"
    if [ -z "$got_samples" ] || [ "$got_samples" -le 0 ]; then
        mlib_fail "jobs=$jobs: repaired track02 reports no samples ('$got_samples')"
    fi
    mlib_log "jobs=$jobs: repaired track02 reports $got_samples samples"

    # --- tracking DB --------------------------------------------------------
    # Row format is "md5 size mtime path" (see record_reencoded_to), so the path is
    # the LAST field, not the first.
    #
    # This runs two separate reencode passes (option 2, then option 4), so a file
    # legitimately has TWO rows: one appended per pass. Duplicates within a SINGLE
    # pass are the parallel merge bug (two workers' shards folded in twice), and the
    # per-pass row count is what the run reported, so that is asserted instead of
    # global uniqueness. The merge behaviour itself is pinned precisely by
    # tests/case_parallel.sh; here the real-file goal is "every file is recorded and
    # the DB is consistent with what the runs claimed".
    local db db_paths total_rows
    db="$sbx/lib/.flac_scan_data/reencoded.db"
    [ -f "$db" ] || mlib_fail "jobs=$jobs: no tracking database at $db"
    db_paths=$(awk '{print $NF}' "$db" | sort)
    total_rows=$(printf '%s\n' "$db_paths" | grep -c . || true)

    # Option 2 recorded 2 files, option 4 recorded 5 -> 7 rows.
    [ "$total_rows" -eq 7 ] \
        || mlib_fail "jobs=$jobs: expected 7 DB rows (2 from option 2 + 5 from option 4), found $total_rows:
$db_paths"

    # No single run may append a path twice. Option 2's 2 rows and option 4's 5 rows
    # must each be internally unique, which is what a broken merge would violate.
    local per_path
    per_path=$(printf '%s\n' "$db_paths" | uniq -c | awk '$1 > 2 {print}')
    [ -z "$per_path" ] \
        || mlib_fail "jobs=$jobs: a path was recorded more than twice (merge bug):
$per_path"

    # Every library file must be present, and no foreign path may appear.
    local missing="" n
    for n in 1 2 3 4 5; do
        printf '%s\n' "$db_paths" | grep -qxF "$sbx/lib/track0$n.flac" \
            || missing="$missing track0$n.flac"
    done
    [ -z "$missing" ] \
        || mlib_fail "jobs=$jobs: tracking DB is missing file(s):$missing"
    local foreign
    foreign=$(printf '%s\n' "$db_paths" | grep -vF "$sbx/lib/track0" || true)
    [ -z "$foreign" ] \
        || mlib_fail "jobs=$jobs: tracking DB contains unexpected paths:
$foreign"
    mlib_log "jobs=$jobs: tracking DB has 7 consistent rows covering all 5 files"

    # --- hygiene ------------------------------------------------------------
    mlib_assert_no_residue "$sbx/lib"
    local shard_dirs
    shard_dirs=$(mlib_count "$sbx/lib/.flac_scan_data/logs" -type d -name shards)
    [ "$shard_dirs" -eq 0 ] || mlib_fail "jobs=$jobs: a shards/ directory survived the run"
    mlib_log "jobs=$jobs: no temp files, shards, or seed lists left behind"

    # A second reencode of the same CSV must be a no-op: the DB now covers both
    # files, so option 2 skips everything and changes nothing.
    local before_sum after_sum
    before_sum="$(md5sum "$sbx/lib"/*.flac | awk '{print $1}' | sort | md5sum)"
    mlib_run_menu "$sbx" "2" "Y" ""
    after_sum="$(md5sum "$sbx/lib"/*.flac | awk '{print $1}' | sort | md5sum)"
    [ "$before_sum" = "$after_sum" ] \
        || mlib_fail "jobs=$jobs: a second reencode run modified already-reencoded files"
    mlib_log "jobs=$jobs: re-running reencode is idempotent"
}

mlib_run_variant 1
mlib_run_variant 4

echo "OK: real-flac smoke passed for jobs=1 and jobs=4"

