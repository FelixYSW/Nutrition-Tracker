#!/usr/bin/env python3
"""Train Model B (portion mass and nutrition estimation) on Nutrition5k.

    python -m ml.nutrition_estimation.train --inputs rgb
    python -m ml.nutrition_estimation.train --inputs rgb,seg --seg-dir ml/data/n5k_masks
    python -m ml.nutrition_estimation.train --inputs rgb,depth
    python -m ml.nutrition_estimation.train --inputs rgb,seg,depth --seg-dir ml/data/n5k_masks

Only the RGB variant can ship in V1, because the app has no depth input and
runs Model A separately. The other variants exist to measure whether those
signals are worth adding later (spec sections 20, 21).

There is no public Malaysian portion/mass dataset at this scale, so this model
is trained on Nutrition5k alone and its accuracy on local dishes is unverified.
"""
from __future__ import annotations

import argparse
import json
import math
import time
from pathlib import Path

import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader
from tqdm import tqdm

from ml.common import MANIFESTS, RUNS, pick_device, seed_everything
from ml.nutrition_estimation.dataset import TARGETS, Nutrition5kDataset, read_manifest, target_stats
from ml.nutrition_estimation.evaluate import evaluate
from ml.nutrition_estimation.model import NutritionEstimator

# Calories matter most to the user; mass drives everything else.
TASK_WEIGHTS = {"mass": 1.0, "calories": 1.5, "protein": 1.0, "carbs": 1.0, "fat": 1.0}


def normalise_input(x: torch.Tensor) -> torch.Tensor:
    """ImageNet-normalise the RGB channels only; extra channels are already 0..1."""
    mean = torch.tensor([0.485, 0.456, 0.406], device=x.device).view(1, 3, 1, 1)
    std = torch.tensor([0.229, 0.224, 0.225], device=x.device).view(1, 3, 1, 1)
    rgb = (x[:, :3] - mean) / std
    return torch.cat([rgb, x[:, 3:]], dim=1) if x.shape[1] > 3 else rgb


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--manifest", type=Path, default=MANIFESTS / "nutrition5k.csv")
    parser.add_argument("--inputs", default="rgb", help="comma list from rgb,seg,depth")
    parser.add_argument("--seg-dir", type=Path)
    parser.add_argument("--depth-dir", type=Path, help="estimated-depth PNGs; default uses sensor depth")
    parser.add_argument("--backbone", default="mobilenet_v3_large",
                        choices=["mobilenet_v3_large", "efficientnet_b0"])
    parser.add_argument("--size", type=int, default=256)
    parser.add_argument("--epochs", type=int, default=60)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--lr", type=float, default=5e-4)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--run-name", default=None)
    args = parser.parse_args()

    inputs = tuple(part.strip() for part in args.inputs.split(",") if part.strip())
    if inputs[0] != "rgb" or not set(inputs) <= {"rgb", "seg", "depth"}:
        raise SystemExit("--inputs must start with rgb and use only rgb, seg, depth")

    run_dir = RUNS / (args.run_name or f"model_b_{'_'.join(inputs)}_{args.backbone}")
    run_dir.mkdir(parents=True, exist_ok=True)
    seed_everything(args.seed)
    device = pick_device()

    rows = read_manifest(args.manifest)
    train_rows = [r for r in rows if r["split"] == "train"]
    val_rows = [r for r in rows if r["split"] == "val"]
    stats = target_stats(train_rows)

    def make(rows_, train):
        return Nutrition5kDataset(rows_, stats, args.size, train, inputs, args.seg_dir, args.depth_dir)

    train_ds, val_ds = make(train_rows, True), make(val_rows, False)
    train_loader = DataLoader(train_ds, batch_size=args.batch_size, shuffle=True,
                              num_workers=args.workers, drop_last=True,
                              pin_memory=device.type == "cuda")
    val_loader = DataLoader(val_ds, batch_size=args.batch_size, num_workers=args.workers)

    model = NutritionEstimator(args.backbone, train_ds.channels).to(device)
    optimiser = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.OneCycleLR(
        optimiser, max_lr=args.lr, total_steps=args.epochs * max(1, len(train_loader)), pct_start=0.1)
    weights = torch.tensor([TASK_WEIGHTS[t] for t in TARGETS], device=device)
    scaler = torch.cuda.amp.GradScaler(enabled=device.type == "cuda")

    best, history = math.inf, []
    for epoch in range(1, args.epochs + 1):
        model.train()
        started, running, batches = time.time(), 0.0, 0
        for x, target, _ in tqdm(train_loader, desc=f"epoch {epoch}/{args.epochs}"):
            x, target = normalise_input(x.to(device)), target.to(device)
            with torch.autocast(device_type=device.type, enabled=device.type == "cuda"):
                prediction = model(x)
            loss = (F.smooth_l1_loss(prediction.float(), target, reduction="none") * weights).mean()
            optimiser.zero_grad(set_to_none=True)
            scaler.scale(loss).backward()
            scaler.step(optimiser)
            scaler.update()
            scheduler.step()
            running, batches = running + loss.item(), batches + 1

        metrics = evaluate(model, val_loader, stats, device, normalise_input)
        entry = {"epoch": epoch, "seconds": round(time.time() - started),
                 "train_loss": running / max(1, batches), **metrics}
        history.append(entry)
        print(json.dumps(entry))

        checkpoint = {"model": model.state_dict(), "stats": stats, "inputs": inputs,
                      "channels": train_ds.channels, "backbone": args.backbone,
                      "size": args.size, "epoch": epoch, "metrics": metrics}
        torch.save(checkpoint, run_dir / "last.pt")
        if metrics["calories_mae"] < best:
            best = metrics["calories_mae"]
            torch.save(checkpoint, run_dir / "best.pt")

    (run_dir / "history.json").write_text(json.dumps(history, indent=2))
    print(f"Done. Best calorie MAE {best:.1f} kcal -> {run_dir / 'best.pt'}")


if __name__ == "__main__":
    main()
