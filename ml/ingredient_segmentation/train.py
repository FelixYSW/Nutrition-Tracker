#!/usr/bin/env python3
"""Train Model A (food / ingredient recognition and segmentation).

Two stages (spec section 19):

  base       FoodSeg103 masks only.
             python -m ml.ingredient_segmentation.train --stage base \
                 --manifests ml/data/manifests/foodseg103.jsonl

  malaysian  Fine-tune from the base checkpoint, adding Malaysian classes. Mix
             FoodSeg103 back in at a low weight so the model does not forget it.
             python -m ml.ingredient_segmentation.train --stage malaysian \
                 --init ml/runs/model_a_base/best.pt \
                 --manifests ml/data/manifests/foodseg103.jsonl \
                             ml/data/manifests/roboflow_mfr.jsonl \
                             ml/data/manifests/malaysia_food11.jsonl \
                             ml/data/manifests/mf150.jsonl \
                 --source-weight foodseg103=0.3

Checkpoints and a metrics log go to ml/runs/<run-name>/ (gitignored).
"""
from __future__ import annotations

import argparse
import json
import math
import time
from collections import Counter
from pathlib import Path

import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader, WeightedRandomSampler
from tqdm import tqdm

from ml.common import (RUNS, TimeBudget, normalise, pick_device, read_jsonl, save_atomic,
                       seed_everything)
from ml.ingredient_segmentation.dataset import IGNORE, IngredientDataset, collect_labels
from ml.ingredient_segmentation.evaluate import evaluate
from ml.ingredient_segmentation.model import IngredientSegmenter, expand_classes, load_checkpoint


def compute_loss(seg_logits, presence_logits, masks, presence, seg_weight, presence_weight):
    # Segmentation: per-sample mean over valid pixels, weighted by how much the
    # mask is trusted. Image-label samples have no valid pixels and weight 0.
    ce = F.cross_entropy(seg_logits, masks, ignore_index=IGNORE, reduction="none")
    valid = (masks != IGNORE).float()
    per_sample = (ce * valid).sum(dim=(1, 2)) / valid.sum(dim=(1, 2)).clamp(min=1.0)
    seg_loss = (per_sample * seg_weight).sum() / seg_weight.sum().clamp(min=1e-6)

    # Presence: only classes whose status is known contribute.
    known = (presence >= 0).float()
    bce = F.binary_cross_entropy_with_logits(presence_logits, presence.clamp(min=0),
                                             reduction="none")
    presence_loss = (bce * known).sum() / known.sum().clamp(min=1.0)
    return seg_loss + presence_weight * presence_loss, seg_loss.detach(), presence_loss.detach()


