#!/usr/bin/env python3
"""pbak albums — Sync Lightroom Classic collections to Immich albums.

Reads collections from a LrC catalog (.lrcat), matches files to Immich
assets by originalFileName, creates/updates albums, syncs metadata
(picks → favorites, ratings), and stacks related files (TIF/DNG/ARW).
"""

import json
import os
import re
import sqlite3
import sys
import time
import urllib.request
import urllib.error
from collections import defaultdict
from pathlib import Path

# ── UI helpers (match pbak bash style) ────────────────────────────────────

_ISATTY = sys.stderr.isatty()
_B = "\033[1m" if _ISATTY else ""
_D = "\033[2m" if _ISATTY else ""
_R = "\033[0m" if _ISATTY else ""
_RED = "\033[31m" if _ISATTY else ""
_GREEN = "\033[32m" if _ISATTY else ""
_YELLOW = "\033[33m" if _ISATTY else ""
_BLUE = "\033[34m" if _ISATTY else ""


QUIET = False

def header(msg):
    if QUIET: return
    print(f"\n{_B}{_BLUE}▸ {msg}{_R}")
    print(f"{_D}{'─' * 60}{_R}")

def success(msg):
    if QUIET: return
    print(f"{_GREEN}✓{_R} {msg}")
def error(msg):    print(f"{_RED}✗{_R} {msg}", file=sys.stderr)
def warn(msg):     print(f"{_YELLOW}!{_R} {msg}", file=sys.stderr)
def info(msg):
    if QUIET: return
    print(f"{_BLUE}·{_R} {msg}")
def dim(msg):
    if QUIET: return
    print(f"{_D}{msg}{_R}")
def debug(msg):
    if VERBOSE:
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        print(f"{ts} [DEBUG] {msg}", file=sys.stderr)


# ── Immich API ────────────────────────────────────────────────────────────

class ImmichAPI:
    def __init__(self, server: str, api_key: str, dry_run: bool = False):
        self.server = server.rstrip("/")
        self.api_key = api_key
        self.dry_run = dry_run

    def _request(self, method: str, endpoint: str, data=None, readonly=False):
        if method != "GET" and not readonly and self.dry_run:
            debug(f"[dry-run] {method} {endpoint}")
            return None

        url = f"{self.server}{endpoint}"
        body = json.dumps(data).encode() if data else None
        req = urllib.request.Request(url, data=body, method=method, headers={
            "x-api-key": self.api_key,
            "Content-Type": "application/json",
            "Accept": "application/json",
        })

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read()) if resp.status != 204 else None
        except urllib.error.HTTPError as e:
            body_text = e.read().decode()[:300] if e.fp else ""
            debug(f"API {method} {endpoint} returned {e.code}: {body_text}")
            raise
        except urllib.error.URLError as e:
            error(f"Connection failed: {e.reason}")
            raise

    def get_my_user_id(self) -> str:
        resp = self._request("GET", "/api/users/me")
        return resp["id"]

    def build_asset_index(self, owner_id: str = "") -> dict[str, list[dict]]:
        """Fetch all assets, return {originalFileName: [asset_dicts]}.
        If owner_id is set, only include assets owned by that user."""
        index = defaultdict(list)
        page = 1
        skipped = 0
        while True:
            resp = self._request("POST", "/api/search/metadata",
                                 {"page": page, "size": 1000}, readonly=True)
            items = resp.get("assets", {}).get("items", [])
            debug(f"Fetched page {page}: {len(items)} assets")
            for a in items:
                if owner_id and a.get("ownerId") != owner_id:
                    skipped += 1
                    continue
                index[a["originalFileName"]].append(a)
            if len(items) < 1000:
                break
            page += 1
        total = sum(len(v) for v in index.values())
        debug(f"Asset index: {total} assets (skipped {skipped} from other users)")
        return dict(index)

    def albums_list(self) -> list[dict]:
        return self._request("GET", "/api/albums") or []

    def album_create(self, name: str) -> dict:
        return self._request("POST", "/api/albums", {"albumName": name})

    def album_get(self, album_id: str) -> dict:
        return self._request("GET", f"/api/albums/{album_id}")

    def album_add_assets(self, album_id: str, ids: list[str]):
        return self._request("PUT", f"/api/albums/{album_id}/assets", {"ids": ids})

    def album_remove_assets(self, album_id: str, ids: list[str]):
        return self._request("DELETE", f"/api/albums/{album_id}/assets", {"ids": ids})

    def assets_set_favorite(self, ids: list[str], favorite: bool):
        return self._request("PUT", "/api/assets", {"ids": ids, "isFavorite": favorite})

    def assets_set_rating(self, ids: list[str], rating: int):
        return self._request("PUT", "/api/assets", {"ids": ids, "rating": rating})

    def stack_create(self, primary_id: str, other_ids: list[str]):
        # First asset becomes the stack cover (primary)
        all_ids = [primary_id] + other_ids
        return self._request("POST", "/api/stacks",
                             {"assetIds": all_ids})

    def stacks_list(self) -> list[dict]:
        return self._request("GET", "/api/stacks") or []


