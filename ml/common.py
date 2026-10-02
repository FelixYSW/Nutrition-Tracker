"""Shared helpers for both training pipelines."""
from __future__ import annotations

import json
import random
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "ml" / "data"
MANIFESTS = DATA / "manifests"
RUNS = ROOT / "ml" / "runs"

# ImageNet statistics. Normalisation happens *inside* the exported Core ML
# model, so the app only ever feeds raw 0-255 pixels.
IMAGENET_MEAN = (0.485, 0.456, 0.406)
IMAGENET_STD = (0.229, 0.224, 0.225)


def seed_everything(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    torch.cuda.manual_seed_all(seed)


def pick_device() -> torch.device:
    if torch.cuda.is_available():
        return torch.device("cuda")
    if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def read_jsonl(path: Path) -> list[dict]:
    with path.open(encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def write_jsonl(path: Path, records: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")


def split_for(index: int, seed: int = 0, val: float = 0.1, test: float = 0.1) -> str:
    """Deterministic split for datasets that ship without one."""
    rng = random.Random(seed * 1_000_003 + index)
    roll = rng.random()
    if roll < test:
        return "test"
    if roll < test + val:
        return "val"
    return "train"


def normalise(images: torch.Tensor) -> torch.Tensor:
    mean = torch.tensor(IMAGENET_MEAN, device=images.device).view(1, 3, 1, 1)
    std = torch.tensor(IMAGENET_STD, device=images.device).view(1, 3, 1, 1)
    return (images - mean) / std
