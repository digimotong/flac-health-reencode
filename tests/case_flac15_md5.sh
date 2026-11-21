#!/usr/bin/env bash
# case_flac15_md5.sh - integration: repairs survive flac >= 1.5's input-MD5 check.
#
# WHY THIS EXISTS. flac 1.5 (upstream commit a9306bb) verifies, when re-encoding a
# FLAC file to FLAC, that the OUTPUT's STREAMINFO MD5 matches the INPUT's:
#
#     "<file>: ERROR: MD5sum of input is different from MD5sum of output"  (exit 1)
#
# A damaged file - exactly what this script repairs with --decode-through-errors -
# decodes to audio that no longer matches its stored MD5, so on flac 1.5 every
# repair would be reported as a failure and the repaired file deleted. Ubuntu's
# runner image started shipping 1.5.0, which is how this surfaced (the real-flac
# CI job went red with no code change).
#
# The fix (reencode_one_file) retries ONCE with --until=<total samples>, which
# upstream documents in code as disabling that comparison while still encoding the
# whole file. This case pins both halves of the contract:
#   * a mismatching (damaged) file is repaired, not reported as failed;
#   * the retry happens ONLY for such files - a healthy file is encoded once, so
#     the safety check is not silently disabled for the whole library.
#
# The stub reproduces the 1.5 behaviour behind STUB_FLAC_MD5_CHECK (see
# tests/stub_flac) and logs every invocation to STUB_FLAC_RECORD_ARGS.

set -o errexit
set -o nounset
set -o pipefail

: "${TESTS_ROOT:?}"
: "${PROD_SCRIPT:?}"
. "$TESTS_ROOT/helpers.sh"

SBX=''
make_sandbox SBX
register_sandbox "$SBX"
LIB="$SBX/lib"

# One damaged file (the MD5MISMATCH marker the stub reacts to, plus the CORRUPT
# marker so a scan would also flag it) and one healthy file.
DAMAGED="$LIB/Album/damaged.flac"
HEALTHY="$LIB/Album/healthy.flac"
mkdir -p "$LIB/Album"
write_file "$DAMAGED" 'audio:CORRUPT:MD5MISMATCH'
write_file "$HEALTHY" 'audio:healthy'

RECORD="$SBX/flac_invocations.log"
: > "$RECORD"

# Option 4 (reencode ALL) keeps the fixture to two files while exercising the real
# reencode path (backup + replace + DB) for both.
run_script_env "$SBX" 'STUB_FLAC_MD5_CHECK=1' "STUB_FLAC_RECORD_ARGS=$RECORD" \
    -- '4' 'REENCODE ALL' '' 'q'

[ "$LAST_STATUS" -eq 0 ] || _fail "run exited $LAST_STATUS, expected 0"

# ===========================================================================
# 1. Both files are re-encoded: the damaged one is NOT reported as a failure.
# ===========================================================================
occur_re 'Successful reencodes: 2'
occur_re 'Failed reencodes: 0'
file_eq "$DAMAGED" 'REENCODE_OK' || _fail "damaged file was not repaired"
file_eq "$HEALTHY" 'REENCODE_OK' || _fail "healthy file was not re-encoded"

# Originals were backed up byte-for-byte before being replaced.
file_eq "$SBX/lib_backup/Album/damaged.flac" 'audio:CORRUPT:MD5MISMATCH'
file_eq "$SBX/lib_backup/Album/healthy.flac" 'audio:healthy'

# The run log records the repair as a SUCCESS, never a FAILURE, and explains the
# retry it took.
if grep -rq 'FAILURE' "$LIB/.flac_scan_data/logs/"; then
    _fail "the run log records a FAILURE although the repair succeeded"
fi
grep -rq 're-encoded with --until=' "$LIB/.flac_scan_data/logs/" \
    || _fail "the run log does not note the MD5-driven retry"

# No reencode temp may survive a successful run.
if find "$LIB" -type f -name 'tmp_*.part' | grep -q .; then
    _fail "a tmp_*.part file survived the run"
fi

# ===========================================================================
# 2. The retry is targeted: damaged -> 2 attempts (2nd with --until=), healthy -> 1.
# ===========================================================================
attempts_for() {
    grep -c -- "-o .*tmp_$(basename "$1").part" "$RECORD" || true
}

damaged_attempts=$(attempts_for "$DAMAGED")
healthy_attempts=$(attempts_for "$HEALTHY")

[ "$damaged_attempts" -eq 2 ] \
    || _fail "damaged file took $damaged_attempts encode attempt(s), expected 2 (first refused by the MD5 check, second with --until)"
[ "$healthy_attempts" -eq 1 ] \
    || _fail "healthy file took $healthy_attempts encode attempt(s), expected 1 (no retry needed)"

# The retried attempt must actually carry --until=, and the first must not (it has
# to try the plain form first, so a real corruption warning is still produced).
first_until=$(grep -- "tmp_$(basename "$DAMAGED").part" "$RECORD" | sed -n '1p' \
    | grep -c -- '--until=' || true)
second_until=$(grep -- "tmp_$(basename "$DAMAGED").part" "$RECORD" | sed -n '2p' \
    | grep -c -- '--until=' || true)
[ "$first_until" -eq 0 ] || _fail "the first attempt already passed --until= (the check would be skipped for every file)"
[ "$second_until" -eq 1 ] || _fail "the retry did not pass --until="

# The sample count handed to --until must be a positive number from metaflac.
grep -- "tmp_$(basename "$DAMAGED").part" "$RECORD" | sed -n '2p' \
    | grep -qE -- '--until=[1-9][0-9]*' \
    || _fail "the retry's --until= value is missing or zero"

echo "ok: case_flac15_md5 (flac 1.5 input-MD5 refusal handled with a targeted --until retry)"
