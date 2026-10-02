"""Unified dataset over mask, box and image-label manifests.

Every sample yields:
    image     float tensor [3, S, S] in 0..1 (normalised later, on device)
    mask      long tensor  [S, S]   class index per pixel, 255 = ignore
    presence  float tensor [C]      1 present, 0 absent, -1 unknown
    seg_weight float                how much to trust the mask

Square resizing (not aspect-preserving) is deliberate: the app feeds Vision
with `.scaleFill`, so training sees the same stretch it will meet on-device.
"""
from __future__ import annotations

import numpy as np
import torch
from PIL import Image, ImageDraw
from torch.utils.data import Dataset
from torchvision import tv_tensors
from torchvision.transforms import v2
from torchvision.transforms.v2 import functional as TF

IGNORE = 255

# Trust placed in each kind of supervision for the segmentation loss.
SEG_WEIGHT = {"mask": 1.0, "boxes": 0.5, "image_labels": 0.0}


def build_transform(size: int, train: bool) -> v2.Compose:
    if train:
        return v2.Compose([
            v2.RandomResizedCrop((size, size), scale=(0.5, 1.0), ratio=(0.6, 1.66), antialias=True),
            v2.RandomHorizontalFlip(),
            # Rotation padding is marked ignore on the mask, never background.
            v2.RandomApply([v2.RandomRotation(15, fill={tv_tensors.Image: 0, tv_tensors.Mask: IGNORE})], p=0.3),
            v2.ColorJitter(0.3, 0.3, 0.3, 0.03),
        ])
    return v2.Compose([v2.Resize((size, size), antialias=True)])


class IngredientDataset(Dataset):
    def __init__(self, records: list[dict], labels: list[str], size: int, train: bool) -> None:
        self.records = records
        self.labels = labels
        self.index = {label: i for i, label in enumerate(labels)}
        self.size = size
        self.transform = build_transform(size, train)

    def __len__(self) -> int:
        return len(self.records)

    def _mask_from_png(self, record: dict) -> np.ndarray:
        raw = np.array(Image.open(record["mask"]))
        if raw.ndim == 3:
            raw = raw[..., 0]
        mask = np.full(raw.shape, IGNORE, dtype=np.uint8)
        for pixel_value, label in record["mask_labels"].items():
            target = self.index.get(label)
            if target is not None:
                mask[raw == int(pixel_value)] = target
        return mask

    def _mask_from_boxes(self, record: dict, width: int, height: int) -> np.ndarray:
        canvas = Image.new("L", (width, height), IGNORE)
        draw = ImageDraw.Draw(canvas)
        # Largest first so small items painted later are not swallowed.
        for x, y, w, h, label in sorted(record["boxes"], key=lambda b: -(b[2] * b[3])):
            target = self.index.get(label)
            if target is not None:
                draw.rectangle([x, y, x + w, y + h], fill=target)
        return np.array(canvas, dtype=np.uint8)

    def __getitem__(self, i: int):
        record = self.records[i]
        image = Image.open(record["image"]).convert("RGB")
        width, height = image.size
        kind = record["kind"]

        if kind == "mask":
            mask = self._mask_from_png(record)
        elif kind == "boxes":
            mask = self._mask_from_boxes(record, width, height)
        else:
            mask = np.full((height, width), IGNORE, dtype=np.uint8)

        image_t = tv_tensors.Image(TF.pil_to_tensor(image))
        mask_t = tv_tensors.Mask(torch.from_numpy(mask).unsqueeze(0))
        image_t, mask_t = self.transform(image_t, mask_t)
        mask_t = mask_t.squeeze(0).long()

        image_f = TF.to_dtype(image_t, torch.float32, scale=True)
        presence = self._presence(record, mask_t)
        return image_f, mask_t, presence, torch.tensor(SEG_WEIGHT[kind], dtype=torch.float32)

    def _presence(self, record: dict, mask: torch.Tensor) -> torch.Tensor:
        presence = torch.full((len(self.labels),), -1.0)
        kind = record["kind"]

        if kind == "mask":
            known = {self.index[l] for l in record["mask_labels"].values() if l in self.index}
            for idx in known:
                presence[idx] = 0.0
            for idx in torch.unique(mask).tolist():
                if idx != IGNORE:
                    presence[idx] = 1.0
        elif kind == "boxes":
            for label in record["label_set"]:
                if label in self.index:
                    presence[self.index[label]] = 0.0
            for idx in torch.unique(mask).tolist():
                if idx != IGNORE:
                    presence[idx] = 1.0
        else:
            for label in record["label_set"]:
                if label in self.index:
                    presence[self.index[label]] = 0.0
            for label in record["image_labels"]:
                if label in self.index:
                    presence[self.index[label]] = 1.0

        # Background is never a presence target.
        if "background" in self.index:
            presence[self.index["background"]] = -1.0
        return presence


def collect_labels(records: list[dict], existing: list[str] | None = None) -> list[str]:
    """Stable label space: existing order kept, new labels appended sorted.

    Appending rather than re-sorting is what lets the Malaysian stage add
    classes without disturbing the indices learnt in the base stage.
    """
    found: set[str] = set()
    for record in records:
        if record["kind"] == "mask":
            found.update(record["mask_labels"].values())
        elif record["kind"] == "boxes":
            found.update(box[4] for box in record["boxes"])
            found.update(record["label_set"])
        else:
            found.update(record["image_labels"])
            found.update(record["label_set"])
    labels = list(existing) if existing else ["background"]
    labels += sorted(found - set(labels) - {"background"})
    return labels
