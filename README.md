# FLAC Health Check & Re-encode

Scans a FLAC music library for corrupted files, re-encodes them, and keeps a
backup of every original it replaces.

## Features

- Full-library scan for corrupted FLACs, written to a CSV report
- Re-encode just the reported files, the whole library, or only files that
  haven't been re-encoded before
- Original files backed up to `backup_FLAC_originals/` before being replaced
- Backup cleanup for after you've verified the re-encodes
- Color-coded terminal output with progress tracking
- Per-run logs and a small JSON config file

## Install & Run

```bash
git clone https://github.com/digimotong/flac-health-reencode.git
cd flac-health-reencode
chmod +x flac_health_reencode.sh
./flac_health_reencode.sh
```

On first run, use option 3 to point the script at your music library.

## Usage

```
1) Scan music library for errors
2) Reencode problematic FLAC files (from latest scan)
3) Set/Update default library path
4) Clean up FLAC backups
5) Reencode ALL FLAC files (with backups & warning)
6) Reencode NEW FLAC files only
7) Quit
```

- Options 2, 5 and 6 back up each original to a `backup_FLAC_originals/` folder
  next to it, then replace it with the re-encoded copy. Option 4 deletes those
  backup folders afterwards, so only run it once you've verified the re-encodes.
- The script never scans or re-encodes files inside its own
  `backup_FLAC_originals/` folders or the `.flac_scan_data/` directory.
- Option 5 re-encodes everything and asks you to confirm first. Expect it to be
  slow on a large library, and make sure there's disk space for the backups.
  Option 6 only processes files it hasn't recorded yet, so after an initial
  option 5 run you can use it to pick up newly added albums.

## Configuration

On first run the script creates `flac_health_config.json` next to itself.
Set the library path from the menu, or edit the file directly:

```json
{
  "library_path": "/path/to/music",
  "version": "1.0"
}
```

## What the Script Writes in Your Library

```
<library>/
├── Artist/Album/
│   ├── song.flac
│   └── backup_FLAC_originals/   # originals from before re-encoding
└── .flac_scan_data/
    ├── reports/                 # CSV scan reports
    ├── logs/                    # per-run re-encode logs
    └── reencoded.db             # fingerprints of re-encoded files
```

Each successful re-encode records the file's FLAC audio MD5, size and mtime in
`.flac_scan_data/reencoded.db`, which is what option 6 uses to tell new files
from ones it has already processed.

## Troubleshooting

- `flac`, `metaflac` and `jq` are checked before the menu appears. A missing tool
  exits with status `1` and a message naming the command, so install it and run
  the script again.
- A file that fails to re-encode is logged as `FAILURE` and left untouched: the
  original is only replaced after the new copy is verified. Backups are never
  overwritten, so re-running an option over the same files cannot lose a pristine
  original — restore one by copying it back out of `backup_FLAC_originals/`.
- Scan reports and per-run logs live in `.flac_scan_data/` inside your library,
  so a failed run can be reviewed after the fact.

## Development

Requires Bash, `jq`, and `shellcheck` for linting.

```bash
bash tests/run_tests.sh                # test suite
bash tests/lint.sh                     # shellcheck
```

The suite drives the real script inside throwaway sandboxes with stubbed `flac`
and `metaflac` binaries, so it needs no FLAC tools and touches nothing outside a
sandbox. It runs in CI on every push. If you change the `flac`/`metaflac` flags
the script passes, update `tests/stub_flac` and `tests/stub_metaflac` to match.

## Requirements

- Bash
- `flac` (which also provides `metaflac`) and `jq`

```bash
# Debian / Ubuntu
sudo apt-get install flac jq

# macOS
brew install flac jq
```
