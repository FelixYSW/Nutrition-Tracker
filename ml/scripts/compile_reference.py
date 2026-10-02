#!/usr/bin/env python3
"""Compile the bundled nutrition reference table and ontology for the iOS app.

Inputs (all under ml/config/):
  generic_reference.csv  typical per-100 g figures for common ingredients
  myfcd_reference.csv    rows copied by hand from MyFCD (myfcd.moh.gov.my)
  ontology.json          canonical food IDs and dataset label aliases

Outputs (under NutritionTracker/Resources/):
  myfcd_reference.json   merged table read by LocalNutritionReference
  ontology.json          copy of the ontology read by FoodOntology

MyFCD has no bulk download or public API, so its rows are compiled here
offline and nothing is fetched at runtime. A MyFCD row overrides a generic row
with the same canonical ID. MyFCD rows with blank nutrient values are skipped
(they are placeholders still waiting to be filled in) and reported.

Every canonical ID in either CSV must exist in the ontology, otherwise the
script fails: an unmapped row could never be looked up by the app.

Usage:
  python ml/scripts/compile_reference.py
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "ml" / "config"
RESOURCES = ROOT / "NutritionTracker" / "Resources"

NUTRIENTS = ["calories", "protein", "carbs", "fat"]
OPTIONAL = ["fibre", "sugar", "sodium"]


def parse_number(raw: str | None) -> float | None:
    if raw is None:
        return None
    raw = raw.strip()
    if not raw:
        return None
    value = float(raw.replace(",", "."))
    if not math.isfinite(value) or value < 0:
        raise ValueError(f"invalid nutrient value {raw!r}")
    return value


def load_rows(path: Path, source: str) -> tuple[list[dict], list[str]]:
    rows: list[dict] = []
    skipped: list[str] = []
    if not path.exists():
        return rows, skipped
    with path.open(newline="", encoding="utf-8") as handle:
        for line_no, record in enumerate(csv.DictReader(handle), start=2):
            cid = (record.get("canonical_id") or "").strip()
            if not cid:
                continue
            try:
                required = {k: parse_number(record.get(k)) for k in NUTRIENTS}
                optional = {k: parse_number(record.get(k)) for k in OPTIONAL}
            except ValueError as error:
                raise SystemExit(f"{path.name}:{line_no}: {error}")
            if any(v is None for v in required.values()):
                skipped.append(cid)
                continue
            row = {
                "canonicalID": cid,
                "displayName": (record.get("display_name") or cid).strip(),
                **required,
                "source": source,
            }
            for key, value in optional.items():
                if value is not None:
                    row[key] = value
            code = (record.get("myfcd_code") or "").strip()
            if code:
                row["sourceCode"] = code
            rows.append(row)
    return rows, skipped


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, default=RESOURCES)
    args = parser.parse_args()

    ontology = json.loads((CONFIG / "ontology.json").read_text(encoding="utf-8"))
    known_ids = {entry["canonicalID"] for entry in ontology["entries"]}

    generic, generic_skipped = load_rows(CONFIG / "generic_reference.csv", "generic")
    myfcd, myfcd_skipped = load_rows(CONFIG / "myfcd_reference.csv", "myfcd")

    merged: dict[str, dict] = {row["canonicalID"]: row for row in generic}
    for row in myfcd:
        merged[row["canonicalID"]] = row  # MyFCD wins over generic

    unknown = sorted(cid for cid in merged if cid not in known_ids)
    if unknown:
        print("Canonical IDs missing from ontology.json:", ", ".join(unknown), file=sys.stderr)
        return 1

    args.out.mkdir(parents=True, exist_ok=True)
    table = {"version": 1, "rows": sorted(merged.values(), key=lambda r: r["canonicalID"])}
    (args.out / "myfcd_reference.json").write_text(
        json.dumps(table, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (args.out / "ontology.json").write_text(
        json.dumps(ontology, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    print(f"Wrote {len(merged)} rows ({len(myfcd)} MyFCD, "
          f"{len(merged) - len(myfcd)} generic) and {len(known_ids)} ontology entries.")
    if myfcd_skipped:
        print(f"MyFCD placeholders still blank ({len(myfcd_skipped)}): "
              + ", ".join(myfcd_skipped))
    if generic_skipped:
        print(f"Generic rows skipped for missing values: {', '.join(generic_skipped)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
