#!/usr/bin/env python3
"""Generate food-mask channels for Model B's rgb+seg variant using Model A.

Nutrition5k has no segmentation labels, so the mask comes from a trained
Model A: each pixel stores 1 - P(background), scaled to 0-255.

    python -m ml.nutrition_estimation.pseudo_masks \
        --checkpoint ml/runs/model_a_base/best.pt --out ml/data/n5k_masks
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from torchvision.transforms.v2 import functional as TF
from tqdm import tqdm

from ml.common import MANIFESTS, normalise, pick_device
from ml.ingredient_segmentation.model import load_checkpoint
from ml.nutrition_estimation.dataset import read_manifest


@torch.no_grad()
def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, default=MANIFESTS / "nutrition5k.csv")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    device = pick_device()
    model, checkpoint = load_checkpoint(args.checkpoint, device)
    model.to(device).eval()
    size = checkpoint["size"]
    background = checkpoint["labels"].index("background")
    args.out.mkdir(parents=True, exist_ok=True)

    for row in tqdm(read_manifest(args.manifest)):
        image = Image.open(row["image"]).convert("RGB")
        x = TF.to_dtype(TF.pil_to_tensor(image.resize((size, size), Image.BILINEAR)),
                        torch.float32, scale=True).unsqueeze(0).to(device)
        seg, _ = model(normalise(x))
        food = 1 - torch.softmax(seg, dim=1)[0, background]
        mask = (food.clamp(0, 1).cpu().numpy() * 255).astype(np.uint8)
        Image.fromarray(mask).resize(image.size, Image.BILINEAR).save(args.out / f"{row['dish_id']}.png")

    print(f"Wrote masks to {args.out}")


if __name__ == "__main__":
    main()