# ── LrC Catalog Reader ───────────────────────────────────────────────────

class LrCCatalog:
    def __init__(self, path: str):
        self.path = path
        self.conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        self.conn.row_factory = sqlite3.Row

    def close(self):
        self.conn.close()

    def list_collections(self) -> list[dict]:
        rows = self.conn.execute("""
            SELECT c.id_local AS id, c.name,
                   CASE c.creationId
                       WHEN 'com.adobe.ag.library.collection' THEN 'regular'
                       WHEN 'com.adobe.ag.library.smart_collection' THEN 'smart'
                   END AS type,
                   COALESCE(p.name, '') AS parent_name
            FROM AgLibraryCollection c
            LEFT JOIN AgLibraryCollection p ON c.parent = p.id_local
            WHERE c.creationId IN (
                'com.adobe.ag.library.collection',
                'com.adobe.ag.library.smart_collection'
            )
            AND c.systemOnly != '1.0'
            AND c.name != 'quick collection'
            ORDER BY c.name
        """).fetchall()
        return [dict(r) for r in rows]

    def collection_files(self, collection_id: int) -> list[dict]:
        rows = self.conn.execute("""
            SELECT f.originalFilename AS filename,
                   COALESCE(i.pick, 0) AS pick,
                   COALESCE(i.rating, 0) AS rating,
                   i.fileFormat AS fileformat
            FROM AgLibraryCollectionImage ci
            JOIN Adobe_images i ON i.id_local = ci.image
            JOIN AgLibraryFile f ON f.id_local = i.rootFile
            WHERE ci.collection = ?
        """, (collection_id,)).fetchall()
        return [dict(r) for r in rows]

    def smart_collection_files(self, collection_id: int) -> list[dict]:
        row = self.conn.execute("""
            SELECT content FROM AgLibraryCollectionContent
            WHERE collection = ? AND content LIKE 's = %'
        """, (collection_id,)).fetchone()

        if not row:
            debug(f"No smart rules for collection {collection_id}")
            return []

        content = row[0]
        rules, combine = self._parse_smart_rules(content)
        if not rules:
            debug(f"Could not parse rules for collection {collection_id}")
            return []

        where_clauses = []
        needs_exif = False
        for r in rules:
            clause = self._rule_to_sql(r)
            if clause:
                where_clauses.append(clause)
            if r["criteria"] == "focalLength":
                needs_exif = True

        if not where_clauses:
            return []

        joiner = " AND " if combine == "intersect" else " OR "
        where = joiner.join(f"({c})" for c in where_clauses)
        joins = "LEFT JOIN AgHarvestedExifMetadata exif ON exif.image = i.id_local" if needs_exif else ""

        rows = self.conn.execute(f"""
            SELECT f.originalFilename AS filename,
                   COALESCE(i.pick, 0) AS pick,
                   COALESCE(i.rating, 0) AS rating,
                   i.fileFormat AS fileformat
            FROM Adobe_images i
            JOIN AgLibraryFile f ON f.id_local = i.rootFile
            {joins}
            WHERE {where}
        """).fetchall()
        return [dict(r) for r in rows]

    def resolve_collection(self, coll_id: int, coll_type: str) -> list[dict]:
        if coll_type == "regular":
            return self.collection_files(coll_id)
        elif coll_type == "smart":
            return self.smart_collection_files(coll_id)
        return []

    # ── Smart collection rule parsing ─────────────────────────────────

    @staticmethod
    def _parse_smart_rules(content: str) -> tuple[list[dict], str]:
        rules = []
        combine = "intersect"

        combine_m = re.search(r'combine\s*=\s*"(\w+)"', content)
        if combine_m:
            combine = combine_m.group(1)

        # Match each { ... } block
        for block in re.finditer(r'\{([^{}]+)\}', content):
            text = block.group(1)
            rule = {}
            for key in ("criteria", "operation", "value", "value2", "value_units"):
                # Try string value first, then numeric
                m = re.search(rf'{key}\s*=\s*"([^"]*)"', text)
                if m:
                    rule[key] = m.group(1)
                else:
                    m = re.search(rf'{key}\s*=\s*(-?[\d.]+)', text)
                    if m:
                        rule[key] = m.group(1)
            if "criteria" in rule:
                rules.append(rule)

        return rules, combine

    @staticmethod
    def _rule_to_sql(rule: dict) -> str | None:
        criteria = rule.get("criteria", "")
        op = rule.get("operation", "")
        val = rule.get("value", "")
        val2 = rule.get("value2", "")
        units = rule.get("value_units", "")

        if criteria == "captureTime":
            if op == ">":    return f"i.captureTime > '{val}'"
            if op == "<":    return f"i.captureTime < '{val}'"
            if op == "==":   return f"i.captureTime >= '{val}' AND i.captureTime < date('{val}', '+1 day')"
            if op == "inLast": return f"i.captureTime > datetime('now', '-{val} {units}')"

        elif criteria == "pick":
            return f"i.pick = {val}"

        elif criteria == "rating":
            if op == "==": return f"i.rating = {val}"
            if op == ">=": return f"i.rating >= {val}"

        elif criteria == "fileFormat":
            if op == "==": return f"i.fileFormat = '{val}'"
            if op == "!=": return f"(i.fileFormat IS NULL OR i.fileFormat != '{val}')"

        elif criteria == "keywords":
            lc_val = val.lower()
            if op == "any":
                return (f"EXISTS (SELECT 1 FROM AgLibraryKeywordImage ki "
                        f"JOIN AgLibraryKeyword k ON k.id_local = ki.tag "
                        f"WHERE ki.image = i.id_local AND k.lc_name = '{lc_val}')")
            if op == "empty":
                return "NOT EXISTS (SELECT 1 FROM AgLibraryKeywordImage ki WHERE ki.image = i.id_local)"

        elif criteria == "focalLength":
            if op == "<": return f"exif.focalLength < {val}"
            if op == ">": return f"exif.focalLength > {val}"

        elif criteria == "labelColor":
            colors = {"1": "Red", "2": "Yellow", "3": "Green", "4": "Blue", "5": "Purple"}
            name = colors.get(val, val)
            return f"i.colorLabels = '{name}'"

        elif criteria == "touchTime":
            cocoa_now = int(time.time()) - 978307200
            multiplier = {"days": 86400, "months": 2592000}.get(units, 86400)
            threshold = cocoa_now - int(float(val)) * multiplier
            return f"i.touchTime > {threshold}"

        else:
            debug(f"Unknown smart collection criteria: {criteria}")

        return None


