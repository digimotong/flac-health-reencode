# tests/manual — real-`flac` verification harness

`tests/run_tests.sh` proves the **scheduler**: sharding, ordering, tallying, the
DB merge and shard hygiene, all against stubbed `flac`/`metaflac`. It is fast,
hermetic and dependency-free, which is why it is the required CI job.

It therefore cannot prove anything about **real audio**: that a damaged file is
actually detected by `flac -t`, that a re-encoded replacement decodes to the same
samples, that a backup is byte-identical to the original, or that a concurrent run
survives an interrupt or a storage fault. This directory covers that gap.

## Running it

```bash
bash tests/manual/run_manual.sh              # everything
bash tests/manual/run_manual.sh real_flac_smoke.sh   # one script
```

Every script creates its sandbox under `TMPDIR` with `mktemp -d` and removes it on
exit, including on failure, so nothing is written into the working tree.

**If `flac`/`metaflac` are not installed, each script prints a single `SKIP:` line
and exits 0.** That is deliberate: the harness stays green in a container without
the flac package, while still being a real gate on a host that has it. A run where
everything skipped is reported as such rather than silently counted as coverage.

## Scripts

| Script | What it proves |
| --- | --- |
| `real_flac_smoke.sh` | Full option 1 → option 2 cycle over real FLACs, with two damaged by different means (truncation and a tail flip). Asserts the CSV lists exactly the bad files, the repaired files are genuine re-encodes — not the damaged bytes left in place — that verify with real `flac -t`, the backups `cmp`-equal the damaged originals, no residue survives, and a re-run is idempotent. Runs for `jobs=1` **and** `jobs=4`. |
| `real_flac_equivalence.sh` | `jobs=1` vs `jobs=4` on byte-identical fixtures (`diff -r`-checked before the runs) running option 4. Afterwards the library `*.flac` payloads and the whole backup tree must match on `name mode md5`, the tracking DBs on `md5 size library-relative-name`, every `jobs=4` file must verify with real `flac -t`, and the 8 distinct payloads must not collapse onto one another. Mtimes and the per-run `.flac_scan_data` bookkeeping are excluded by design. |
| `real_flac_resilience.sh` | (A) `SIGTERM` the **parent only** mid-run — a terminal Ctrl-C signals the whole process group, so it can hide a missing handler: asserts the handler kills workers *and* their `flac` grandchildren, sweeps temps/shards, exits 143, and that a re-run still repairs everything. (B) `chmod 000` source: one clean failure, siblings still repaired, the unreadable file not clobbered. (C) Unwritable backup root: no payload is rewritten — an assert on the audio, not on an exit status, and skipped as root, where directory permissions deny nothing. (D) `kill -9` a `flac` child: counted as a failure, run completes, no residue — or, when the kill takes this test's shared process group down with it, reported as inconclusive rather than counted as a pass. |

A repaired file must keep the original bit depth / sample rate / channels, and its
sample count must match the **salvage oracle** exactly: not fewer (frames the
decoder could still have salvaged were dropped), not more (audio was invented).
The oracle is the repair command itself — `flac --verify --compression-level-0
--decode-through-errors` over the copy of the damaged bytes the script saw — so
both sides agree on what "salvageable" means. Truncation drops trailing frames
outright, so equality with the *pristine* original is unachievable; decoded-audio
equality is therefore asserted where it *is* achievable — an intact file
re-encoded via option 4.

The tracking DB gains one row per re-encode per pass (2 from option 2 + 5 from
option 4 = 7), so one path legitimately appearing twice is normal. What is
asserted is that no *single pass* records a path twice, which is the parallel
merge bug.

## CI

`.github/workflows/tests.yml` runs this harness in a separate, **non-required**
job (`manual-real-flac`) that first installs the `flac` package. It is not a
required check because it needs a real binary and real CPU time; the required
`test` and `lint` jobs stay hermetic. See the workflow for the exact wiring.

The job asserts `flac`/`metaflac` really landed on `PATH` before running this
harness. Without that, a package outage or a renamed package would leave every
script SKIPping — and because a SKIP is not a failure, the job would report green
while verifying nothing.

## Adding a script

1. `source` `lib.sh` (it sets `set -euo pipefail`, an EXIT cleanup trap, and the
   `mlib_*` helpers).
2. Call `mlib_require_real_tools` (or `mlib_require_basic_tools` if you only
   inspect the script's own output).
3. Build fixtures with `mlib_make_sandbox` / `mlib_make_flac`, and fail with
   `mlib_fail "..."`, never a bare `exit 1`. Declare the sandbox variable as
   `local sbx=''` before calling `mlib_make_sandbox` — it assigns through a
   nameref, which `set -u` rejects on an unset variable.
4. Make sure the file is tracked: the repo is a deny-all `.gitignore`, and
   `!tests/*` does **not** descend into this subdirectory — `!tests/manual/` and
   `!tests/manual/*` are what keep these files in git.
