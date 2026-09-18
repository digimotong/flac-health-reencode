# FLAC Health Check & Re-encode

Scans a FLAC music library for corrupted files, re-encodes them, and keeps a
backup of every original it replaces.

## Features

- Full-library scan for corrupted FLACs, written to a CSV report
- Re-encode just the reported files, the whole library, or only files that
  haven't been re-encoded before
- Original files mirrored into a backup directory outside the library
- Color-coded terminal output with progress tracking
- Per-run logs and a small JSON config file

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

```
1) Scan music library for errors
2) Reencode problematic FLAC files (from latest scan)
3) Set/Update library path & backup directory
4) Reencode ALL FLAC files (with backups & warning)
5) Reencode NEW FLAC files only
6) Quit
```

- Options 2, 4 and 5 mirror each original into the configured backup directory
  before replacing it with the re-encoded copy.
- The script never scans, re-encodes or backs up files inside its own
  `backup_FLAC_originals/` folders (legacy, see [Migration](#migration)) or its
  `.flac_scan_data/` directory.
- Option 4 re-encodes everything and asks you to confirm first. Expect it to be
  slow on a large library, and make sure there's disk space for the backups.
  Option 5 only processes files it hasn't recorded yet, so after an initial
  option 4 run you can use it to pick up newly added albums.

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
  looks like audio. Backups stored inside an album folder show up as a second
  copy of every track; outside the library they are ignored entirely.
- **One-place cleanup.** Verify your re-encodes, then delete the whole backup
  tree (`rm -rf /music_backup`) when you no longer need it. No per-album hunting.

Rules enforced by the script:

- The backup directory must be an **absolute** path. A bare relative answer (e.g.
  a stray `y` typed into the prompt) is refused instead of being resolved against
  the working directory and scattering backups unpredictably.
- The backup directory may not be the library, inside the library, or a parent of
  the library. All three would either destroy the originals or the library
  itself, so they are rejected with an explanation.
- Backups are never overwritten. If a backup already exists for a file, the
  existing one is kept (the pristine original survives re-runs) and the re-encode
  still proceeds.
- If a file cannot be backed up, it is **not** re-encoded. Nothing is re-encoded
  without a backup first — including files listed in a scan CSV that sit outside
  the library, which are skipped with a warning.
- The backup directory is created and write-probed *before* the first file is
  touched. A read-only or full destination aborts the run with nothing changed.

### When the backup directory is not set yet

If the config has no `backup_path`, the script suggests `<library>_backup` (a
sibling of the library):

- Option 2 and option 5 **ask** before using it, and store the answer you accept
  ("leave blank" accepts the suggestion).
- Option 4 does **not** interrupt: its warning panel prints the destination it
  will use and you confirm from there. Nothing is written to the config in this
  case, so the menu keeps showing the path as derived until you set one
  explicitly with option 3.

### Restoring an original

Copy the file back out of the backup tree, overwriting the re-encoded version:

```bash
cp -p /music_backup/2Pac/All\ Eyez\ on\ Me\ \(1996\)/01\ -\ Ambitionz.flac \
      "/music/2Pac/All Eyez on Me (1996)/01 - Ambitionz.flac"
```

To find every file a run touched, check the run log written to
`<library>/.flac_scan_data/logs/`: it records `Backup created for: <original> ->
<backup copy>` for each file.

## Migration

Older versions (config `version` `1.0`) wrote backups into a
`backup_FLAC_originals/` folder next to each album, inside the library. Those
copies are untouched by this version — they are still excluded from scans and
re-encodes, so they cannot be mistaken for real library content — but new backups
go to the configured backup directory instead.

To move an existing library over:

1. Set the new backup directory (option 3). The default suggestion is
   `<library>_backup`, a sibling of the library.
2. Move the old in-library backups into the new tree, preserving each album's
   relative path:

   ```bash
   cd /music
   find . -type d -name backup_FLAC_originals | while read -r d; do
       rel="${d%/backup_FLAC_originals}"
       mkdir -p "/music_backup/$rel"
       cp -p "$d"/*.flac "/music_backup/$rel/" 2>/dev/null
   done
   ```

3. Verify the copies, then remove the old folders:

   ```bash
   find /music -type d -name backup_FLAC_originals -exec rm -rf {} +
   ```

Leaving them in place is harmless — they are simply ignored — so this cleanup is
optional and can wait until you are confident in the new location.

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

- `backup_path` may be left empty or absent: the script then derives
  `<library_path>_backup` (a sibling of the library) and offers it as the default
  the first time you re-encode. Setting it explicitly is recommended when backup
  storage lives elsewhere, e.g. `/mnt/backup/music`.
- Both paths must be absolute, and trailing slashes are accepted on either.

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

Each successful re-encode records the file's FLAC audio MD5, size and mtime in
`.flac_scan_data/reencoded.db`, which is what option 5 uses to tell new files
from ones it has already processed.

## Troubleshooting

- `flac`, `metaflac` and `jq` are checked before the menu appears. A missing tool
  exits with status `1` and a message naming the command, so install it and run
  the script again.
- A file that fails to re-encode is logged as `FAILURE` and left untouched: the
  original is only replaced after the new copy is verified. Backups are never
  overwritten, so re-running an option over the same files cannot lose a pristine
  original — restore one as shown in [Backups](#backups).
- `Error: The backup directory cannot be inside the library (...)` means the two
  paths overlap. Pick a backup directory that is neither inside, equal to, nor a
  parent of the library path, then re-run.
- `Error: The backup directory must be an absolute path (...)` means a relative
  name reached the config, usually a mis-typed prompt answer. Set it again from
  option 3 with a full path such as `/mnt/backup/music`.
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