# ── Stacking helpers ──────────────────────────────────────────────────────

_DATE_PREFIX = re.compile(r'^\d{8}-')          # LrC plugin: 20260302-DSC07936
_DXO_SUFFIX = re.compile(r'-DxO_[^-]*', re.IGNORECASE)
_VIRTUAL_COPY = re.compile(r'-\d+$')

FORMAT_PRIORITY = {
    "tif": 1, "tiff": 1,
    "dng": 2,
    "arw": 3, "cr3": 3, "cr2": 3, "nef": 3, "raf": 3,
    "jpg": 4, "jpeg": 4,
    "heic": 5,
}

def normalize_stem(filename: str) -> str:
    stem = Path(filename).stem
    stem = _DATE_PREFIX.sub("", stem)
    stem = _DXO_SUFFIX.sub("", stem)
    stem = _VIRTUAL_COPY.sub("", stem)
    return stem.lower()

def format_priority(ext: str) -> int:
    return FORMAT_PRIORITY.get(ext.lower(), 9)


# ── Main sync logic ──────────────────────────────────────────────────────

def run(server: str, api_key: str, catalog_path: str,
        dry_run: bool = False, collection_filter: str = "",
        sync_metadata: bool = True, do_stacks: bool = True,
        do_prune: bool = False):

    api = ImmichAPI(server, api_key, dry_run)
    catalog = LrCCatalog(catalog_path)

    header("Album Sync: LrC → Immich")

    if dry_run:
        warn("[DRY RUN] No changes will be made to Immich.")
        print()

    # ── Phase 1: Build indexes ────────────────────────────────────────

    info("Fetching Immich asset index...")
    try:
        my_user_id = api.get_my_user_id()
        debug(f"Current user: {my_user_id}")
        asset_index = api.build_asset_index(owner_id=my_user_id)
    except Exception as e:
        error(f"Failed to build asset index: {e}")
        catalog.close()
        sys.exit(1)

    total_assets = sum(len(v) for v in asset_index.values())
    info(f"Immich: {total_assets} assets indexed (own assets only)")

    try:
        albums_list = api.albums_list()
    except Exception:
        error("Failed to fetch Immich albums.")
        catalog.close()
        sys.exit(1)

    album_by_name = {a["albumName"]: a["id"] for a in albums_list}

    # Build promotion map: asset_id → best asset_id in same stem group
    # So albums always reference the highest-quality format (TIF > DNG > RAW > JPG)
    promote: dict[str, str] = {}
    stem_best: dict[str, str] = {}  # stem → best asset_id
    for filename, assets in asset_index.items():
        for a in assets:
            fn = a["originalFileName"]
            stem = normalize_stem(fn)
            ext = fn.rsplit(".", 1)[-1] if "." in fn else ""
            prio = format_priority(ext)
            if stem not in stem_best:
                stem_best[stem] = (a["id"], prio)
            elif prio < stem_best[stem][1]:
                stem_best[stem] = (a["id"], prio)

    # Map every asset in a stem group to the best one
    for filename, assets in asset_index.items():
        for a in assets:
            stem = normalize_stem(a["originalFileName"])
            best_id, _ = stem_best.get(stem, (a["id"], 9))
            if best_id != a["id"]:
                promote[a["id"]] = best_id

    promoted_count = len(promote)
    if promoted_count > 0:
        debug(f"Promotion map: {promoted_count} assets will be promoted to best format")

    # Build stem index for fallback matching (LrC name → Immich stem)
    stem_index: dict[str, list[dict]] = defaultdict(list)
    for filename, assets in asset_index.items():
        stem = normalize_stem(filename)
        stem_index[stem].extend(assets)

    # ── Phase 2: Enumerate LrC collections ────────────────────────────

    collections = catalog.list_collections()
    info(f"LrC: {len(collections)} collections found")
    print()

    # ── Phase 3: Album sync loop ─────────────────────────────────────

    synced = created = skipped = errors = 0
    all_unmatched_files: set[str] = set()
    meta_records = []  # (asset_id, pick, rating)

    for coll in collections:
        coll_id = coll["id"]
        coll_name = coll["name"]
        coll_type = coll["type"]
        parent_name = coll["parent_name"]

        if collection_filter and coll_name != collection_filter:
            continue

        display_name = coll_name
        if parent_name and parent_name != "Smart Collections":
            display_name = f"{parent_name} / {coll_name}"

        info(f"Syncing: {_B}{display_name}{_R}")

        try:
            files = catalog.resolve_collection(coll_id, coll_type)
        except Exception as e:
            warn(f"  Failed to resolve collection: {e}")
            errors += 1
            continue

        if not files:
            dim("  Empty collection, skipping.")
            skipped += 1
            continue

        matched_ids = []
        unmatched = 0

        for f in files:
            filename = f["filename"]
            assets = asset_index.get(filename, [])
            if not assets:
                # Fallback: match by normalized stem (handles date-prefixed exports etc.)
                stem = normalize_stem(filename)
                assets = stem_index.get(stem, [])
            if not assets:
                debug(f"No Immich asset for: {filename}")
                unmatched += 1
                all_unmatched_files.add(filename)
                continue
            aid = assets[0]["id"]
            # Promote to best format in stem group (TIF > DNG > RAW > JPG)
            aid = promote.get(aid, aid)
            matched_ids.append(aid)
            if sync_metadata:
                meta_records.append((aid, f["pick"], f["rating"]))

        # Deduplicate — multiple LrC files may promote to the same best asset
        matched_ids = list(dict.fromkeys(matched_ids))

        if not matched_ids:
            dim(f"  No assets matched in Immich ({len(files)} files in LrC)")
            skipped += 1
            continue

        if unmatched > 0:
            debug(f"  {unmatched} file(s) not found in Immich")

        # Find or create album
        album_id = album_by_name.get(coll_name)

        if not album_id:
            if dry_run:
                info(f"  [dry-run] Would create album: {coll_name}")
            else:
                try:
                    resp = api.album_create(coll_name)
                    album_id = resp["id"]
                    album_by_name[coll_name] = album_id
                    success(f"  Created album: {coll_name}")
                    created += 1
                except Exception:
                    error(f"  Failed to create album: {coll_name}")
                    errors += 1
                    continue

        # Add assets
        if album_id:
            if dry_run:
                info(f"  [dry-run] Would add {len(matched_ids)} assets to '{coll_name}'")
            else:
                try:
                    api.album_add_assets(album_id, matched_ids)
                    success(f"  {len(matched_ids)} assets → '{coll_name}'")
                except Exception as e:
                    error(f"  Failed to add assets to '{coll_name}': {e}")
                    errors += 1

            # Prune
            if do_prune and album_id and not dry_run:
                try:
                    album_data = api.album_get(album_id)
                    current_ids = {a["id"] for a in album_data.get("assets", [])}
                    matched_set = set(matched_ids)
                    to_remove = list(current_ids - matched_set)
                    if to_remove:
                        api.album_remove_assets(album_id, to_remove)
                        dim(f"  Pruned {len(to_remove)} asset(s)")
                except Exception:
                    debug(f"Failed to prune album: {coll_name}")

        synced += 1

    # ── Phase 4: Metadata sync ────────────────────────────────────────

    if sync_metadata and meta_records:
        print()
        header("Metadata Sync")

        # Favorites (pick == 1 or 1.0)
        fav_ids = list({r[0] for r in meta_records if float(r[1]) == 1.0})
        if fav_ids:
            if dry_run:
                info(f"[dry-run] Would set {len(fav_ids)} asset(s) as favorite")
            else:
                try:
                    api.assets_set_favorite(fav_ids, True)
                    success(f"Set {len(fav_ids)} asset(s) as favorite")
                except Exception as e:
                    error(f"Failed to set favorites: {e}")

        # Ratings 1-5
        for rating_val in range(1, 6):
            r_ids = list({r[0] for r in meta_records if int(float(r[2])) == rating_val})
            if r_ids:
                if dry_run:
                    info(f"[dry-run] Would set {len(r_ids)} asset(s) to rating {rating_val}")
                else:
                    try:
                        api.assets_set_rating(r_ids, rating_val)
                        success(f"Set {len(r_ids)} asset(s) to rating {rating_val}")
                    except Exception as e:
                        error(f"Failed to set rating {rating_val}: {e}")

    # ── Phase 5: Stacking ────────────────────────────────────────────

    if do_stacks:
        print()
        header("Stacking")

        info("Analyzing file groups...")

        # Get all assets flat
        all_assets = []
        for filename, assets in asset_index.items():
            for a in assets:
                all_assets.append(a)

        # Group by normalized stem
        stem_groups: dict[str, list[tuple[str, str, str]]] = defaultdict(list)
        for a in all_assets:
            fn = a["originalFileName"]
            stem = normalize_stem(fn)
            ext = fn.rsplit(".", 1)[-1] if "." in fn else ""
            stem_groups[stem].append((a["id"], ext, fn))

        # Map asset ID → existing stack ID, and stack ID → all asset IDs
        asset_to_stack: dict[str, str] = {}
        stack_assets: dict[str, set[str]] = defaultdict(set)
        if not dry_run:
            try:
                stacks = api.stacks_list()
                for s in stacks:
                    sid = s["id"]
                    for sa in s.get("assets", []):
                        aid = sa.get("id", "")
                        asset_to_stack[aid] = sid
                        stack_assets[sid].add(aid)
            except Exception:
                pass

        stacks_created = 0
        stacks_updated = 0
        stacks_skipped = 0

        for stem, group in sorted(stem_groups.items()):
            if len(group) < 2:
                continue

            all_ids_in_group = {aid for aid, _, _ in group}

            # Check if all assets are already in the same stack
            existing_stack_ids = {asset_to_stack[aid] for aid in all_ids_in_group if aid in asset_to_stack}
            unstacked = [aid for aid in all_ids_in_group if aid not in asset_to_stack]

            if len(existing_stack_ids) == 1 and not unstacked:
                # All already in same stack — nothing to do
                continue

            # Sort group by format priority to determine primary
            sorted_group = sorted(group, key=lambda x: format_priority(x[1]))
            primary_id = sorted_group[0][0]
            all_ids = [g[0] for g in sorted_group]

            if dry_run:
                dim(f"  [dry-run] Would stack: {stem} ({len(group)} files)")
                stacks_created += 1
            else:
                # If there's an existing stack, delete it first — we'll recreate with all files
                for old_sid in existing_stack_ids:
                    try:
                        api._request("DELETE", f"/api/stacks/{old_sid}")
                        debug(f"Deleted old stack {old_sid} for re-merge")
                    except Exception:
                        pass

                try:
                    api.stack_create(primary_id, [aid for aid in all_ids if aid != primary_id])
                    if existing_stack_ids:
                        stacks_updated += 1
                    else:
                        stacks_created += 1
                except Exception:
                    debug(f"Failed to stack: {stem}")
                    stacks_skipped += 1

        if stacks_created > 0:
            success(f"Created {stacks_created} stack(s)")
        if stacks_updated > 0:
            success(f"Updated {stacks_updated} stack(s) (merged new files)")
        if stacks_created == 0 and stacks_updated == 0:
            dim("No new stacks to create.")
        if stacks_skipped > 0:
            dim(f"  {stacks_skipped} stack(s) failed")

    # ── Summary ───────────────────────────────────────────────────────

    catalog.close()

    print()
    header("Summary")
    success(f"Synced: {synced} album(s)")
    if created > 0:
        success(f"Created: {created} new album(s)")
    if skipped > 0:
        dim(f"  Skipped: {skipped} (empty or unmatched)")
    if all_unmatched_files:
        dim(f"  Catalog-only: {len(all_unmatched_files)} unique file(s) in LrC but not in Immich")
    if errors > 0:
        error(f"Errors: {errors}")


