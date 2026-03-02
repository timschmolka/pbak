#!/usr/bin/env python3
"""pbak immich utilities — stacking and upload verification.

Subcommands:
  stack                  Stack all assets by filename stem (format priority)
  mark-uploaded <db>     Mark hash DB entries as uploaded based on Immich assets
  uploaded-files         Output originalFileName for every asset on the server
"""

import json
import os
import re
import sys
import time
import urllib.request
import urllib.error
from collections import defaultdict
from pathlib import Path

# ── Config ────────────────────────────────────────────────────────────────

DRY_RUN = os.environ.get("PBAK_DRY_RUN", "0") == "1"
VERBOSE = os.environ.get("PBAK_VERBOSE", "0") == "1"
QUIET = os.environ.get("PBAK_QUIET", "0") == "1"

# ── UI helpers (match pbak bash style) ────────────────────────────────────

_ISATTY = sys.stderr.isatty()
_B = "\033[1m" if _ISATTY else ""
_D = "\033[2m" if _ISATTY else ""
_R = "\033[0m" if _ISATTY else ""
_RED = "\033[31m" if _ISATTY else ""
_GREEN = "\033[32m" if _ISATTY else ""
_YELLOW = "\033[33m" if _ISATTY else ""
_BLUE = "\033[34m" if _ISATTY else ""


def success(msg):
    if not QUIET: print(f"{_GREEN}✓{_R} {msg}", file=sys.stderr)
def error(msg):   print(f"{_RED}✗{_R} {msg}", file=sys.stderr)
def warn(msg):    print(f"{_YELLOW}!{_R} {msg}", file=sys.stderr)
def info(msg):
    if not QUIET: print(f"{_BLUE}·{_R} {msg}", file=sys.stderr)
def dim(msg):
    if not QUIET: print(f"{_D}{msg}{_R}", file=sys.stderr)
def debug(msg):
    if VERBOSE:
        print(f"{time.strftime('%H:%M:%S')} [DEBUG] {msg}", file=sys.stderr)


# ── Immich API ────────────────────────────────────────────────────────────

class ImmichAPI:
    def __init__(self, server: str, api_key: str):
        self.server = server.rstrip("/")
        self.api_key = api_key

    def _request(self, method: str, endpoint: str, data=None, readonly=False):
        if method != "GET" and not readonly and DRY_RUN:
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

    def get_all_assets(self) -> list[dict]:
        assets = []
        page = 1
        while True:
            resp = self._request("POST", "/api/search/metadata",
                                 {"page": page, "size": 1000}, readonly=True)
            items = resp.get("assets", {}).get("items", [])
            debug(f"Fetched page {page}: {len(items)} assets")
            assets.extend(items)
            if len(items) < 1000:
                break
            page += 1
        return assets

    def stack_create(self, primary_id: str, other_ids: list[str]):
        # First asset becomes the stack cover (primary)
        all_ids = [primary_id] + other_ids
        return self._request("POST", "/api/stacks",
                             {"assetIds": all_ids})

    def stacks_list(self) -> list[dict]:
        return self._request("GET", "/api/stacks") or []


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


# ── Commands ──────────────────────────────────────────────────────────────

def cmd_stack(api: ImmichAPI):
    """Stack all assets by filename stem."""
    info("Fetching assets from Immich...")
    assets = api.get_all_assets()
    if not assets:
        info("No assets found.")
        return

    info(f"Found {len(assets)} assets")

    # Existing stacks
    stacks = api.stacks_list()
    asset_to_stack: dict[str, str] = {}
    for s in stacks:
        sid = s["id"]
        if "primaryAssetId" in s:
            asset_to_stack[s["primaryAssetId"]] = sid
        for a in s.get("assets", []):
            asset_to_stack[a["id"]] = sid

    # Group by normalized stem
    stem_groups: dict[str, list[tuple]] = defaultdict(list)
    for a in assets:
        fn = a["originalFileName"]
        stem = normalize_stem(fn)
        ext = fn.rsplit(".", 1)[-1] if "." in fn else ""
        stem_groups[stem].append((a["id"], ext, fn))

    created = 0
    skipped = 0

    for stem, group in sorted(stem_groups.items()):
        if len(group) < 2:
            continue

        all_ids_in_group = {aid for aid, _, _ in group}
        existing_stack_ids = {asset_to_stack[aid] for aid in all_ids_in_group
                              if aid in asset_to_stack}
        unstacked = [aid for aid in all_ids_in_group if aid not in asset_to_stack]

        if len(existing_stack_ids) == 1 and not unstacked:
            skipped += 1
            continue

        sorted_group = sorted(group, key=lambda x: format_priority(x[1]))
        primary_id = sorted_group[0][0]
        other_ids = [g[0] for g in sorted_group if g[0] != primary_id]

        fnames = ", ".join(g[2] for g in sorted_group)
        debug(f"Stacking: {fnames}")

        if not DRY_RUN:
            try:
                for old_sid in existing_stack_ids:
                    api._request("DELETE", f"/api/stacks/{old_sid}")
                api.stack_create(primary_id, other_ids)
            except Exception as e:
                debug(f"Stack failed for {fnames}: {e}")
                continue

        created += 1

    success(f"Stacks created: {created}, already stacked: {skipped}")


