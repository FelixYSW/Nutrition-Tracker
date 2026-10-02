"""Shared helpers for both training pipelines."""
from __future__ import annotations

import json
import os
import random
import time
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[1]

# Overridable so data can sit on fast local disk while checkpoints go to
# persistent storage - e.g. on Colab, data in /content and runs on Google Drive.
DATA = Path(os.environ.get("NT_DATA_DIR", ROOT / "ml" / "data"))
MANIFESTS = DATA / "manifests"
RUNS = Path(os.environ.get("NT_RUNS_DIR", ROOT / "ml" / "runs"))

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


class TimeBudget:
    """Stops training cleanly before a hosted session (e.g. free Colab) is cut off.

    After each epoch, training asks whether another epoch of the same length
    still fits. If not, it saves and exits, and `--resume` continues later.
    """

    def __init__(self, max_minutes: float | None) -> None:
        self.deadline = time.time() + max_minutes * 60 if max_minutes else None
        self.longest_epoch = 0.0

    def record(self, epoch_seconds: float) -> None:
        self.longest_epoch = max(self.longest_epoch, epoch_seconds)

    def another_epoch_fits(self) -> bool:
        if self.deadline is None:
            return True
        return time.time() + self.longest_epoch * 1.1 < self.deadline


def save_atomic(state: dict, path: Path) -> None:
    """Writes a checkpoint via a temp file, so a disconnect mid-write (common
    on Colab with Google Drive) cannot leave a corrupt last.pt behind."""
    tmp = path.with_suffix(path.suffix + ".tmp")
    torch.save(state, tmp)
    os.replace(tmp, path)


def normalise(images: torch.Tensor) -> torch.Tensor:
    mean = torch.tensor(IMAGENET_MEAN, device=images.device).view(1, 3, 1, 1)
    std = torch.tensor(IMAGENET_STD, device=images.device).view(1, 3, 1, 1)
    return (images - mean) / std
