#!/usr/bin/env python3
"""Build the Model A base-training manifest from FoodSeg103.

Expected layout after extracting the official archive (see ml/README.md):

    <root>/category_id.txt                  "0<TAB>background", "1<TAB>candy", ...
    <root>/Images/img_dir/{train,test}/*.jpg
    <root>/Images/ann_dir/{train,test}/*.png   pixel value = category id

FoodSeg103 ships train/test only, so its test split doubles as validation.

Usage:
    python -m ml.scripts.prepare_foodseg103 --root ml/data/raw/FoodSeg103
"""
from __future__ import annotations

import argparse
from pathlib import Path

from ml.common import MANIFESTS, write_jsonl
from ml.scripts.label_mapping import LabelMapper


def read_categories(root: Path) -> dict[int, str]:
    path = root / "category_id.txt"
    if not path.exists():
        raise SystemExit(f"Missing {path}. Is --root the extracted FoodSeg103 folder?")
    categories: dict[int, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.strip().split(maxsplit=1)
        if len(parts) == 2 and parts[0].isdigit():
            categories[int(parts[0])] = parts[1].strip()
    return categories


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--out", type=Path, default=MANIFESTS / "foodseg103.jsonl")
    args = parser.parse_args()

    mapper = LabelMapper()
    categories = read_categories(args.root)
    mask_labels = {str(cid): mapper.map("foodseg103", name) for cid, name in categories.items()}
    mask_labels["0"] = "background"

    records = []
    for split, out_split in (("train", "train"), ("test", "val")):
        image_dir = args.root / "Images" / "img_dir" / split
        mask_dir = args.root / "Images" / "ann_dir" / split
        if not image_dir.exists():
            raise SystemExit(f"Missing {image_dir}")
        for image in sorted(image_dir.glob("*.jpg")):
            mask = mask_dir / f"{image.stem}.png"
            if not mask.exists():
                continue
            records.append({
                "source": "foodseg103",
                "split": out_split,
                "kind": "mask",
                "image": str(image.resolve()),
                "mask": str(mask.resolve()),
                "mask_labels": mask_labels,
            })

    write_jsonl(args.out, records)
    print(f"Wrote {len(records)} records to {args.out}")
    print(mapper.report())


if __name__ == "__main__":
    main()