# Extensions where stem matching is safe (one unique file per shot).
# If any variant of DSC00123 is on Immich, all RAW/DNG variants are "uploaded".
_STEM_MATCH_EXTENSIONS = {"arw", "cr3", "cr2", "nef", "raf", "dng"}


def cmd_mark_uploaded(api: ImmichAPI, db_path: str):
    """Mark hash DB entries as uploaded based on Immich assets.

    Matching strategy per extension:
      ARW/DNG/CR3/CR2/NEF/RAF  — by normalized stem (DSC number)
      TIF/TIFF and others      — by exact filename only
    """
    info("Fetching assets from Immich...")
    assets = api.get_all_assets()
    if not assets:
        info("No assets found on server.")
        return

    info(f"Found {len(assets)} assets on server")

    # Build lookup sets from Immich assets
    exact_names: set[str] = set()       # lowercase exact filenames
    uploaded_stems: set[str] = set()    # normalized stems

    for a in assets:
        fn = a["originalFileName"]
        exact_names.add(fn.lower())
        uploaded_stems.add(normalize_stem(fn))

    # Read DB, mark matches, write back atomically
    ts = time.strftime("%Y-%m-%dT%H:%M:%S")
    lines: list[str] = []
    marked = 0

    with open(db_path, "r") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            fields = line.split("\t")
            if len(fields) < 5:
                lines.append(line)
                continue

            dest_path = fields[2]
            fname = dest_path.rsplit("/", 1)[-1] if "/" in dest_path else dest_path
            ext = fname.rsplit(".", 1)[-1].lower() if "." in fname else ""

            is_uploaded = False

            if ext in _STEM_MATCH_EXTENSIONS:
                # RAW/DNG: match by normalized stem
                stem = normalize_stem(fname)
                if stem in uploaded_stems:
                    is_uploaded = True
            else:
                # TIF and everything else: exact filename match only
                if fname.lower() in exact_names:
                    is_uploaded = True

            if is_uploaded:
                while len(fields) < 6:
                    fields.append("")
                fields[5] = ts
                marked += 1

            lines.append("\t".join(fields))

    import tempfile, shutil
    tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(db_path))
    with os.fdopen(tmp_fd, "w") as out:
        for l in lines:
            out.write(l + "\n")
    shutil.move(tmp_path, db_path)

    success(f"Marked {marked} files as uploaded (verified against Immich)")


def cmd_uploaded_files(api: ImmichAPI):
    """Output originalFileName for all assets (one per line, to stdout)."""
    assets = api.get_all_assets()
    info(f"Found {len(assets)} assets on server")
    for a in assets:
        print(a["originalFileName"])


# ── Main ──────────────────────────────────────────────────────────────────

def main():
    server = os.environ.get("PBAK_IMMICH_SERVER", "")
    api_key = os.environ.get("PBAK_IMMICH_API_KEY", "")

    if not server or not api_key:
        error("PBAK_IMMICH_SERVER and PBAK_IMMICH_API_KEY required")
        sys.exit(1)

    api = ImmichAPI(server, api_key)

    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "stack":
        cmd_stack(api)
    elif cmd == "mark-uploaded":
        if len(sys.argv) < 3:
            error(f"Usage: {sys.argv[0]} mark-uploaded <db_path>")
            sys.exit(1)
        cmd_mark_uploaded(api, sys.argv[2])
    elif cmd == "uploaded-files":
        cmd_uploaded_files(api)
    else:
        error(f"Usage: {sys.argv[0]} <stack|mark-uploaded|uploaded-files>")
        sys.exit(1)


if __name__ == "__main__":
    main()
