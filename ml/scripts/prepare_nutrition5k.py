#!/usr/bin/env python3
"""Build the Model B manifest from Nutrition5k.

Expected layout (a subset of gs://nutrition5k_dataset/nutrition5k_dataset):

    <root>/metadata/dish_metadata_cafe1.csv
    <root>/metadata/dish_metadata_cafe2.csv
    <root>/dish_ids/splits/rgb_train_ids.txt
    <root>/dish_ids/splits/rgb_test_ids.txt
    <root>/imagery/realsense_overhead/dish_<id>/rgb.png
    <root>/imagery/realsense_overhead/dish_<id>/depth_raw.png   (optional)

Each metadata row is: dish_id, total_calories, total_mass, total_fat,
total_carb, total_protein, then repeating groups of seven per ingredient
(ingr_id, ingr_name, grams, calories, fat, carb, protein). Rows vary in length,
so they are read with the csv module rather than a fixed-width table.

Only overhead RGB dishes are used. Note the domain gap: these were shot from a
fixed overhead rig with depth sensing, not a handheld phone (spec section 18).

Usage:
    python -m ml.scripts.prepare_nutrition5k --root ml/data/raw/nutrition5k_dataset
"""
from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path

from ml.common import MANIFESTS, split_for

FIELDS = ["dish_id", "split", "image", "depth", "mass", "calories", "protein",
          "carbs", "fat", "ingredients"]


def parse_metadata(path: Path) -> dict[str, dict]:
    dishes = {}
    with path.open(encoding="utf-8", newline="") as handle:
        for row in csv.reader(handle):
            if len(row) < 6 or not row[0].startswith("dish_"):
                continue
            try:
                calories, mass, fat, carbs, protein = (float(v) for v in row[1:6])
            except ValueError:
                continue
            if not all(math.isfinite(v) and v >= 0 for v in (calories, mass, fat, carbs, protein)):
                continue
            ingredients = []
            for start in range(6, len(row) - 6, 7):
                group = row[start:start + 7]
                try:
                    ingredients.append({"id": group[0], "name": group[1], "grams": float(group[2])})
                except (ValueError, IndexError):
                    break
            dishes[row[0]] = {"mass": mass, "calories": calories, "protein": protein,
                              "carbs": carbs, "fat": fat, "ingredients": ingredients}
    return dishes


def read_ids(path: Path) -> set[str]:
    return {line.strip() for line in path.read_text().splitlines() if line.strip()} if path.exists() else set()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--out", type=Path, default=MANIFESTS / "nutrition5k.csv")
    parser.add_argument("--max-calories", type=float, default=3000,
                        help="drop implausible outliers (data-entry errors)")
    args = parser.parse_args()

    dishes: dict[str, dict] = {}
    for name in ("dish_metadata_cafe1.csv", "dish_metadata_cafe2.csv"):
        path = args.root / "metadata" / name
        if path.exists():
            dishes.update(parse_metadata(path))
    if not dishes:
        raise SystemExit("No dish metadata found under <root>/metadata/")

    train_ids = read_ids(args.root / "dish_ids" / "splits" / "rgb_train_ids.txt")
    test_ids = read_ids(args.root / "dish_ids" / "splits" / "rgb_test_ids.txt")

    rows, skipped = [], 0
    overhead = args.root / "imagery" / "realsense_overhead"
    for index, (dish_id, info) in enumerate(sorted(dishes.items())):
        image = overhead / dish_id / "rgb.png"
        if not image.exists() or info["mass"] <= 0 or info["calories"] > args.max_calories:
            skipped += 1
            continue
        if dish_id in test_ids:
            split = "test"
        elif dish_id in train_ids:
            # Carve a validation set out of the official train split.
            split = "val" if split_for(index, seed=5, val=0.1, test=0.0) == "val" else "train"
        else:
            split = split_for(index, seed=5)
        depth = overhead / dish_id / "depth_raw.png"
        rows.append({"dish_id": dish_id, "split": split, "image": str(image.resolve()),
                     "depth": str(depth.resolve()) if depth.exists() else "",
                     **{k: info[k] for k in ("mass", "calories", "protein", "carbs", "fat")},
                     "ingredients": json.dumps(info["ingredients"])})

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)

    splits = {s: sum(r["split"] == s for r in rows) for s in ("train", "val", "test")}
    print(f"Wrote {len(rows)} dishes to {args.out} {splits}; skipped {skipped}")


if __name__ == "__main__":
    main()
