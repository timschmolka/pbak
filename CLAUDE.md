# CLAUDE.md — pbak project guide

## Overview

**pbak** is a photo backup CLI that coordinates the full camera workflow:

1. **Dump** — SD card → SSD (EXIF date sort, SHA-256 dedup, sidecar support)
2. **Ingest** — Discover untracked files on SSD or import from external folder
3. **Upload** — SSD → Immich server (via immich-go, hash-level dedup tracking)
4. **Albums** — Lightroom Classic catalog → Immich albums, favorites, ratings, stacks
5. **Sync** — Primary SSD → Mirror SSD (additive rsync)
6. **Verify** — SHA-256 integrity check against hash DB (bit rot detection)
7. **Doctor** — Full health check (config, connectivity, deps, DB integrity)

The SSD is the source of truth for photo files. Immich and the mirror are downstream consumers — all syncs are one-way.

## Architecture

```
Camera → SD Card → [dump] → Primary SSD → [upload] → Immich Server
                                  ↓                      ↑
                              [sync]              [albums]
                                  ↓                      ↑
                            Mirror SSD          LrC Catalog
```

### Key assumptions

- **ARW ↔ DNG ↔ TIF relationship**: ARW 1:1 DNG, 1:N TIF, with unique DSC numberings. This is a known limitation.
- **Client-side dedup** is preferred whenever possible and feasible. Catalogs may have hundreds of thousands of photos — operations must scale.
- **Normalized stem matching** (`normalize_stem()` in immich.py) strips DxO suffixes, virtual copy numbers, and lowercases. TIF uses exact filename match. Format priority: TIF(1) > DNG(2) > RAW(3) > JPG(4) > HEIC(5).

## Project structure

```
bin/pbak              Entry point — flag parsing, command dispatch
lib/pbak/
  albums.py           Album sync engine (Python, stdlib only)
  albums.sh           Bash wrapper for albums.py
  config.sh           Config load/save/setup wizard, migration
  doctor.sh           Health check (config, connectivity, deps, DB integrity)
  dump.sh             SD → SSD copy with EXIF dating + hash dedup + sidecars
  hash.sh             SHA-256 hashing, database, upload status tracking, verify
  immich.py           Immich API utilities (stacking, upload verification)
  ingest.sh           Register untracked files, import from external folder
  sync.sh             rsync-based SSD mirroring
  ui.sh               Terminal UI (colors, spinners, prompts, select)
  upload.sh           SSD → Immich upload via immich-go
  utils.sh            Shared helpers (path checks, logging, deps, sidecar detection)
completions/
  pbak.zsh            Zsh tab completion
  pbak.bash           Bash tab completion
Makefile              install / uninstall / test / clean
```

## Build & test

```bash
make test        # Syntax checks (bash -n, py_compile) for all scripts
make install     # Install to /usr/local (PREFIX overridable)
make uninstall
```

Homebrew: `brew install timschmolka/pbak/pbak`

## Configuration

Stored at `~/.config/pbak/config` (chmod 600). Created by `pbak setup`.

### Root path variables

```bash
PBAK_SD_ROOT="/Volumes/T7/DCIM"          # or any path, e.g. /home/user/inbox
PBAK_SSD_ROOT="/Volumes/Samsung/full_dump"
PBAK_MIRROR_ROOT="/Volumes/Mirror/full_dump"
```

All CLI flags (`--sd`, `--ssd`, `--from`, `--to`) accept either:
- A full path starting with `/` — used as-is
- A bare volume name (e.g. `T7`) — expanded to `/Volumes/<name>/<default_subfolder>`

Detection via `utils_resolve_override()`.

### Migration

Old config using `PBAK_SD_VOLUME` / `PBAK_SSD_VOLUME` / `PBAK_MIRROR_VOLUME` + `PBAK_SD_PATH` / `PBAK_SSD_PATH` is auto-migrated in `config_load()` to the new `*_ROOT` vars.

### Other settings

- `PBAK_IMMICH_SERVER`, `PBAK_IMMICH_API_KEY` — Immich connection
- `PBAK_DUMP_EXTENSIONS_INCLUDE/EXCLUDE` — file extension filters for dump
- `PBAK_UPLOAD_EXTENSIONS_INCLUDE/EXCLUDE` — file extension filters for upload
- `PBAK_CONCURRENT_TASKS` — parallel upload workers (1–20, default 4)
- `PBAK_UPLOAD_PAUSE_JOBS` — pause Immich background jobs during upload
- `PBAK_LRC_CATALOG` — path to `.lrcat` file for album sync

## Hash database

File: `~/.config/pbak/hashes.db` — 6-column TSV:

```
<sha256>\t<source_path>\t<dest_path>\t<timestamp>\t<file_size_bytes>\t<uploaded_ts>
```

- Column 6 (`uploaded_ts`) tracks per-file upload status. Empty = not uploaded.
- `hash_add()` writes 6 columns (trailing `\t` for empty col 6).
- `hash_rebuild()` preserves upload status from old DB before overwriting. Respects `DRY_RUN`. Validates success (>50% hashed, non-empty result) before replacing DB — old DB preserved on failure.
- `hash_mark_uploaded()` sets column 6 for all files in a folder.

## Upload state

Two tracking layers:
- **Hash DB column 6** — per-file upload status (primary, hash-level dedup)
- **uploads.log** — per-folder upload status (legacy, kept for folder-level summary)

One-time migration (`_upload_migrate_to_hash_db`) seeds hash DB from uploads.log.

## Coding conventions

- **Bash**: `set -euo pipefail`, functions namespaced by module (`hash_*`, `dump_*`, `upload_*`)
- **UI output**: all user-facing output goes to stderr via `ui_*` functions
- **Python**: stdlib only (no pip dependencies), UI via stderr to match bash style
- **Atomic file ops**: tempfile + `mv` pattern for DB writes
- **Global flags**: `DRY_RUN`, `VERBOSE`, and `QUIET` exported from `bin/pbak`. All write operations must check `utils_is_dry_run()`. `QUIET` suppresses `ui_header`, `ui_success`, `ui_info`, `ui_dim`, `ui_progress`, `ui_spinner` — errors and warnings always shown. Python scripts receive `PBAK_DRY_RUN`, `PBAK_VERBOSE`, and `PBAK_QUIET` via environment.
- **File operations**: `utils_ensure_dir` respects `DRY_RUN`
- **Path handling**: never hardcode `/Volumes/`; use `utils_resolve_override()` for CLI overrides, `PBAK_*_ROOT` config vars for defaults
- **Sidecars**: `.xmp`, `.dop`, `.pp3` detected via `utils_find_sidecars()` by stem matching. Copied alongside primary files in dump and ingest. `.xmp` included in upload defaults (Immich supports it).

## Release process

1. Bump `PBAK_VERSION` in `bin/pbak`
2. `make test`
3. `git add -A && git commit -m "vX.Y.Z: ..."`
4. `git tag vX.Y.Z && git push && git push --tags`
5. Get tarball SHA: `curl -sL https://github.com/timschmolka/pbak/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256`
6. Update `homebrew-pbak/Formula/pbak.rb` — version URL + sha256
7. `cd ../homebrew-pbak && git add -A && git commit && git push`
