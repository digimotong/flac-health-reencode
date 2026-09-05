# FLAC Health Check & Re-encode Utility

A robust Bash script for scanning and repairing FLAC audio files while preserving metadata and creating backups.

## Features

- Recursive scanning of FLAC files for corruption
- Safe re-encoding of problematic files with backup preservation
- Detailed CSV reports and operation logs
- Color-coded terminal output with progress tracking
- Persistent configuration via JSON file
- Backup cleanup utility
- Reencode "new" files only, via a persistent MD5+sizes tracking database

## Installation

1. Ensure you have the required dependencies:
   ```bash
   sudo apt-get install flac jq  # Debian/Ubuntu (metaflac ships with 'flac')
   brew install flac jq         # macOS
   ```

2. Download the script:
   ```bash
   git clone https://github.com/digimotong/flac-health-reencode.git
   cd flac-health-reencode
   ```

3. Make the script executable:
   ```bash
   chmod +x flac_health_reencode.sh
   ```

## Usage

Run the script and follow the interactive menu:
```bash
./flac_health_reencode.sh
```

### Menu Options:
1. **Full scan music library** - Checks all real FLAC files for errors (excludes the script's own `backup_FLAC_originals` copies and the `.flac_scan_data` tracking dir)
2. **Reencode problematic FLAC files** - Fixes corrupted files (creates backups); skips any CSV row that points into `backup_FLAC_originals` or `.flac_scan_data`
3. **Set/Update default library path** - Configure your music library location
4. **Clean up FLAC backups** - Remove backup files after verification
5. **Reencode ALL FLAC files** - Reencodes every real FLAC file (excludes the script's own `backup_FLAC_originals` copies and the `.flac_scan_data` tracking dir; with backups & warning)
6. **Reencode NEW FLAC files only** - Reencodes only files that have never been reencoded (excludes `backup_FLAC_originals` and `.flac_scan_data`)
7. **Quit**

> **Note on "Reencode NEW FLAC files only":** After a successful reencode the
> script records the file's FLAC audio MD5 + file size in
> `<library>/.flac_scan_data/reencoded.db`. The "new files" option skips any file
> already recorded, so newly added albums — or albums you deleted and
> re-downloaded later — are correctly processed without you having to re-run the
> expensive "Reencode ALL" option each time.

## Configuration

The script automatically creates a configuration file (`flac_health_config.json`) in its directory. You can:
- Set the default library path through the menu
- Manually edit the JSON file:
  ```json
  {
    "library_path": "/path/to/your/music",
    "version": "1.0"
  }
  ```

## File Structure

The script creates the following structure in your music library:
```
.music_library/
└── .flac_scan_data/
    ├── reports/         # CSV scan reports
    ├── logs/            # Operation logs
    └── reencoded.db     # Tracking DB of successfully reencoded files
```

For each re-encoded file, a backup is stored in:
```
album_folder/
└── backup_FLAC_originals/
    └── original_file.flac
```
