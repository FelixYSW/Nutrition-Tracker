"""Nutrition5k dataset for Model B.

Input channels are configurable so the four variants the spec asks to compare
can be trained from the same code (spec section 20):

    rgb               3 channels  (what ships in V1)
    rgb+seg           + 1 food-mask channel from Model A (pseudo_masks.py)
    rgb+depth         + 1 depth channel (Nutrition5k's sensor depth, or a
                        monocular estimate supplied as PNGs - spec section 21)
    rgb+seg+depth     both

Targets are log1p-transformed then standardised with train-set statistics,
which tames the long tail of large dishes. Export undoes both, so the Core ML
model outputs grams and kcal directly.
"""
from __future__ import annotations

import csv
import math
import random
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from torch.utils.data import Dataset
from torchvision.transforms import v2
from torchvision.transforms.v2 import functional as TF

TARGETS = ["mass", "calories", "protein", "carbs", "fat"]
DEPTH_MAX_MM = 1000.0


def read_manifest(path: Path) -> list[dict]:
    with path.open(encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def target_stats(rows: list[dict]) -> dict[str, list[float]]:
    values = np.array([[math.log1p(float(r[t])) for t in TARGETS] for r in rows])
    return {"mean": values.mean(axis=0).tolist(), "std": (values.std(axis=0) + 1e-6).tolist()}


class Nutrition5kDataset(Dataset):
    def __init__(self, rows: list[dict], stats: dict, size: int, train: bool,
                 inputs: tuple[str, ...] = ("rgb",), seg_dir: Path | None = None,
                 depth_dir: Path | None = None) -> None:
        self.rows = rows
        self.mean = torch.tensor(stats["mean"])
        self.std = torch.tensor(stats["std"])
        self.size = size
        self.train = train
        self.inputs = inputs
        self.seg_dir = seg_dir
        self.depth_dir = depth_dir
        self.jitter = v2.ColorJitter(0.25, 0.25, 0.25, 0.02)
        if "seg" in inputs and seg_dir is None:
            raise ValueError("inputs include 'seg' but no --seg-dir was given")

    @property
    def channels(self) -> int:
        return 3 + int("seg" in self.inputs) + int("depth" in self.inputs)

    def __len__(self) -> int:
        return len(self.rows)

    def _resize(self, image: Image.Image, nearest: bool = False) -> Image.Image:
        resample = Image.NEAREST if nearest else Image.BILINEAR
        # Square stretch, matching the app's Vision `.scaleFill`.
        return image.resize((self.size, self.size), resample)

    def _extra_channel(self, path: Path, scale: float) -> torch.Tensor:
        if not path.exists():
            return torch.zeros(1, self.size, self.size)
        array = np.array(self._resize(Image.open(path), nearest=True), dtype=np.float32)
        if array.ndim == 3:
            array = array[..., 0]
        return torch.from_numpy(np.clip(array / scale, 0.0, 1.0)).unsqueeze(0)

    def __getitem__(self, i: int):
        row = self.rows[i]
        rgb = TF.pil_to_tensor(self._resize(Image.open(row["image"]).convert("RGB")))
        if self.train:
            rgb = self.jitter(rgb)
        channels = [TF.to_dtype(rgb, torch.float32, scale=True)]

        if "seg" in self.inputs:
            channels.append(self._extra_channel(self.seg_dir / f"{row['dish_id']}.png", 255.0))
        if "depth" in self.inputs:
            depth_path = (self.depth_dir / f"{row['dish_id']}.png") if self.depth_dir else Path(row["depth"] or "")
            channels.append(self._extra_channel(depth_path, DEPTH_MAX_MM))

        x = torch.cat(channels, dim=0)
        if self.train:
            # Overhead plates have no canonical orientation, so exact flips and
            # 90-degree turns are safe and apply identically to every channel.
            if random.random() < 0.5:
                x = torch.flip(x, dims=[2])
            if random.random() < 0.5:
                x = torch.flip(x, dims=[1])
            x = torch.rot90(x, k=random.randint(0, 3), dims=[1, 2])

        raw = torch.tensor([float(row[t]) for t in TARGETS], dtype=torch.float32)
        target = (torch.log1p(raw) - self.mean) / self.std
        return x, target, raw
