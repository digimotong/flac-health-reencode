# FLAC Health Check & Re-encode

Scans a FLAC music library for corrupted files, re-encodes them, and keeps a
backup of every original it replaces.

It runs `flac -t` over the whole library and writes the failures to a timestamped
CSV report, then re-encodes with `flac --verify --decode-through-errors
--preserve-modtime` — losslessly, so timestamps survive. Files are processed
several at a time (see [Configuration](#configuration)), which is what makes a
large library bearable. Re-encoding is safe by default: each original is mirrored
into a backup directory outside the library before it is replaced, and the
replacement only lands once the new copy has been verified.

## Install & Run

```bash
git clone https://github.com/digimotong/flac-health-reencode.git
cd flac-health-reencode
chmod +x flac_health_reencode.sh
./flac_health_reencode.sh
```

On first run, use option 3 to point the script at your music library and backup
directory.

## Usage

Running the script draws a numbered menu; the table below is what each option
does. The menu also prints the active library, backup directory and worker count, and
accepts `q` as a shortcut for quitting.

| Option | Action | Notes |
|--------|--------|-------|
| `1` | Scan music library for errors | Read-only. Writes a CSV report; changes no audio file. |
| `2` | Reencode problematic FLAC files | Acts on the latest scan report. Mirrors each original into the backup directory first. |
| `3` | Set/Update library path & backup directory | First-run setup. Validates that the backup destination is safe. |
| `4` | Reencode ALL FLAC files | Confirmed by typing `REENCODE ALL`. Slow on a large library — check free disk space for the backups first. |
| `5` | Reencode NEW FLAC files only | Skips files already recorded in the tracking database. Use it after an option 4 run to pick up newly added albums. |
| `6` | Quit | Same as `q`. |

Options 2, 4 and 5 always mirror each original into the configured backup
directory before replacing it with the re-encoded copy — the backup mirrors the
library's layout (`<library>/Artist/Album/song.flac` →
`<backup>/Artist/Album/song.flac`) and an existing backup is never overwritten,
so the pristine original survives re-runs. Without a backup, a file is not
re-encoded. To restore one, copy it back out of the backup tree over the
re-encoded file. Verify your re-encodes and you can delete the whole backup tree
in one go.

The backup destination must be absolute and may not be the library, inside it,
or a parent of it; all three are refused with an explanation. If the config has
no `backup_path`, the script suggests `<library>_backup` and asks before using
it (options 2 and 5) or just prints it (option 4).

Files inside the script's own `backup_FLAC_originals/` folders (in-library
backups written by older versions) and its `.flac_scan_data/` directory are never
scanned, re-encoded or backed up. Re-encoded originals are **not** written inside
the library either: `.flac_scan_data/` holds the CSV scan reports, the per-run
re-encode logs and `reencoded.db`, the fingerprints of files already re-encoded —
which is what option 5 skips.

## Configuration

On first run the script creates `flac_health_config.json` next to itself.
Set both paths from the menu, or edit the file directly:

```json
{
  "library_path": "/path/to/music",
  "backup_path": "/path/to/music_backup",
  "version": "1.1"
}
```

| Key | Required | Description |
|-----|----------|-------------|
| `library_path` | yes | Absolute path to the FLAC library to scan and re-encode. |
| `backup_path` | no | Absolute path for the mirrored originals. Left empty or absent, the script derives `<library_path>_backup` (a sibling of the library) and offers it as the default the first time you re-encode. Setting it explicitly is recommended when backup storage lives elsewhere, e.g. `/mnt/backup/music`. |
| `version` | — | Written when the script creates the file; the script never reads it back, so leave it alone. |

Both paths must be absolute, and trailing slashes are accepted on either.

| Key | Required | Description |
|-----|----------|-------------|
| `jobs` | no | How many files to handle at once, for **both** re-encoding and scanning. Absent, non-numeric or `< 1` falls back to the default `min(4, nproc)`. `1` means strictly sequential. |

The worker count is resolved per run, in this order: `FLAC_HEALTH_JOBS` (a
per-run environment override, e.g. `FLAC_HEALTH_JOBS=8 ./flac_health_reencode.sh`),
then `jobs` in the config, then `min(4, nproc)`.

Re-encoding is CPU- and I/O-heavy but `flac` itself is single-threaded per file,
so the script parallelises **across files**: options 1, 2, 4 and 5 keep several
files in flight at once. Both operations share one knob and one pool — a scan is
read-only and needs no temp files or backups, so it gets the same scheduler and
only differs in the per-file work (`flac -t` instead of a re-encode).

That is safe because a file is only ever handed to one worker, each worker writes
to its own temp file and moves it into place atomically, and a failure is
contained: one bad file (including a `--decode-through-errors` file with a long
tail) does not stop or corrupt the others. Per-file lines are replayed in file
order once the workers finish, so logs and the tracking database end up as they
would in a sequential run.

Every file moves roughly three times its size through the filesystem (source
read, temp write, backup copy), so the pool saturates your **storage** long before
it saturates the CPU. The default of 4 is a compromise that helps on spinning
disks and NVMe alike without starving a media server reading the same library.
Raise it on fast local storage; set `jobs: 1` if the library is on a slow network
share where concurrent access makes things worse.

## Troubleshooting

- `flac`, `metaflac` and `jq` are checked before the menu appears. A missing
  tool exits with status `1` and a message naming the command, so install it and
  run the script again.

## Development

Requires Bash 4.3+, `jq`, and `shellcheck` for linting.

```bash
bash tests/run_tests.sh                # test suite
bash tests/lint.sh                     # shellcheck
```

The suite drives the real script inside throwaway sandboxes with stubbed `flac`
and `metaflac` binaries, so it needs no FLAC tools and touches nothing outside a
sandbox. It runs in CI on every push and pull request. If you change the
`flac`/`metaflac` flags the script passes, update `tests/stub_flac` and
`tests/stub_metaflac` to match.

Sandboxes pin `jobs: 1`, so the bulk of the suite exercises the sequential path;
`tests/case_parallel.sh` covers the pooled one instead, asserting that work
overlaps and that the merged log, CSV report and tracking database are identical
at any worker count.

## Requirements

- Bash 4.3+ (associative arrays and `wait -n`, both used by the worker pool)
- `flac` (which also provides `metaflac`) and `jq`

```bash
# Debian / Ubuntu
sudo apt-get install flac jq

# macOS
brew install flac jq
```
