"""Train RGB-only Nutrition5k regression baseline from a prepared JSONL manifest.

Rows: {"image":"...jpg","split":"train|val|test","mass_g":...,"calories":...,
"protein":...,"carbs":...,"fat":...}. Add segmentation/depth channels only after
independent validation; fixed-rig Nutrition5k results do not imply phone accuracy.
"""
import argparse
import json
from pathlib import Path

import torch
from PIL import Image
from torch.utils.data import DataLoader, Dataset
from torchvision.models import mobilenet_v3_small
from torchvision.transforms import functional as TF

TARGETS = ("mass_g", "calories", "protein", "carbs", "fat")
SCALE = torch.tensor([500.0, 1000.0, 100.0, 100.0, 100.0])


class NutritionRows(Dataset):
    def __init__(self, manifest, split):
        self.rows = [json.loads(line) for line in Path(manifest).read_text().splitlines()]
        self.rows = [row for row in self.rows if row["split"] == split]

    def __len__(self):
        return len(self.rows)

    def __getitem__(self, index):
        row = self.rows[index]
        image = Image.open(row["image"]).convert("RGB").resize((224, 224))
        return TF.to_tensor(image), torch.tensor([float(row[key]) for key in TARGETS])


def create_model():
    model = mobilenet_v3_small(weights=None)
    model.classifier[3] = torch.nn.Linear(model.classifier[3].in_features, len(TARGETS))
    return model


def evaluate(model, loader, device):
    model.eval(); total = torch.zeros(len(TARGETS)); count = 0
    with torch.no_grad():
        for images, targets in loader:
            pred = model(images.to(device)).cpu().clamp_min(0) * SCALE
            total += (pred - targets).abs().sum(0); count += len(images)
    return {name + "_mae": value for name, value in zip(TARGETS, (total / max(count, 1)).tolist())}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--checkpoint", default="ml/checkpoints/portion.pt")
    parser.add_argument("--resume")
    parser.add_argument("--eval-only", action="store_true")
    parser.add_argument("--eval-split", choices=["val", "test"], default="test")
    args = parser.parse_args()
    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = create_model().to(device)
    if args.resume:
        model.load_state_dict(torch.load(args.resume, map_location=device, weights_only=True)["model"])
    if args.eval_only:
        if not args.resume:
            raise ValueError("--eval-only requires --resume")
        loader = DataLoader(NutritionRows(args.manifest, args.eval_split), batch_size=args.batch_size)
        print(json.dumps(evaluate(model, loader, device))); return
    train = DataLoader(NutritionRows(args.manifest, "train"), batch_size=args.batch_size, shuffle=True)
    val = DataLoader(NutritionRows(args.manifest, "val"), batch_size=args.batch_size)
    optimizer = torch.optim.AdamW(model.parameters(), lr=1e-4)
    Path(args.checkpoint).parent.mkdir(parents=True, exist_ok=True)
    for epoch in range(args.epochs):
        model.train()
        for images, targets in train:
            output = model(images.to(device))
            loss = torch.nn.functional.smooth_l1_loss(output, targets.to(device) / SCALE.to(device))
            optimizer.zero_grad(); loss.backward(); optimizer.step()
        print(json.dumps({"epoch": epoch + 1, **evaluate(model, val, device)}))
        torch.save({"model": model.state_dict(), "epoch": epoch + 1}, args.checkpoint)


if __name__ == "__main__":
    main()