def make_sampler(records: list[dict], weights_arg: list[str]) -> WeightedRandomSampler | None:
    if not weights_arg:
        return None
    source_weights = {}
    for item in weights_arg:
        name, value = item.split("=")
        source_weights[name] = float(value)
    counts = Counter(r["source"] for r in records)
    weights = [source_weights.get(r["source"], 1.0) / counts[r["source"]] for r in records]
    return WeightedRandomSampler(weights, num_samples=len(records), replacement=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--stage", choices=["base", "malaysian"], required=True)
    parser.add_argument("--manifests", type=Path, nargs="+", required=True)
    parser.add_argument("--init", type=Path, help="checkpoint to fine-tune from")
    parser.add_argument("--run-name", default=None)
    parser.add_argument("--epochs", type=int, default=None)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--lr", type=float, default=None)
    parser.add_argument("--size", type=int, default=384)
    parser.add_argument("--presence-weight", type=float, default=0.5)
    parser.add_argument("--source-weight", nargs="*", default=[],
                        help="per-source sampling weight, e.g. foodseg103=0.3")
    parser.add_argument("--freeze-backbone-epochs", type=int, default=None)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--resume", action="store_true",
                        help="continue from <run>/last.pt if it exists (e.g. after a Colab disconnect)")
    parser.add_argument("--max-minutes", type=float, default=None,
                        help="stop cleanly before this many minutes; resume later with --resume")
    args = parser.parse_args()

    # Stage defaults: fine-tuning uses fewer epochs and a lower learning rate.
    base = args.stage == "base"
    epochs = args.epochs or (40 if base else 15)
    lr = args.lr or (3e-4 if base else 1e-4)
    freeze_epochs = args.freeze_backbone_epochs if args.freeze_backbone_epochs is not None else (0 if base else 3)
    run_dir = RUNS / (args.run_name or f"model_a_{args.stage}")
    run_dir.mkdir(parents=True, exist_ok=True)
    last_path = run_dir / "last.pt"

    seed_everything(args.seed)
    device = pick_device()
    budget = TimeBudget(args.max_minutes)

    records = [r for path in args.manifests for r in read_jsonl(path)]
    train_records = [r for r in records if r["split"] == "train"]
    val_records = [r for r in records if r["split"] == "val"]
    if not train_records:
        raise SystemExit("No training records found in the given manifests.")

    resume_state = None
    if args.resume and last_path.exists():
        resume_state = torch.load(last_path, map_location="cpu", weights_only=False)
        # The label space is fixed by the run being resumed, never re-derived.
        labels = resume_state["labels"]
        model = IngredientSegmenter(len(labels), pretrained_backbone=False)
        model.load_state_dict(resume_state["model"])
        print(f"Resuming {run_dir.name} after epoch {resume_state['epoch']}")
    elif args.init:
        model, checkpoint = load_checkpoint(args.init)
        labels = collect_labels(records, existing=checkpoint["labels"])
        model = expand_classes(model, checkpoint["labels"], labels)
        added = len(labels) - len(checkpoint["labels"])
        print(f"Fine-tuning from {args.init}: {len(labels)} classes ({added} new)")
    else:
        labels = collect_labels(records)
        model = IngredientSegmenter(len(labels))
        print(f"Training from ImageNet backbone: {len(labels)} classes")
    model.to(device)

    train_ds = IngredientDataset(train_records, labels, args.size, train=True)
    val_ds = IngredientDataset(val_records, labels, args.size, train=False)
    sampler = make_sampler(train_records, args.source_weight)
    train_loader = DataLoader(train_ds, batch_size=args.batch_size, shuffle=sampler is None,
                              sampler=sampler, num_workers=args.workers, drop_last=True,
                              pin_memory=device.type == "cuda")
    val_loader = DataLoader(val_ds, batch_size=args.batch_size, num_workers=args.workers)

    optimiser = torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=1e-4)
    total_steps = epochs * max(1, len(train_loader))
    scheduler = torch.optim.lr_scheduler.OneCycleLR(optimiser, max_lr=lr, total_steps=total_steps,
                                                    pct_start=0.1)
    scaler = torch.cuda.amp.GradScaler(enabled=device.type == "cuda")

    best_score, history, start_epoch = -math.inf, [], 1
    if resume_state:
        optimiser.load_state_dict(resume_state["optimiser"])
        scheduler.load_state_dict(resume_state["scheduler"])
        scaler.load_state_dict(resume_state["scaler"])
        best_score = resume_state["best_score"]
        history = resume_state["history"]
        start_epoch = resume_state["epoch"] + 1

    finished = True
    for epoch in range(start_epoch, epochs + 1):
        if not budget.another_epoch_fits():
            finished = False
            print(f"Time budget reached before epoch {epoch}. Re-run with --resume to continue.")
            break

        frozen = epoch <= freeze_epochs
        for parameter in model.backbone.parameters():
            parameter.requires_grad = not frozen

        model.train()
        totals = Counter()
        started = time.time()
        for images, masks, presence, seg_weight in tqdm(train_loader, desc=f"epoch {epoch}/{epochs}"):
            images = normalise(images.to(device, non_blocking=True))
            masks, presence = masks.to(device), presence.to(device)
            seg_weight = seg_weight.to(device)

            with torch.autocast(device_type=device.type, enabled=device.type == "cuda"):
                seg_logits, presence_logits = model(images)
            loss, seg_loss, pres_loss = compute_loss(seg_logits.float(), presence_logits.float(),
                                                     masks, presence, seg_weight,
                                                     args.presence_weight)
            optimiser.zero_grad(set_to_none=True)
            scaler.scale(loss).backward()
            scaler.step(optimiser)
            scaler.update()
            scheduler.step()
            totals.update(loss=loss.item(), seg=seg_loss.item(), presence=pres_loss.item(), n=1)

        metrics = evaluate(model, val_loader, labels, device) if val_records else {}
        budget.record(time.time() - started)
        # Base stage ranks on mIoU; the Malaysian stage, where most supervision
        # is image-level, ranks on presence mAP.
        score = metrics.get("miou" if base else "presence_map", -totals["loss"])
        entry = {"epoch": epoch, "seconds": round(time.time() - started),
                 "train_loss": totals["loss"] / max(1, totals["n"]),
                 "seg_loss": totals["seg"] / max(1, totals["n"]),
                 "presence_loss": totals["presence"] / max(1, totals["n"]),
                 **{k: v for k, v in metrics.items() if not isinstance(v, (list, dict))}}
        history.append(entry)
        print(json.dumps(entry))

        checkpoint = {"model": model.state_dict(), "labels": labels, "size": args.size,
                      "stage": args.stage, "epoch": epoch, "metrics": entry}
        if score > best_score:
            best_score = score
            save_atomic(checkpoint, run_dir / "best.pt")
            if metrics:
                (run_dir / "best_metrics.json").write_text(json.dumps(metrics, indent=2))
        # last.pt carries optimiser state too, so a resumed run continues exactly.
        save_atomic({**checkpoint, "optimiser": optimiser.state_dict(),
                     "scheduler": scheduler.state_dict(), "scaler": scaler.state_dict(),
                     "best_score": best_score, "history": history}, last_path)

    (run_dir / "history.json").write_text(json.dumps(history, indent=2))
    (run_dir / "labels.json").write_text(json.dumps(labels, indent=2))
    if finished:
        print(f"Done. Best checkpoint: {run_dir / 'best.pt'}")


if __name__ == "__main__":
    main()
