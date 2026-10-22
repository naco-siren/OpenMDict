#!/usr/bin/env python3
"""Generate preset-dictionaries.json from the build output.

For every output/<Name>/<Name>.meta.json sidecar the build scripts wrote:

  * displayName, description, direction, flag, license, dataSource and tier
    come from the sidecar;
  * sizeBytes, sha256 and entries are measured from output/<Name>/<Name>.mdx
    itself, because a sidecar can be older than its .mdx (entries = the key
    count in the MDX keyword header, the number the `openmdict` CLI prints);
  * licenseNote (hand-maintained), previousSha256 and previousDisplayNames
    are carried over from the current catalog by id; previousSha256 gains the
    sha256 that a rebuild replaces, since the app offers an update only for
    the builds listed there, and previousDisplayNames the displayName a
    rebuild replaces, since the app renames an updated copy that still has
    one of them;
  * source and odrTag follow catalog-policy.json.

The result is compared with the current catalog field by field. The
default mode writes the new catalog and prints that diff; --check prints it
and exits 1 when anything would change (`make all` runs it, so a rebuild
never rewrites the catalog silently). It refuses to drop a dictionary that
is in the current catalog but has no sidecar, and it fails on a license id
or dataSource that gen_third_party_notices.py cannot attribute.

Usage:
    python3 scripts/generate_preset_catalog.py            # rewrite + diff
    python3 scripts/generate_preset_catalog.py --check    # diff, exit 1 on drift
"""

import argparse
import hashlib
import json
import re
import struct
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parent
OUTPUT_DIR = ROOT / "output"
POLICY_PATH = ROOT / "catalog-policy.json"
CATALOG_PATH = ROOT / "preset-dictionaries.json"

sys.path.insert(0, str(SCRIPT_DIR))
import gen_third_party_notices as notices  # noqa: E402  (license / source tables)

# Field order of a catalog entry (optional fields are omitted when absent).
FIELD_ORDER = ("id", "filename", "displayName", "description", "direction",
               "flag", "entries", "sizeBytes", "license", "licenseNote",
               "dataSource", "source", "odrTag", "tier", "sha256",
               "previousSha256", "previousDisplayNames")

# Fields that identify a preset to the app (or are maintained by hand); a
# change to one of them is flagged in the diff.
IDENTITY_FIELDS = ("filename", "flag", "source", "odrTag", "tier", "licenseNote")

# Build scripts should emit SPDX ids; older ones wrote these spellings.
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
    """Map a sidecar license string to its SPDX expression (pass-through if already SPDX)."""
    return LICENSE_SPDX.get(raw.strip(), raw.strip())


def load_catalog() -> dict:
    if not CATALOG_PATH.exists():
        return {"version": 3, "dictionaries": []}
    return json.loads(CATALOG_PATH.read_text(encoding="utf-8"))


def load_policy() -> dict:
    if not POLICY_PATH.exists():
        print(f"  WARNING: {POLICY_PATH} not found, using defaults")
        return {"bundle_assets": []}
    return json.loads(POLICY_PATH.read_text(encoding="utf-8"))


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def mdx_entry_count(path: Path) -> int:
    """Number of keys in an MDX file, read from its keyword-section header.

    Layout (docs/MDict_Format_Specification.md): u32 BE header length, the
    UTF-16LE header, u32 adler32, then the keyword section header, whose
    second field is the number of entries (u64 BE for engine version >= 2.0,
    u32 BE before).
    """
    with open(path, "rb") as f:
        (header_len,) = struct.unpack(">I", f.read(4))
        header = f.read(header_len).decode("utf-16-le", errors="replace")
        f.read(4)
        m = re.search(r'Encrypted="(\d+)"', header)
        if m and int(m.group(1)) & 1:
            raise ValueError(f"{path}: keyword header is encrypted")
        m = re.search(r'GeneratedByEngineVersion="([\d.]+)"', header)
        version = float(m.group(1)) if m else 2.0
        if version >= 2.0:
            _blocks, entries = struct.unpack(">QQ", f.read(16))
        else:
            _blocks, entries = struct.unpack(">II", f.read(8))
    return entries