# ── CLI entry point ──────────────────────────────────────────────────────

VERBOSE = False

def main():
    global VERBOSE, QUIET

    server = os.environ.get("PBAK_IMMICH_SERVER", "")
    api_key = os.environ.get("PBAK_IMMICH_API_KEY", "")
    catalog = os.environ.get("PBAK_LRC_CATALOG", "")
    dry_run = os.environ.get("PBAK_DRY_RUN", "0") == "1"
    VERBOSE = os.environ.get("PBAK_VERBOSE", "0") == "1"
    QUIET = os.environ.get("PBAK_QUIET", "0") == "1"

    # Parse CLI flags (passed through from bash wrapper)
    collection_filter = ""
    sync_metadata = True
    do_stacks = True
    do_prune = False

    args = sys.argv[1:]
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--collection" and i + 1 < len(args):
            collection_filter = args[i + 1]
            i += 2
        elif arg == "--no-metadata":
            sync_metadata = False
            i += 1
        elif arg == "--no-stacks":
            do_stacks = False
            i += 1
        elif arg == "--prune":
            do_prune = True
            i += 1
        elif arg in ("-h", "--help"):
            print(f"""{_B}pbak albums{_R} — Sync Lightroom Classic collections to Immich albums

Reads collections from the LrC catalog, matches files to Immich assets,
creates/updates albums, syncs metadata (picks/ratings), and stacks
related files (TIF/DNG/ARW).

{_B}Flags:{_R}
  --collection <name>  Sync a single collection by name
  --no-metadata        Skip pick/rating metadata sync
  --no-stacks          Skip file stacking
  --prune              Remove assets from Immich albums not in LrC collection
  -h, --help           Show this help

{_B}Global flags also apply:{_R}  --dry-run, --verbose""")
            sys.exit(0)
        else:
            error(f"Unknown flag: {arg}")
            sys.exit(1)

    # Validate
    if not server or not api_key:
        error("Immich server details missing. Run 'pbak setup'.")
        sys.exit(1)
    if not catalog:
        error("PBAK_LRC_CATALOG is not set. Run 'pbak setup'.")
        sys.exit(1)
    if not Path(catalog).exists():
        error(f"Catalog not found: {catalog}")
        sys.exit(1)

    run(server, api_key, catalog,
        dry_run=dry_run,
        collection_filter=collection_filter,
        sync_metadata=sync_metadata,
        do_stacks=do_stacks,
        do_prune=do_prune)


if __name__ == "__main__":
    main()
