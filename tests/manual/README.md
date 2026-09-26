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
| `real_flac_smoke.sh` | Full option 1 → option 2 cycle over real FLACs, with two damaged by different means. Asserts the CSV lists exactly the bad files, the repaired files verify with `flac -t` while keeping the original bit depth/rate/channels and carrying **exactly** the audio still salvageable from the damaged bytes (truncation removes trailing frames outright, so those are gone for good — the check is calibrated against `flac --decode-through-errors` itself, the same command the script repairs with), backups `cmp`-equal the damaged originals, the DB has exactly the right unique rows, no residue survives, and a re-run is idempotent. A repaired file may not be a *length* shortcut either: its sample count must match the salvage oracle, no more (invented audio) and no less (dropped frames). The strongest losslessness claim — decoded audio identical — is made for an **intact** file re-encoded via option 4, where equality is actually achievable. Runs for `jobs=1` **and** `jobs=4`. |
| `real_flac_equivalence.sh` | `jobs=1` vs `jobs=4` on byte-identical fixtures (option 4). Requires `diff -r`-identical library and backup trees and identical tracking DBs, so a parallel run is indistinguishable from a serial one. |
| `real_flac_resilience.sh` | (A) `SIGTERM` the **parent only** mid-run: asserts the interrupt handler kills workers *and* their `flac` grandchildren, sweeps temps/shards, exits 143, and that a re-run still completes. (B) `chmod 000` source: one clean failure, siblings still repaired. (C) Unwritable backup root: run aborts without rewriting audio. (D) `kill -9` a `flac` child: counted as a failure, run completes, no residue. |

Scenario A signals the parent alone on purpose. A terminal Ctrl-C also signals the
whole process group, so it can hide a missing handler; `kill -TERM <parent>` is the
case that used to leave orphaned workers rewriting audio after the user believed
the run had stopped.

## CI

`.github/workflows/tests.yml` runs this harness in a separate, **non-required**
job (`manual-real-flac`) that first installs the `flac` package. It is not a
required check because it needs a real binary and real CPU time; the required
`test` and `lint` jobs stay hermetic. See the workflow for the exact wiring.

## Adding a script

1. `source` `lib.sh` (it sets `set -euo pipefail`, an EXIT cleanup trap, and the
   `mlib_*` helpers).
2. Call `mlib_require_real_tools` (or `mlib_require_basic_tools` if you only
   inspect the script's own output).
3. Build fixtures with `mlib_make_sandbox` / `mlib_make_flac`, and fail with
   `mlib_fail "..."`, never a bare `exit 1`.
4. Make sure the file is tracked: the repo is a deny-all `.gitignore`, and
   `!tests/*` does **not** descend into this subdirectory — `!tests/manual/` and
   `!tests/manual/*` are what keep these files in git.
