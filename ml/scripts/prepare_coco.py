"""Map COCO polygon masks to canonical IDs for semantic segmentation.

Use for FoodSeg103 or Roboflow COCO exports that include segmentation polygons.
Detection boxes without masks cannot become segmentation supervision here.
"""
import argparse
import json
import random
import re
from pathlib import Path

import numpy as np
from PIL import Image
from pycocotools.coco import COCO


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--annotations", type=Path, required=True)
    parser.add_argument("--images", type=Path, required=True)
    parser.add_argument("--source", required=True, help="Ontology alias key, e.g. foodseg103")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--expand-ontology", action="store_true", help="Add unknown source labels as distinct canonical IDs")
    args = parser.parse_args()
    ontology = json.loads(Path("ml/config/ontology.json").read_text())
    aliases = {alias.casefold(): row["id"] for row in ontology["classes"]
               for alias in row.get("aliases", {}).get(args.source, [])}
    coco = COCO(str(args.annotations))
    unknown = sorted({value["name"] for value in coco.cats.values() if value["name"].casefold() not in aliases})
    if unknown and not args.expand_ontology:
        raise ValueError(f"Unmapped labels for {args.source}: {unknown}. Map aliases or use --expand-ontology.")
    if unknown:
        for name in unknown:
            slug = re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")
            new_id = f"{args.source}_{slug}"
            if new_id in {item["id"] for item in ontology["classes"]}:
                raise ValueError(f"Canonical ID collision: {new_id}")
            ontology["classes"].append({"id": new_id, "name": name, "aliases": {args.source: [name]}})
            aliases[name.casefold()] = new_id
        Path("ml/config/ontology.json").write_text(json.dumps(ontology, indent=2) + "\n")
    class_ids = {row["id"]: i + 1 for i, row in enumerate(ontology["classes"])}
    category_map = {key: class_ids[aliases[value["name"].casefold()]] for key, value in coco.cats.items()}
    Path("NutritionTracker/Resources/food_labels.json").write_text(
        json.dumps(["background"] + [row["id"] for row in ontology["classes"]], indent=2) + "\n")
    ids = sorted(coco.imgs)
    random.Random(args.seed).shuffle(ids)
    args.output.mkdir(parents=True, exist_ok=True)
    mask_dir = args.output / "masks"; mask_dir.mkdir(exist_ok=True)
    manifest = []
    for i, image_id in enumerate(ids):
        meta = coco.imgs[image_id]
        image_path = args.images / meta["file_name"]
        if not image_path.exists():
            raise FileNotFoundError(image_path)
        mask = np.zeros((meta["height"], meta["width"]), dtype=np.uint8)
        for annotation in coco.loadAnns(coco.getAnnIds(imgIds=[image_id])):
            canonical = category_map.get(annotation["category_id"])
            if canonical is not None and annotation.get("segmentation"):
                mask[coco.annToMask(annotation).astype(bool)] = canonical
        output_mask = mask_dir / f"{image_id}.png"
        Image.fromarray(mask).save(output_mask)
        ratio = i / max(len(ids), 1)
        split = "train" if ratio < 0.8 else "val" if ratio < 0.9 else "test"
        manifest.append({"image": str(image_path.resolve()), "mask": str(output_mask.resolve()), "split": split})
    (args.output / "manifest.jsonl").write_text("\n".join(json.dumps(row) for row in manifest) + "\n")
    print(f"Prepared {len(manifest)} images; class 0 is background")


if __name__ == "__main__":
    main()