def derive_id(filename: str) -> str:
    """WordNet-EN.mdx -> wordnet-en"""
    return Path(filename).stem.lower()


def collect_sidecars() -> list[dict]:
    sidecars = []
    for meta_path in sorted(OUTPUT_DIR.glob("*/*.meta.json")):
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        meta["_source_path"] = str(meta_path)
        sidecars.append(meta)
    return sidecars


def ordered(entry: dict) -> dict:
    extra = [k for k in entry if k not in FIELD_ORDER]
    if extra:
        raise ValueError(f"{entry.get('id')}: unexpected catalog fields {extra}")
    return {k: entry[k] for k in FIELD_ORDER if k in entry}


def build_catalog(sidecars: list[dict], policy: dict, current: dict) -> tuple[dict, list[str], list[str]]:
    """Return (catalog, warnings, errors)."""
    bundle_set = set(policy.get("bundle_assets", []))
    existing = {d["id"]: d for d in current.get("dictionaries", [])}
    dictionaries, warnings, errors = [], [], []
    seen = set()

    for meta in sidecars:
        filename = meta["filename"]
        dict_id = derive_id(filename)
        seen.add(dict_id)
        mdx = OUTPUT_DIR / Path(filename).stem / filename
        if not mdx.is_file():
            errors.append(f"{meta['_source_path']}: no {mdx.relative_to(ROOT)} next to the sidecar")
            continue
        is_bundle = filename in bundle_set
        old = existing.get(dict_id, {})

        license_expr = normalize_license(meta["license"])
        unknown = [i for i in notices.license_ids(license_expr) if i not in notices.LICENSES]
        if unknown:
            errors.append(f"{filename}: license {license_expr!r} has ids {unknown} that "
                          "gen_third_party_notices.LICENSES does not know (emit SPDX ids, or add a row)")
        try:
            notices.attribution(meta["dataSource"])
        except SystemExit as e:
            errors.append(f"{filename}: {e}")

        digest = sha256_of(mdx)
        previous = list(old.get("previousSha256", []))
        old_sha = old.get("sha256")
        if old_sha and old_sha != digest and old_sha not in previous:
            previous.append(old_sha)

        entry = {
            "id": dict_id,
            "filename": filename,
            "displayName": meta["displayName"],
            "description": meta["description"],
            "direction": meta["direction"],
            "flag": meta["flag"],
            "entries": mdx_entry_count(mdx),
            "sizeBytes": mdx.stat().st_size,
            "license": license_expr,
            "dataSource": meta["dataSource"],
            "source": "bundle" if is_bundle else "odr",
            "sha256": digest,
            # Every build that ever shipped, minus the current one.
            "previousSha256": [h for h in dict.fromkeys(previous) if h != digest],
        }
        if old.get("licenseNote"):
            entry["licenseNote"] = old["licenseNote"]
        # Earlier names, so that the app renames an installed copy it updates
        # (unless the user renamed it).
        names = list(old.get("previousDisplayNames", []))
        if old.get("displayName") and old["displayName"] != entry["displayName"]:
            names.append(old["displayName"])
        names = [n for n in dict.fromkeys(names) if n != entry["displayName"]]
        if names:
            entry["previousDisplayNames"] = names
        if not is_bundle:
            entry["odrTag"] = f"preset-dict-{dict_id}"
        if meta.get("tier") is not None:
            entry["tier"] = meta["tier"]
        else:
            warnings.append(f"  HIDDEN (no tier): {filename}")
        if meta["entries"] != entry["entries"] or meta["sizeBytes"] != entry["sizeBytes"]:
            warnings.append(f"  stale sidecar {Path(meta['_source_path']).name}: entries "
                            f"{meta['entries']} / sizeBytes {meta['sizeBytes']}, the .mdx has "
                            f"{entry['entries']} / {entry['sizeBytes']} (the .mdx wins)")
        dictionaries.append(ordered(entry))

    for dict_id in existing:
        if dict_id not in seen:
            errors.append(f"{existing[dict_id]['filename']} is in the catalog but output/ has no "
                          "sidecar for it (build it, or remove it from the catalog by hand)")

    dictionaries.sort(key=lambda d: (d.get("tier", 999), d["displayName"]))
    return {"version": 3, "dictionaries": dictionaries}, warnings, errors


