#!/usr/bin/env python3
"""Export Model A to Core ML as IngredientSegmenter.mlpackage.

The exported model takes raw RGB pixels (0-255, normalised inside the model)
and returns two vectors, one value per class:

  class_confidence  blend of the presence head and the mean segmentation
                    probability over the pixels the class wins
  class_area        fraction of the image the class wins

The full mask is reduced inside the model, so the app never decodes a pixel map.
Class labels (canonical ontology IDs) are stored in the model metadata under
"labels". These names must match CoreMLIngredientRecognitionService.SummaryOutput.

Usage:
    python -m ml.ingredient_segmentation.export --checkpoint ml/runs/model_a_malaysian/best.pt
    # then copy ml/exports/IngredientSegmenter.mlpackage into NutritionTracker/Resources/
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import coremltools as ct
import torch
from torch import nn

from ml.common import IMAGENET_MEAN, IMAGENET_STD, ROOT
from ml.ingredient_segmentation.model import load_checkpoint


class SummaryWrapper(nn.Module):
    def __init__(self, model: nn.Module) -> None:
        super().__init__()
        self.model = model
        self.register_buffer("mean", torch.tensor(IMAGENET_MEAN).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(IMAGENET_STD).view(1, 3, 1, 1))

    def forward(self, image: torch.Tensor):
        x = (image - self.mean) / self.std
        seg, presence = self.model(x)
        probs = torch.softmax(seg, dim=1)
        winners = (probs >= probs.max(dim=1, keepdim=True).values).float()
        area = winners.mean(dim=(2, 3))
        region_confidence = (probs * winners).sum(dim=(2, 3)) / winners.sum(dim=(2, 3)).clamp(min=1.0)
        confidence = 0.5 * torch.sigmoid(presence) + 0.5 * region_confidence
        return confidence, area


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--out", type=Path, default=ROOT / "ml" / "exports" / "IngredientSegmenter.mlpackage")
    parser.add_argument("--fp32", action="store_true", help="export full precision (larger)")
    args = parser.parse_args()

    model, checkpoint = load_checkpoint(args.checkpoint)
    size, labels = checkpoint["size"], checkpoint["labels"]
    wrapper = SummaryWrapper(model).eval()

    example = torch.rand(1, 3, size, size) * 255
    traced = torch.jit.trace(wrapper, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, size, size), scale=1 / 255.0,
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="class_confidence"), ct.TensorType(name="class_area")],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT32 if args.fp32 else ct.precision.FLOAT16,
    )
    mlmodel.short_description = "Food / ingredient recognition (Model A). Outputs are estimates."
    mlmodel.author = "NutritionTracker ml/ingredient_segmentation"
    mlmodel.license = "Model: BSD-3 (torchvision). Training data licences: see README."
    mlmodel.user_defined_metadata["labels"] = json.dumps(labels)
    mlmodel.user_defined_metadata["input_size"] = str(size)
    mlmodel.user_defined_metadata["stage"] = str(checkpoint.get("stage"))

    args.out.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(args.out))

    # Sanity check: the traced wrapper and the converted model agree.
    if hasattr(mlmodel, "predict"):
        try:
            from PIL import Image
            pil = Image.fromarray((example[0].permute(1, 2, 0).numpy()).astype("uint8"))
            out = mlmodel.predict({"image": pil})
            print("Core ML output shapes:", {k: v.shape for k, v in out.items()})
        except Exception as error:  # prediction only works on macOS
            print(f"(Skipped Core ML prediction check: {error})")

    print(f"Saved {args.out} with {len(labels)} classes at {size}x{size}.")
    print("Copy it to NutritionTracker/Resources/ and regenerate the Xcode project.")


if __name__ == "__main__":
    main()
