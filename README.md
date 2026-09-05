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

## Requirements

Bash, `flac` (which also provides `metaflac`), and `jq`.

```bash
# Debian / Ubuntu
sudo apt-get install flac jq

# macOS
brew install flac jq
```

## Install & run

```bash
git clone https://github.com/digimotong/flac-health-reencode.git
cd flac-health-reencode
chmod +x flac_health_reencode.sh
./flac_health_reencode.sh
```

On first run, use option 3 to point the script at your music library.

## Menu

```
1) Full scan music library
2) Reencode problematic FLAC files (with local backups)
3) Set/Update default library path
4) Clean up FLAC backups
5) Reencode ALL FLAC files (with backups & warning)
6) Reencode NEW FLAC files only (skips already-reencoded)
7) Quit
```

Notes before picking a re-encode option:

- Options 2, 5 and 6 back up each original to a `backup_FLAC_originals/` folder
  next to it, then replace it with the re-encoded copy. Option 4 deletes those
  backup folders afterwards.
- The script never scans or re-encodes files inside its own
  `backup_FLAC_originals/` folders or the `.flac_scan_data/` directory.
- Option 5 re-encodes everything and asks you to confirm first. Expect it to be
  slow on a large library, and make sure there's disk space for the backups.
- Option 6 only processes files it hasn't recorded yet. Each successful
  re-encode records the file's FLAC audio MD5, size and mtime in
  `.flac_scan_data/reencoded.db`, so after an initial option 5 run you can use
  it to pick up newly added albums without re-encoding the whole library.

## Configuration

On first run the script creates `flac_health_config.json` next to itself.
Set the library path from the menu, or edit the file directly:

```json
{
  "library_path": "/path/to/music",
  "version": "1.0"
}
```

## What the script writes in your library

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

## Tests

`tests/` holds the integration and unit suite. It runs the real script against
throwaway sandboxes with stubbed `flac` and `metaflac` binaries, so no FLAC
tools are needed and nothing outside a sandbox is touched. The same suite runs
in CI (GitHub Actions) on every push.

```bash
bash tests/run_tests.sh
```

- Integration cases drive the interactive menu end to end: scan, re-encode from
  a scan report, re-encode all / new files, and backup cleanup.
- Unit cases source `flac_health_reencode.sh` (safe thanks to the `BASH_SOURCE`
  guard) and call helper functions directly.
- Assertions match short, stable output markers and real state changes (file
  contents, backups, `reencoded.db` rows), not full rendered output, so wording
  changes don't break the suite.
- If you change the `flac`/`metaflac` flags the script passes, update
  `tests/stub_flac` and `tests/stub_metaflac` to match.
- Break an assertion in a case to watch the suite fail. To run a single case:
  `TESTS_ROOT=tests PROD_SCRIPT=$PWD/flac_health_reencode.sh bash tests/case_scan.sh`