def _short(value) -> str:
    text = json.dumps(value, ensure_ascii=False) if not isinstance(value, str) else value
    if isinstance(value, str) and len(value) == 64 and re.fullmatch(r"[0-9a-f]{64}", value):
        return value[:12] + "…"
    return text if len(text) <= 70 else text[:67] + "…"


def diff_catalogs(old: dict, new: dict) -> list[tuple[str, str, object, object]]:
    """(id, field, old, new) for every field that differs; field '*' = added/removed."""
    old_d = {d["id"]: d for d in old.get("dictionaries", [])}
    new_d = {d["id"]: d for d in new.get("dictionaries", [])}
    changes = []
    for dict_id in sorted(old_d.keys() | new_d.keys()):
        a, b = old_d.get(dict_id), new_d.get(dict_id)
        if a is None or b is None:
            changes.append((dict_id, "*", "present" if a else "absent", "present" if b else "absent"))
            continue
        for field in FIELD_ORDER:
            if a.get(field) != b.get(field):
                changes.append((dict_id, field, a.get(field), b.get(field)))
    old_order = [d["id"] for d in old.get("dictionaries", [])]
    new_order = [d["id"] for d in new.get("dictionaries", [])]
    if old_order != new_order and set(old_order) == set(new_order):
        changes.append(("(catalog)", "order", "", ""))
    return changes


def print_diff(changes) -> None:
    if not changes:
        print("  No field differs from the current catalog.")
        return
    counts: dict[str, int] = {}
    for dict_id, field, a, b in changes:
        counts[field] = counts.get(field, 0) + 1
        mark = "!" if field in IDENTITY_FIELDS or field == "*" else " "
        if field in ("description", "previousSha256"):
            print(f" {mark} {dict_id:24s} {field:15s} changed")
        else:
            print(f" {mark} {dict_id:24s} {field:15s} {_short(a)} -> {_short(b)}")
    summary = ", ".join(f"{f} {n}" for f, n in sorted(counts.items()))
    print(f"\n  {len(changes)} field change(s): {summary}")
    if any(f in IDENTITY_FIELDS or f == "*" for _, f, _, _ in changes):
        print("  ('!' marks fields that identify a preset or are maintained by hand: review them)")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true",
                    help="print the diff and exit 1 if the catalog would change (write nothing)")
    args = ap.parse_args()

    print("=" * 60)
    print("  " + ("Checking" if args.check else "Generating") + " preset-dictionaries.json")
    print("=" * 60)
    if not OUTPUT_DIR.exists():
        print(f"ERROR: {OUTPUT_DIR} not found. Build dictionaries first.")
        return 1
    sidecars = collect_sidecars()
    if not sidecars:
        print("ERROR: No .meta.json sidecars found in output/. Run the build scripts first (make all).")
        return 1

    current = load_catalog()
    catalog, warnings, errors = build_catalog(sidecars, load_policy(), current)
    for w in warnings:
        print(w)
    if errors:
        for e in errors:
            print(f"ERROR: {e}")
        if not args.check:
            print("Catalog not written.")
        return 1

    changes = diff_catalogs(current, catalog)
    print_diff(changes)
    n = len(catalog["dictionaries"])
    n_bundle = sum(1 for d in catalog["dictionaries"] if d["source"] == "bundle")

    if args.check:
        if changes:
            print(f"\n  {CATALOG_PATH.name} is out of date with output/: review the changes "
                  "above, then run `make catalog` (and `make notices`).")
            return 1
        print(f"  {CATALOG_PATH.name} matches output/ ({n} dictionaries)")
        return 0

    CATALOG_PATH.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n",
                            encoding="utf-8")
    print(f"\n  {n} dictionaries ({n_bundle} bundle + {n - n_bundle} ODR)")
    print(f"  Written: {CATALOG_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
