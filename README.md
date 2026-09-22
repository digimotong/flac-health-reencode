# FLAC Health Check & Re-encode

Scans a FLAC music library for corrupted files, re-encodes them, and keeps a
backup of every original it replaces.

## Features

- **Health scanning**: runs `flac -t` over the whole library and writes the
  failures to a timestamped CSV report
- **Three re-encode modes**:
  - the files listed in the latest scan report
  - every FLAC file in the library (with a confirmation prompt)
  - only files that have not been re-encoded before
- **Backups outside the library**: each original is mirrored into a backup
  directory that copies the library's layout, so no media scanner ever indexes a
  backup as a duplicate track
- **Safe by default**: a file is only replaced after the new copy has been
  verified, and never without a backup first; unsafe backup destinations are
  refused
- **Lossless re-encode**: `flac --verify --decode-through-errors` with
  `--preserve-modtime`, so timestamps survive
- **Resumable tracking**: successful re-encodes are recorded by FLAC audio MD5,
  size and mtime in `.flac_scan_data/reencoded.db`
- **Reporting**: color-coded progress, per-run logs, and a small JSON config

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
does. The menu also prints the active library and backup directory, and accepts
`q` as a shortcut for quitting.

| Option | Action | Notes |
|--------|--------|-------|
| `1` | Scan music library for errors | Read-only. Writes a CSV report; changes no audio file. |
| `2` | Reencode problematic FLAC files | Acts on the latest scan report. Mirrors each original into the backup directory first. |
| `3` | Set/Update library path & backup directory | First-run setup. Validates that the backup destination is safe. |
| `4` | Reencode ALL FLAC files | Confirmed by typing `REENCODE ALL`. Slow on a large library — check free disk space for the backups first. |
| `5` | Reencode NEW FLAC files only | Skips files already recorded in the tracking database. Use it after an option 4 run to pick up newly added albums. |
| `6` | Quit | Same as `q`. |

Options 2, 4 and 5 always mirror each original into the configured backup
directory before replacing it with the re-encoded copy.

Files inside the script's own `backup_FLAC_originals/` folders (in-library
backups written by older versions) and its `.flac_scan_data/` directory are never
scanned, re-encoded or backed up.

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

## Backups

**Backups live outside the library.** The backup directory mirrors the library's
layout, so a file at `<library>/2Pac/All Eyez on Me (1996)/01 - Ambitionz.flac`
is backed up to `<backup>/2Pac/All Eyez on Me (1996)/01 - Ambitionz.flac`.

```
/music/                              /music_backup/
├── 2Pac/                            ├── 2Pac/
│   └── All Eyez on Me (1996)/       │   └── All Eyez on Me (1996)/
│       └── 01 - Ambitionz.flac  ──► │       └── 01 - Ambitionz.flac
└── .flac_scan_data/                 └── (backup tree only)
```

Keeping originals out of the library has two practical benefits:

- **No duplicate tracks.** Plex, Roon, Navidrome and friends index anything that
  looks like audio; backups stored outside the library are ignored entirely.
- **One-place cleanup.** Verify your re-encodes, then delete the whole backup
  tree (`rm -rf /music_backup`) when you no longer need it.

Rules enforced by the script:

| Rule | Behavior |
|------|----------|
| Absolute path required | A relative answer (e.g. a stray `y` typed into the prompt) is refused instead of being resolved against the working directory and scattering backups unpredictably. |
| No overlap with the library | The backup directory may not be the library, inside it, or a parent of it — all three would destroy the originals or the library — so they are rejected with an explanation. |
| Backups are never overwritten | If a backup already exists for a file, the existing one is kept so the pristine original survives re-runs; the re-encode still proceeds. |
| No backup, no re-encode | If a file cannot be backed up it is not re-encoded — including files listed in a scan CSV that sit outside the library, which are skipped with a warning. |
| Created only once you commit | The destination is created and write-probed *before* the first file is touched, and only after you confirm the run, so cancelling leaves no stray directory. A read-only or full destination aborts with nothing changed. Missing parent directories are created as needed. |

### When the backup directory is not set yet

If the config has no `backup_path`, the script suggests `<library>_backup` (a
sibling of the library). Options 2 and 5 **ask** before using it and store the
answer you accept, showing the suggestion as the prompt's default; option 4 does
**not** interrupt, and only prints the destination in its warning panel. In every
case nothing is written to the config here, so the menu keeps showing the path as
derived until you set one explicitly with option 3.

### Restoring an original

Copy the file back out of the backup tree, overwriting the re-encoded version:

```bash
cp -p /music_backup/2Pac/All\ Eyez\ on\ Me\ \(1996\)/01\ -\ Ambitionz.flac \
      "/music/2Pac/All Eyez on Me (1996)/01 - Ambitionz.flac"
```

To find every file a run touched, check the run log written to
`<library>/.flac_scan_data/logs/`: it records `Backup created for: <original> ->
<backup copy>` for each file.

## What the Script Writes in Your Library

```
<library>/
├── Artist/Album/
│   └── song.flac
└── .flac_scan_data/
    ├── reports/                 # CSV scan reports
    ├── logs/                    # per-run re-encode logs
    └── reencoded.db             # fingerprints of re-encoded files
```

Re-encoded originals are **not** written here; they go to the backup directory
described in [Backups](#backups).

## Troubleshooting

- `flac`, `metaflac` and `jq` are checked before the menu appears. A missing
  tool exits with status `1` and a message naming the command, so install it and
  run the script again.
- A file that fails to re-encode is logged as `FAILURE` and left untouched: the
  original is only replaced after the new copy is verified, and it can be
  restored from the backup tree (see [Backups](#backups)).
- `Error: The backup directory cannot be inside the library (...)` or `Error: The
  backup directory must be an absolute path (...)` means the destination is
  relative or overlaps the library. See [Backups](#backups) for the rules and
  pick a path that is neither inside, equal to, nor a parent of the library.
- Scan reports and per-run logs live in `.flac_scan_data/` inside your library,
  so a failed run can be reviewed after the fact.

## Development

Requires Bash 4.0+, `jq`, and `shellcheck` for linting.

```bash
bash tests/run_tests.sh                # test suite
bash tests/lint.sh                     # shellcheck
```

The suite drives the real script inside throwaway sandboxes with stubbed `flac`
and `metaflac` binaries, so it needs no FLAC tools and touches nothing outside a
sandbox. It runs in CI on every push and pull request. If you change the
`flac`/`metaflac` flags the script passes, update `tests/stub_flac` and
`tests/stub_metaflac` to match.

## Requirements

- Bash 4.0+ (the script uses associative arrays)
- `flac` (which also provides `metaflac`) and `jq`

```bash
# Debian / Ubuntu
sudo apt-get install flac jq

# macOS
brew install flac jq
```
