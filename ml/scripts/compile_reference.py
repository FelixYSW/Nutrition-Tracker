"""Compile manually verified MyFCD rows into the iOS bundle; do not scrape MyFCD."""
import argparse
import csv
import json
from pathlib import Path


def compile_table(source: Path, output: Path) -> None:
    ontology = json.loads(Path("ml/config/ontology.json").read_text(encoding="utf-8"))
    ids = {item["id"] for item in ontology["classes"]}
    rows = []
    with source.open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            canonical_id = row["canonical_id"].strip()
            if canonical_id not in ids:
                raise ValueError(f"Unknown canonical id: {canonical_id}")
            if not row["source_url"] or not row["verified_date"]:
                raise ValueError(f"Missing provenance for {canonical_id}")
            values = {key: float(row[key]) for key in ("calories", "protein", "carbs", "fat", "fibre", "sugar", "sodium")}
            if any(value < 0 for value in values.values()):
                raise ValueError(f"Negative nutrition for {canonical_id}")
            rows.append({"canonicalID": canonical_id, "name": row["name"], "source": "MyFCD", "per100g": values})
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(rows, indent=2), encoding="utf-8")
    print(f"Compiled {len(rows)} verified foods")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, default=Path("ml/config/myfcd_reference.csv"))
    parser.add_argument("--output", type=Path, default=Path("NutritionTracker/Resources/food_reference.json"))
    args = parser.parse_args()
    compile_table(args.input, args.output)
