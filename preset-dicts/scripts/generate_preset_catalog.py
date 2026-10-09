#!/usr/bin/env python3
"""Generate preset-dictionaries.json from .meta.json sidecars.

Scans output/*/*.meta.json, merges with catalog-policy.json, and
writes the v3 preset-dictionaries.json catalog consumed by the iOS app.

Usage:
    python scripts/generate_preset_catalog.py
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT_DIR = ROOT / "output"
POLICY_PATH = ROOT / "catalog-policy.json"
CATALOG_PATH = ROOT / "preset-dictionaries.json"


# Build scripts record human spellings in the .meta.json sidecars; the
# catalog (and THIRD-PARTY-NOTICES.md, generated from it) uses SPDX ids.
LICENSE_SPDX = {
    "Public Domain": "LicenseRef-Public-Domain",
    "CC BY-SA 3.0": "CC-BY-SA-3.0",
    "CC-BY-SA 3.0": "CC-BY-SA-3.0",
    "CC BY-SA 4.0": "CC-BY-SA-4.0",
    "CC-BY-SA 4.0": "CC-BY-SA-4.0",
    "GPL 3.0+": "GPL-3.0-or-later",
    "Unicode License": "Unicode-3.0",
    "CC-BY 4.0 + WordNet License": "CC-BY-4.0 AND LicenseRef-WordNet-3.0",
    "CC-BY-SA 3.0 / GFDL": "CC-BY-SA-3.0 OR GFDL-1.3-or-later",
}


def normalize_license(raw: str) -> str:
    """Map a sidecar license string to its SPDX identifier (pass-through if already SPDX)."""
    return LICENSE_SPDX.get(raw.strip(), raw.strip())


def load_existing_notes() -> dict:
    """licenseNote values from the current catalog, keyed by id (hand-maintained, kept across regenerations)."""
    if not CATALOG_PATH.exists():
        return {}
    with open(CATALOG_PATH, encoding='utf-8') as f:
        current = json.load(f)
    return {d["id"]: d["licenseNote"] for d in current.get("dictionaries", []) if d.get("licenseNote")}


def derive_id(filename: str) -> str:
    """Derive catalog id from MDX filename.

    Examples:
        WordNet-EN.mdx  -> wordnet-en
        Bible-KJV-EN.mdx -> bible-kjv-en
    """
    return Path(filename).stem.lower()


def load_policy() -> dict:
    """Load catalog-policy.json."""
    if not POLICY_PATH.exists():
        print(f"  WARNING: {POLICY_PATH} not found, using defaults")
        return {"bundle_assets": []}
    with open(POLICY_PATH, encoding='utf-8') as f:
        return json.load(f)


def collect_sidecars() -> list[dict]:
    """Find and load all .meta.json sidecars from output/."""
    sidecars = []
    for meta_path in sorted(OUTPUT_DIR.glob("*/*.meta.json")):
        with open(meta_path, encoding='utf-8') as f:
            meta = json.load(f)
        meta["_source_path"] = str(meta_path)
        sidecars.append(meta)
    return sidecars


def build_catalog(sidecars: list[dict], policy: dict) -> dict:
    """Build the v3 catalog from sidecars and policy."""
    bundle_set = set(policy.get("bundle_assets", []))
    existing_notes = load_existing_notes()
    dictionaries = []
    warnings = []

    for meta in sidecars:
        filename = meta["filename"]
        dict_id = derive_id(filename)
        is_bundle = filename in bundle_set

        entry = {
            "id": dict_id,
            "filename": filename,
            "displayName": meta["displayName"],
            "description": meta["description"],
            "direction": meta["direction"],
            "flag": meta["flag"],
            "entries": meta["entries"],
            "sizeBytes": meta["sizeBytes"],
            "license": normalize_license(meta["license"]),
            "dataSource": meta["dataSource"],
            "source": "bundle" if is_bundle else "odr",
        }

        if dict_id in existing_notes:
            entry["licenseNote"] = existing_notes[dict_id]

        # ODR dictionaries need an odrTag
        if not is_bundle:
            entry["odrTag"] = f"preset-dict-{dict_id}"

        # Tier (omit if None / hidden)
        tier = meta.get("tier")
        if tier is not None:
            entry["tier"] = tier
        else:
            warnings.append(f"  HIDDEN (no tier): {filename}")

        dictionaries.append(entry)

    # Sort: tier ascending, then displayName
    dictionaries.sort(key=lambda d: (d.get("tier", 999), d["displayName"]))

    return {"version": 3, "dictionaries": dictionaries}, warnings


def main():
    print("=" * 60)
    print("  Generating preset-dictionaries.json")
    print("=" * 60)

    if not OUTPUT_DIR.exists():
        print(f"ERROR: {OUTPUT_DIR} not found. Build dictionaries first.")
        sys.exit(1)

    policy = load_policy()
    sidecars = collect_sidecars()

    if not sidecars:
        print("ERROR: No .meta.json sidecars found in output/.")
        print("       Run build scripts first (make all).")
        sys.exit(1)

    catalog, warnings = build_catalog(sidecars, policy)

    for w in warnings:
        print(w)

    # Write catalog
    CATALOG_PATH.write_text(
        json.dumps(catalog, indent=2, ensure_ascii=False) + '\n',
        encoding='utf-8',
    )

    n = len(catalog["dictionaries"])
    bundle_count = sum(1 for d in catalog["dictionaries"] if d["source"] == "bundle")
    odr_count = n - bundle_count
    print(f"\n  {n} dictionaries ({bundle_count} bundle + {odr_count} ODR)")
    print(f"  Written: {CATALOG_PATH}")
    print()


if __name__ == "__main__":
    main()
