#!/usr/bin/env python3
"""Build Model A fine-tuning manifests from the Malaysian food datasets.

These sets are small (low thousands of images, a few dozen classes) next to
FoodSeg103, so they are a fine-tuning / class-expansion stage, not a primary
training set (spec section 19). None of them has pixel masks, so they
supervise the model weakly:

  roboflow  Malaysian Food Recognition 1 & 2 (Roboflow Universe, CC BY 4.0),
            exported in "COCO JSON" format. Boxes become coarse box masks.
  food11    Malaysia Food-11 (Kaggle). Folder-per-class images: one
            image-level dish label per photo, presence head only.
  mf150     MF-150 (IEEE DataPort). Multilabel ingredient annotations:
            image-level labels, presence head only. Its exact file format is
            not fixed here - point --csv at a table with an image column and a
            separated label column (see --image-col / --labels-col / --sep).

Usage:
    python -m ml.scripts.prepare_malaysian roboflow --root ml/data/raw/mfr1 --name roboflow_mfr
    python -m ml.scripts.prepare_malaysian roboflow --root ml/data/raw/mfr2 --name roboflow_mfr2
    python -m ml.scripts.prepare_malaysian food11 --root ml/data/raw/malaysia-food-11
    python -m ml.scripts.prepare_malaysian mf150 --root ml/data/raw/MF150 --csv labels.csv
"""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

from ml.common import MANIFESTS, split_for, write_jsonl
from ml.scripts.label_mapping import LabelMapper

IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}
SPLIT_ALIASES = {"train": "train", "valid": "val", "val": "val", "validation": "val", "test": "test"}


def roboflow(args, mapper: LabelMapper) -> list[dict]:
    records = []
    for split_dir in sorted(p for p in args.root.iterdir() if p.is_dir()):
        split = SPLIT_ALIASES.get(split_dir.name.lower())
        annotations = split_dir / "_annotations.coco.json"
        if split is None or not annotations.exists():
            continue
        coco = json.loads(annotations.read_text(encoding="utf-8"))
        used = {a["category_id"] for a in coco.get("annotations", [])}
        # Roboflow adds a parent category that is never used directly; skip it.
        categories = {c["id"]: mapper.map(args.name, c["name"])
                      for c in coco.get("categories", []) if c["id"] in used}
        label_set = sorted(set(categories.values()))

        boxes_by_image: dict[int, list] = {}
        for ann in coco.get("annotations", []):
            if ann["category_id"] not in categories:
                continue
            x, y, w, h = ann["bbox"]
            if w <= 1 or h <= 1:
                continue
            boxes_by_image.setdefault(ann["image_id"], []).append(
                [x, y, w, h, categories[ann["category_id"]]])

        for image in coco.get("images", []):
            path = split_dir / image["file_name"]
            boxes = boxes_by_image.get(image["id"])
            if not boxes or not path.exists():
                continue
            records.append({"source": args.name, "split": split, "kind": "boxes",
                            "image": str(path.resolve()), "boxes": boxes,
                            "label_set": label_set})
    return records


def food11(args, mapper: LabelMapper) -> list[dict]:
    root: Path = args.root
    split_dirs = [p for p in root.iterdir() if p.is_dir() and p.name.lower() in SPLIT_ALIASES]
    layout = [(SPLIT_ALIASES[p.name.lower()], p) for p in split_dirs] or [(None, root)]

    class_dirs = {c.name for _, base in layout for c in base.iterdir() if c.is_dir()}
    label_set = sorted({mapper.map("malaysia_food11", name) for name in class_dirs})

    records, index = [], 0
    for split, base in layout:
        for class_dir in sorted(p for p in base.iterdir() if p.is_dir()):
            label = mapper.map("malaysia_food11", class_dir.name)
            for image in sorted(class_dir.rglob("*")):
                if image.suffix.lower() not in IMAGE_SUFFIXES:
                    continue
                records.append({"source": "malaysia_food11",
                                "split": split or split_for(index, seed=11),
                                "kind": "image_labels", "image": str(image.resolve()),
                                "image_labels": [label], "label_set": label_set})
                index += 1
    return records


def mf150(args, mapper: LabelMapper) -> list[dict]:
    table = args.root / args.csv
    if not table.exists():
        raise SystemExit(f"Missing {table}. Point --csv at MF-150's label table.")
    rows = list(csv.DictReader(table.open(encoding="utf-8-sig", newline="")))
    if rows and (args.image_col not in rows[0] or args.labels_col not in rows[0]):
        raise SystemExit(f"Columns found: {list(rows[0])}. Set --image-col / --labels-col.")

    all_labels: set[str] = set()
    parsed = []
    for index, row in enumerate(rows):
        labels = [mapper.map("mf150", raw) for raw in row[args.labels_col].split(args.sep)
                  if raw.strip()]
        image = (args.root / args.images / row[args.image_col]).resolve()
        if not labels or not image.exists():
            continue
        all_labels.update(labels)
        split = SPLIT_ALIASES.get((row.get(args.split_col) or "").lower()) or split_for(index, seed=150)
        parsed.append((image, labels, split))

    label_set = sorted(all_labels)
    return [{"source": "mf150", "split": split, "kind": "image_labels", "image": str(image),
             "image_labels": sorted(set(labels)), "label_set": label_set}
            for image, labels, split in parsed]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="dataset", required=True)

    p = sub.add_parser("roboflow")
    p.add_argument("--root", type=Path, required=True)
    p.add_argument("--name", default="roboflow_mfr", help="manifest/source name")

    p = sub.add_parser("food11")
    p.add_argument("--root", type=Path, required=True)

    p = sub.add_parser("mf150")
    p.add_argument("--root", type=Path, required=True)
    p.add_argument("--csv", default="labels.csv")
    p.add_argument("--images", default=".", help="image folder relative to --root")
    p.add_argument("--image-col", default="image")
    p.add_argument("--labels-col", default="labels")
    p.add_argument("--split-col", default="split")
    p.add_argument("--sep", default=";")

    args = parser.parse_args()
    mapper = LabelMapper()
    builders = {"roboflow": roboflow, "food11": food11, "mf150": mf150}
    records = builders[args.dataset](args, mapper)

    name = getattr(args, "name", None) or {"food11": "malaysia_food11", "mf150": "mf150"}[args.dataset]
    out = MANIFESTS / f"{name}.jsonl"
    write_jsonl(out, records)
    splits = {s: sum(r["split"] == s for r in records) for s in ("train", "val", "test")}
    print(f"Wrote {len(records)} records to {out} {splits}")
    print(mapper.report())


if __name__ == "__main__":
    main()
