#!/usr/bin/env python3
"""Evaluate Model A.

Segmentation metrics (pixel accuracy, per-class IoU, mIoU) use only samples
with real pixel masks. Presence metrics (per-class precision / recall / AP,
macro mAP) use every sample whose label status is known, which is how the
image-level Malaysian sets get measured.

A note on "mask mAP": COCO-style mask mAP is defined for *instance*
segmentation. This model does semantic segmentation, so the honest equivalents
are per-class IoU for masks and per-class AP for presence; both are reported,
with Malaysian classes (canonical IDs starting "my.") broken out separately.

Usage:
    python -m ml.ingredient_segmentation.evaluate --checkpoint ml/runs/model_a_malaysian/best.pt \
        --manifests ml/data/manifests/foodseg103.jsonl ml/data/manifests/roboflow_mfr.jsonl \
        --split test
"""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import torch
from torch.utils.data import DataLoader

from ml.common import normalise, pick_device, read_jsonl
from ml.ingredient_segmentation.dataset import IGNORE, IngredientDataset


def average_precision(scores: torch.Tensor, targets: torch.Tensor) -> float | None:
    positives = int(targets.sum())
    if positives == 0:
        return None
    order = torch.argsort(scores, descending=True)
    hits = targets[order]
    cumulative = torch.cumsum(hits, dim=0)
    precision = cumulative / torch.arange(1, len(hits) + 1, dtype=torch.float32)
    return float((precision * hits).sum() / positives)


@torch.no_grad()
def evaluate(model, loader: DataLoader, labels: list[str], device) -> dict:
    model.eval()
    num_classes = len(labels)
    confusion = torch.zeros(num_classes, num_classes, dtype=torch.long)
    has_masks = False
    all_scores, all_targets = [], []

    for images, masks, presence, seg_weight in loader:
        seg_logits, presence_logits = model(normalise(images.to(device)))
        predictions = seg_logits.argmax(dim=1).cpu()

        # Only fully-masked samples (weight 1) count toward IoU; box masks are
        # too coarse to score pixels against.
        full = seg_weight == 1.0
        if full.any():
            has_masks = True
            truth = masks[full]
            pred = predictions[full]
            valid = truth != IGNORE
            confusion += torch.bincount(truth[valid] * num_classes + pred[valid],
                                        minlength=num_classes ** 2).view(num_classes, num_classes)

        all_scores.append(torch.sigmoid(presence_logits).cpu())
        all_targets.append(presence)

    metrics: dict = {}
    per_class = []

    if has_masks:
        intersection = confusion.diag().float()
        union = confusion.sum(0).float() + confusion.sum(1).float() - intersection
        iou = torch.where(union > 0, intersection / union.clamp(min=1), torch.full_like(union, float("nan")))
        foreground = [i for i, label in enumerate(labels) if label != "background"]
        valid_iou = iou[foreground][~torch.isnan(iou[foreground])]
        metrics["miou"] = float(valid_iou.mean()) if len(valid_iou) else 0.0
        metrics["pixel_accuracy"] = float(intersection.sum() / confusion.sum().clamp(min=1))
    else:
        iou = torch.full((num_classes,), float("nan"))

    scores = torch.cat(all_scores) if all_scores else torch.empty(0, num_classes)
    targets = torch.cat(all_targets) if all_targets else torch.empty(0, num_classes)
    aps, malaysian_aps = [], []

    for i, label in enumerate(labels):
        row = {"label": label, "iou": None if torch.isnan(iou[i]) else round(float(iou[i]), 4)}
        known = targets[:, i] >= 0 if len(targets) else torch.zeros(0, dtype=torch.bool)
        if label != "background" and known.any():
            s, t = scores[known, i], targets[known, i]
            ap = average_precision(s, t)
            predicted = s >= 0.5
            tp = int((predicted & (t == 1)).sum())
            row.update(
                support=int(t.sum()),
                ap=None if ap is None else round(ap, 4),
                precision=round(tp / max(1, int(predicted.sum())), 4),
                recall=round(tp / max(1, int(t.sum())), 4),
            )
            if ap is not None:
                aps.append(ap)
                if label.startswith("my."):
                    malaysian_aps.append(ap)
        per_class.append(row)

    metrics["presence_map"] = float(sum(aps) / len(aps)) if aps else 0.0
    metrics["malaysian_presence_map"] = (float(sum(malaysian_aps) / len(malaysian_aps))
                                         if malaysian_aps else None)
    metrics["per_class"] = per_class
    return metrics


def main() -> None:
    from ml.ingredient_segmentation.model import load_checkpoint

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--manifests", type=Path, nargs="+", required=True)
    parser.add_argument("--split", default="val")
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()

    device = pick_device()
    model, checkpoint = load_checkpoint(args.checkpoint, device)
    model.to(device)
    labels = checkpoint["labels"]
    records = [r for path in args.manifests for r in read_jsonl(path) if r["split"] == args.split]
    loader = DataLoader(IngredientDataset(records, labels, checkpoint["size"], train=False),
                        batch_size=args.batch_size)

    metrics = evaluate(model, loader, labels, device)
    out = args.out or args.checkpoint.with_name(f"eval_{args.split}.json")
    out.write_text(json.dumps(metrics, indent=2))
    with out.with_suffix(".csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=["label", "iou", "ap", "precision", "recall", "support"])
        writer.writeheader()
        writer.writerows(metrics["per_class"])

    summary = {k: v for k, v in metrics.items() if k != "per_class"}
    print(json.dumps(summary, indent=2))
    print(f"Per-class report: {out.with_suffix('.csv')}")


if __name__ == "__main__":
    main()
