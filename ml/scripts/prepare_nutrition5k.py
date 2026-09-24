"""Convert Nutrition5k dish metadata and official split ID lists to JSONL.

Pass an image template relative to dataset root, e.g. a validated path containing
{dish_id}; this avoids guessing which RGB view a particular download includes.
"""
import argparse
import csv
import json
import random
from pathlib import Path


def read_ids(path):
    return {line.strip() for line in path.read_text().splitlines() if line.strip()}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--train-ids", type=Path, required=True)
    parser.add_argument("--test-ids", type=Path, required=True)
    parser.add_argument("--image-template", required=True, help="Relative path with {dish_id}")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    train_ids, test_ids = read_ids(args.train_ids), read_ids(args.test_ids)
    if train_ids & test_ids:
        raise ValueError("Official train and test ID lists overlap")
    train_list = sorted(train_ids); random.Random(42).shuffle(train_list)
    validation = set(train_list[:max(1, len(train_list) // 10)])
    rows = []; missing = 0
    for file in sorted((args.root / "metadata").glob("dish_metadata_cafe*.csv")):
        with file.open(newline="") as stream:
            for fields in csv.reader(stream):
                if len(fields) < 6 or not fields[0].startswith("dish_"):
                    continue
                dish_id = fields[0]
                if dish_id not in train_ids | test_ids:
                    continue
                image = args.root / args.image_template.format(dish_id=dish_id)
                if not image.is_file():
                    missing += 1; continue
                row = {"image": str(image.resolve()),
                       "split": "test" if dish_id in test_ids else "val" if dish_id in validation else "train",
                       "calories": float(fields[1]), "mass_g": float(fields[2]),
                       "fat": float(fields[3]), "carbs": float(fields[4]), "protein": float(fields[5])}
                rows.append(row)
    if not rows:
        raise ValueError("No image/metadata pairs; check image template and dataset layout")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(json.dumps(row) for row in rows) + "\n")
    print(f"Prepared {len(rows)} dishes; {missing} missing images")


if __name__ == "__main__":
    main()
