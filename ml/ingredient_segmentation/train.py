"""Train a mobile semantic segmenter from a prepared image/mask manifest.

Manifest JSONL: {"image":"...jpg", "mask":"...png", "split":"train|val|test"}.
Mask pixels are integer class indices, 0 background, 255 ignore. Dataset adapters must
map each source's labels through ml/config/ontology.json before producing this manifest.
"""
import argparse
import json
import random
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from torch.utils.data import DataLoader, Dataset
from torchvision.models.segmentation import deeplabv3_mobilenet_v3_large
from torchvision.transforms import functional as TF


class SegmentationRows(Dataset):
    def __init__(self, manifest, split, size=384):
        self.rows = [json.loads(line) for line in Path(manifest).read_text().splitlines()]
        self.rows = [row for row in self.rows if row["split"] == split]
        self.size = size
        self.augment = split == "train"

    def __len__(self):
        return len(self.rows)

    def __getitem__(self, index):
        row = self.rows[index]
        image = Image.open(row["image"]).convert("RGB").resize((self.size, self.size))
        mask = Image.open(row["mask"]).resize((self.size, self.size), Image.Resampling.NEAREST)
        if self.augment and random.random() < 0.5:
            image = TF.hflip(image); mask = TF.hflip(mask)
        if self.augment:
            image = TF.adjust_brightness(image, random.uniform(0.85, 1.15))
        return TF.to_tensor(image), torch.from_numpy(np.array(mask, dtype=np.int64))


def evaluate(model, loader, classes, device):
    matrix = torch.zeros((classes, classes), dtype=torch.int64)
    model.eval()
    with torch.no_grad():
        for images, masks in loader:
            pred = model(images.to(device))["out"].argmax(1).cpu()
            valid = (masks != 255) & (masks >= 0) & (masks < classes)
            counts = torch.bincount((masks[valid] * classes + pred[valid]).reshape(-1), minlength=classes * classes)
            matrix += counts.reshape(classes, classes)
    tp = matrix.diag().float()
    precision = tp / matrix.sum(0).clamp_min(1)
    recall = tp / matrix.sum(1).clamp_min(1)
    iou = tp / (matrix.sum(0) + matrix.sum(1) - tp).clamp_min(1)
    return {"precision": precision.tolist(), "recall": recall.tolist(), "mask_iou": iou.tolist(),
            "mean_mask_iou": iou.mean().item()}


def load_for_expansion(model, checkpoint):
    current = model.state_dict()
    for key, old in checkpoint["model"].items():
        if key not in current:
            continue
        if current[key].shape == old.shape:
            current[key] = old
        elif len(current[key].shape) == len(old.shape) and current[key].shape[1:] == old.shape[1:]:
            # Ontology only appends classes; retain existing classifier channels.
            count = min(current[key].shape[0], old.shape[0])
            current[key][:count] = old[:count]
    model.load_state_dict(current)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--classes", type=int, required=True)
    parser.add_argument("--epochs", type=int, default=20)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--checkpoint", default="ml/checkpoints/segmentation.pt")
    parser.add_argument("--resume")
    parser.add_argument("--eval-only", action="store_true")
    parser.add_argument("--eval-split", choices=["val", "test"], default="test")
    args = parser.parse_args()
    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = deeplabv3_mobilenet_v3_large(weights=None, weights_backbone=None, num_classes=args.classes).to(device)
    if args.resume:
        load_for_expansion(model, torch.load(args.resume, map_location=device, weights_only=True))
    if args.eval_only:
        if not args.resume:
            raise ValueError("--eval-only requires --resume")
        loader = DataLoader(SegmentationRows(args.manifest, args.eval_split), batch_size=args.batch_size)
        print(json.dumps(evaluate(model, loader, args.classes, device))); return
    train = DataLoader(SegmentationRows(args.manifest, "train"), batch_size=args.batch_size, shuffle=True)
    val = DataLoader(SegmentationRows(args.manifest, "val"), batch_size=args.batch_size)
    optimizer = torch.optim.AdamW(model.parameters(), lr=2e-4)
    Path(args.checkpoint).parent.mkdir(parents=True, exist_ok=True)
    for epoch in range(args.epochs):
        model.train()
        for images, masks in train:
            output = model(images.to(device))["out"]
            loss = torch.nn.functional.cross_entropy(output, masks.to(device), ignore_index=255)
            optimizer.zero_grad(); loss.backward(); optimizer.step()
        metrics = evaluate(model, val, args.classes, device)
        print(json.dumps({"epoch": epoch + 1, **metrics}))
        torch.save({"model": model.state_dict(), "classes": args.classes, "epoch": epoch + 1}, args.checkpoint)


if __name__ == "__main__":
    main()
