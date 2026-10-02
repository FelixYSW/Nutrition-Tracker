#!/usr/bin/env python3
"""Evaluate Model B: MAE per target in real units, plus MAE as a percentage of
the mean (the form the Nutrition5k paper reports).

Run all four input variants on the same split to compare them:

    for run in ml/runs/model_b_*; do
        python -m ml.nutrition_estimation.evaluate --checkpoint $run/best.pt --split test
    done
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch
from torch.utils.data import DataLoader

from ml.common import MANIFESTS, pick_device
from ml.nutrition_estimation.dataset import TARGETS, Nutrition5kDataset, read_manifest


@torch.no_grad()
def evaluate(model, loader: DataLoader, stats: dict, device, normalise_input) -> dict:
    model.eval()
    mean = torch.tensor(stats["mean"], device=device)
    std = torch.tensor(stats["std"], device=device)
    errors, truths = [], []
    for x, _, raw in loader:
        prediction = model(normalise_input(x.to(device)))
        real = torch.expm1(prediction * std + mean).clamp(min=0)
        errors.append((real - raw.to(device)).abs().cpu())
        truths.append(raw)
    if not errors:
        return {f"{t}_mae": float("nan") for t in TARGETS}

    error = torch.cat(errors)
    truth = torch.cat(truths)
    metrics = {}
    for i, target in enumerate(TARGETS):
        mae = float(error[:, i].mean())
        metrics[f"{target}_mae"] = round(mae, 2)
        metrics[f"{target}_mae_pct"] = round(100 * mae / max(1e-6, float(truth[:, i].mean())), 1)
    metrics["samples"] = int(len(error))
    return metrics


def main() -> None:
    from ml.nutrition_estimation.model import load_checkpoint
    from ml.nutrition_estimation.train import normalise_input

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, default=MANIFESTS / "nutrition5k.csv")
    parser.add_argument("--split", default="test")
    parser.add_argument("--seg-dir", type=Path)
    parser.add_argument("--depth-dir", type=Path)
    args = parser.parse_args()

    device = pick_device()
    model, checkpoint = load_checkpoint(args.checkpoint, device)
    model.to(device)
    rows = [r for r in read_manifest(args.manifest) if r["split"] == args.split]
    dataset = Nutrition5kDataset(rows, checkpoint["stats"], checkpoint["size"], False,
                                 tuple(checkpoint["inputs"]), args.seg_dir, args.depth_dir)
    metrics = evaluate(model, DataLoader(dataset, batch_size=32), checkpoint["stats"],
                       device, normalise_input)
    metrics.update(inputs="+".join(checkpoint["inputs"]), backbone=checkpoint["backbone"],
                   split=args.split)

    out = args.checkpoint.with_name(f"eval_{args.split}.json")
    out.write_text(json.dumps(metrics, indent=2))
    print(json.dumps(metrics, indent=2))


if __name__ == "__main__":
    main()
