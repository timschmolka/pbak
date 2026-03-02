# pbak

Photo backup utility for a two-step workflow: **SD card → SSD → Immich**.

Wraps [immich-go](https://github.com/simulot/immich-go) with interactive path/volume selection, EXIF-based date organization, SHA-256 deduplication, SSD mirroring, upload state tracking, and Lightroom Classic integration.

Storage paths are fully configurable — works with external SSDs, internal folders, NAS mounts, or any directory.

## Architecture

```
                              ┌──────────────────────────────────┐
                              │          Immich Server            │
                              │  ┌────────┐ ┌───────┐ ┌───────┐ │
                              │  │ Assets │ │Albums │ │Stacks │ │
                              │  └───▲────┘ └───▲───┘ └───▲───┘ │
                              └──────┼──────────┼─────────┼─────┘
                                     │          │         │
                               upload│   albums │   albums│
                            immich-go│  REST API│  REST API
                                     │          │         │
┌──────────┐   dump    ┌─────────────┴──┐  ┌────┴─────────┴──┐
│ SD Card  │ ────────▶ │  Primary SSD   │  │  LrC Catalog    │
│          │  exiftool │  YYYY/MM/DD/   │  │  (.lrcat)       │
└──────────┘  sha-256  │  DSC0001.ARW   │  │  Collections    │
                       │                │  │  Picks/Ratings  │
                       └───────┬────────┘  └─────────────────┘
                        sync   │ rsync
                       ┌───────▼────────┐
                       │  Mirror SSD    │
                       └────────────────┘
```

### Source of Truth

| Data | Source of Truth | Direction |
|------|----------------|-----------|
| Photo files (RAW, TIF, DNG) | Primary SSD | SSD → Immich (upload) |
| Date folder structure | Primary SSD | SSD → Immich |
| Hash dedup database | `~/.config/pbak/hashes.db` | Local only |
| Upload state tracking | `~/.config/pbak/hashes.db` col 6 + `uploads.log` | Local only |
| Albums / collections | LrC catalog | LrC → Immich (one-way, promoted to best format) |
| Picks → favorites | LrC catalog | LrC → Immich (one-way) |
| Star ratings | LrC catalog | LrC → Immich (one-way) |
| File stacking | Immich (derived from filename stems) | Computed at sync time, merged incrementally |
| Mirror SSD | Primary SSD | Primary → Mirror (one-way, additive) |

All syncs are **one-way**. Immich and the mirror SSD are treated as downstream consumers — they never write back to the SSD or LrC catalog.

### Data Flow

```
1. SHOOT     Camera ──▶ SD Card

2. DUMP      SD Card ──▶ SSD (EXIF date sort, SHA-256 dedup)
                  └────▶ Mirror SSD (auto-sync if mounted)

3. INGEST    LrC/DxO exports land next to RAWs on SSD
             pbak ingest ──▶ discovers + registers untracked files

4. UPLOAD    SSD ──────▶ Immich (via immich-go, per-folder state tracking)

5. ORGANIZE  LrC ──────▶ Immich (collections → albums, picks → favs,
                                  ratings, stacking)
```

### File Lifecycle

A single photo may exist as multiple files at different processing stages:

```
DSC04883.ARW                     ← Camera RAW (original)
DSC04883-DxO_DeepPRIME XD2s.dng  ← DxO PureRAW (direct)
20260302-DSC04883.dng             ← DxO PureRAW (LrC plugin, date-prefixed)
DSC04883.tif                     ← LrC export (final edit)
```

All variants are uploaded to Immich independently. Both `pbak upload` and `pbak albums` group them by normalizing the filename stem — stripping DxO suffixes (`-DxO_*`), date prefixes (`YYYYMMDD-`), and virtual copy numbers (`-N`) — and create a stack with format priority:

```
TIF (1) > DNG (2) > RAW (3) > JPG (4) > HEIC (5)
```

The highest-priority format becomes the stack cover in Immich. Album references are automatically promoted to the best format — if LrC has the ARW in a collection but a TIF exists, the album points to the TIF. Immich stacking groups the siblings automatically.

## Install

### macOS (Homebrew)

```bash
brew install timschmolka/pbak/pbak
```

### From source (any platform)

```bash
git clone https://github.com/timschmolka/pbak.git
cd pbak
sudo make install
```

### Dependencies

- **Required**: bash 4+, exiftool, openssl, rsync, curl
- **Required for upload**: [immich-go](https://github.com/simulot/immich-go)
- **Required for albums/stacking**: python3 (stdlib only, no pip packages)

## Quick Start

```bash
# 1. Configure Immich server, storage paths, extensions
pbak setup

# 2. Copy photos from SD card to SSD (YYYY/MM/DD structure)
pbak dump

# 3. Upload from SSD to Immich
pbak upload --all

# 4. Sync LrC collections to Immich albums
pbak albums
```

## Commands

| Command | Description |
|---------|-------------|
| `pbak setup` | Interactive configuration wizard |
| `pbak dump` | Copy SD → SSD with hash-based deduplication |
| `pbak upload` | Upload SSD → Immich via immich-go |
| `pbak status` | Show config, backup stats, upload state |
| `pbak sync` | Sync primary SSD to a mirror SSD |
| `pbak albums` | Sync Lightroom Classic collections to Immich albums |
| `pbak ingest` | Register untracked files or import from external folder |
| `pbak rehash` | Rebuild hash database from existing SSD files |
| `pbak verify` | Check SSD file integrity against hash database |
| `pbak doctor` | Run health checks on your pbak setup |

### Global Flags

- `--dry-run` — preview without making changes
- `--verbose` — detailed logging
- `--quiet` / `-q` — suppress informational output (errors and warnings only)
- `--version` — print version

### Ingest Flags

- `--from <path>` — source folder to import from (omit to scan SSD)
- `--ssd <path>` — override SSD dump root (path or volume name)
- `--move` — move files instead of copy (import mode only)
- `--no-sidecars` — skip sidecar detection (.xmp, .dop, .pp3)

### Dump Flags

- `--sd <path>` — override SD card source (path or volume name)
- `--ssd <path>` — override SSD dump root (path or volume name)

### Upload Flags

- `--ssd <path>` — override SSD dump root (path or volume name)
- `--date <YYYY/MM/DD>` — upload specific date folder
- `--all` — upload all pending folders
- `--retry-failed` — retry previously failed uploads
- `--force` — re-upload all folders (immich-go skips server-side duplicates)

### Sync Flags

- `--from <path>` — primary SSD root (path or volume name)
- `--to <path>` — mirror SSD root (path or volume name)

### Albums Flags

- `--collection <name>` — sync a single collection by name
- `--no-metadata` — skip pick/rating metadata sync
- `--no-stacks` — skip file stacking
- `--prune` — remove assets from Immich albums that are no longer in LrC

### Rehash Flags

- `--ssd <path>` — override SSD dump root (path or volume name)

### Verify Flags

- `--ssd <path>` — override SSD dump root (path or volume name)

## How It Works

### Dump (SD → SSD)

1. Scans SD card source directory for matching file extensions (excludes macOS `._*` resource forks)
2. Extracts photo date from EXIF metadata (DateTimeOriginal → CreateDate → FileModifyDate → filesystem date)
3. Computes SHA-256 hash and checks against local database
4. Copies new files to `full_dump/YYYY/MM/DD/` on SSD
5. Verifies copy integrity with hash comparison
6. Records hash in database for future deduplication
7. Detects and copies sidecar files (.xmp, .dop, .pp3) alongside their primary files
8. If a mirror SSD is configured and mounted, automatically syncs to it
9. Offers to eject the SD card (macOS, when source is a mounted volume)

### Ingest (Discover & Register)

**Scan mode** (default — no `--from` flag):
1. Scans the SSD for files matching extension filters
2. Compares against hash database to find untracked files
3. Hashes and registers each file in-place (no copying)
4. Detects and registers sidecar files (.xmp, .dop, .pp3)

**Import mode** (`--from <path>`):
1. Scans source folder for matching files
2. Extracts EXIF date and copies/moves to `YYYY/MM/DD/` on SSD
3. Hash-deduplicates against existing database
4. Copies sidecar files alongside their primary files
5. If a mirror SSD is configured and mounted, automatically syncs

**Recommended LrC workflow**: Export with destination "Same folder as original photo" so TIFs land next to their RAW originals. Then `pbak ingest` registers them.

### Upload (SSD → Immich)

1. **Delta detection**: bulk-stats all SSD files (~1-2s), compares sizes against the hash DB, re-hashes any overwritten files (re-exports, re-edits) and queues them for re-upload
2. Lists date folders on SSD, checks hash DB for per-file upload status (column 6)
3. Shows summary of new vs already-uploaded files per folder
4. Stages only new files into a temp directory, runs `immich-go upload from-folder --recursive`
5. immich-go handles server-side deduplication (SHA1 pre-check)
6. Marks uploaded file hashes in the DB so they're skipped next time
7. Stacks related files (TIF/DNG/ARW) on Immich by normalized filename stem

### Sync (SSD → Mirror SSD)

1. One-way additive sync using rsync (`--ignore-existing`)
2. Copies new files from primary SSD to mirror — nothing is ever deleted from mirror
3. Runs automatically after `pbak dump` if mirror SSD is configured and mounted

### Verify (Integrity Check)

1. Reads all file paths from the hash database under the SSD root
2. Re-computes SHA-256 hashes in parallel
3. Compares against stored hashes — reports any mismatches (possible bit rot)
4. Also reports files tracked in the DB but missing from disk

### Doctor (Health Check)

Runs diagnostics across the full setup:
- Configuration completeness
- Immich server connectivity and API key validity
- Dependency availability (immich-go, exiftool, python3, etc.)
- Storage path accessibility and write permissions
- Hash database integrity (column count, orphaned entries, untracked files)
- LrC catalog reachability

### Albums (LrC → Immich)

```
┌─────────────────────────────────────────────────────────────────┐
│  Phase 1 — Index    Fetch all Immich assets, build filename map │
│  Phase 2 — Collect  Read LrC regular + smart collections       │
│  Phase 3 — Albums   Match files → create/update Immich albums  │
│  Phase 4 — Meta     Picks → favorites, ratings 1–5             │
│  Phase 5 — Stacks   Group by stem, set format-priority cover   │
└─────────────────────────────────────────────────────────────────┘
```

1. Reads regular and smart collections from the LrC catalog (SQLite)
2. Fetches all Immich assets and builds a filename-based index (own assets only)
3. Matches LrC files to Immich assets by `originalFileName`, with stem-based fallback for renamed exports (e.g., date-prefixed DxO PureRAW files)
4. **Promotes album references** to the best available format — if a collection contains `DSC04027.ARW` but a `DSC04027.tif` also exists in Immich, the album points to the TIF
5. Creates or updates Immich albums for each collection
6. Syncs LrC picks → Immich favorites and LrC star ratings → Immich ratings
7. Stacks related files (TIF/DNG/ARW) by normalized filename stem. Merges into existing partial stacks when new formats are added.
8. Idempotent — safe to run repeatedly without duplicating albums or assets

### Smart Collection Support

`pbak albums` parses Lightroom's smart collection rules (stored as Lua tables in the catalog) and translates them to SQL queries. Supported criteria:

| Criteria | Operations |
|----------|-----------|
| Capture time | before, after, equals, in last N days/months |
| Pick flag | picked, unflagged, rejected |
| Star rating | equals, greater-or-equal |
| File format | RAW, TIFF, JPG, HEIC, VIDEO |
| Keywords | contains, is empty |
| Focal length | less than, greater than |
| Color label | Red, Yellow, Green, Blue, Purple |
| Touch time | modified in last N days/months |

Smart collections with `intersect` or `union` combine modes are both supported.

## Project Structure

```
pbak/
├── bin/pbak              # Entry point — flag parsing, command dispatch
├── lib/pbak/
│   ├── albums.py         # Album sync engine (Python, stdlib only)
│   ├── albums.sh         # Bash wrapper for albums.py
│   ├── config.sh         # Config load/save/setup wizard
│   ├── doctor.sh         # Health check (config, connectivity, deps, DB)
│   ├── dump.sh           # SD → SSD copy with EXIF dating + dedup
│   ├── hash.sh           # SHA-256 hashing, database, verify, upload tracking
│   ├── immich.py         # Immich API utilities (stacking, upload verification)
│   ├── ingest.sh         # Register untracked files, import from external
│   ├── sync.sh           # rsync-based SSD mirroring
│   ├── ui.sh             # Terminal UI (colors, spinners, prompts)
│   ├── upload.sh         # SSD → Immich upload via immich-go
│   └── utils.sh          # Shared helpers (platform detection, paths, logging)
├── completions/
│   ├── pbak.zsh          # Zsh tab completion
│   └── pbak.bash         # Bash tab completion
├── Makefile              # Install / uninstall / test / clean
└── README.md
```

## Configuration

All state is stored under `~/.config/pbak/`:

| File | Purpose |
|------|---------|
| `config` | Settings (created by `pbak setup`) |
| `hashes.db` | SHA-256 hash database (6-column TSV) |
| `uploads.log` | Per-folder upload status log |

Key settings:
- Immich server URL and API key
- **Storage paths**: SD source root (`PBAK_SD_ROOT`), SSD dump root (`PBAK_SSD_ROOT`), mirror root (`PBAK_MIRROR_ROOT`) — any directory path works
- File extension include/exclude lists (separate for dump and upload)
- Concurrent upload tasks, pause jobs setting
- Lightroom Classic catalog path (`.lrcat` file)

All path flags (`--sd`, `--ssd`, `--from`, `--to`) accept either a full path (`/some/dir`) or a bare volume name (`T7`, expanded to `/Volumes/T7/<subfolder>`). Old configs using volume-name variables are auto-migrated.

## Dependencies

Automatically checked and offered for install via Homebrew:

- [immich-go](https://github.com/simulot/immich-go) — Immich upload client
- [exiftool](https://exiftool.org/) — EXIF metadata extraction
- `python3` — required for `pbak albums` and `pbak upload` stacking/verification (uses only stdlib)
- `openssl` — SHA-256 hashing
- `rsync` — SSD mirroring
- `curl` — Immich API connectivity checks

On macOS, missing deps are auto-offered for install via Homebrew. On Linux, install them via your package manager.

## License

MIT
