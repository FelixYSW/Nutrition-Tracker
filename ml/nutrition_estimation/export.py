#!/usr/bin/env python3
"""Export Model B to Core ML as NutritionEstimator.mlpackage.

Input: raw RGB pixels (normalised inside the model). Outputs, each a
one-element tensor in real units: mass (g), calories (kcal), protein, carbs,
fat (g). These names match CoreMLPortionNutritionService's decoder.

Only an RGB-only checkpoint can be exported: the app has no depth input and
does not feed Model A's mask into Model B in V1.

Usage:
    python -m ml.nutrition_estimation.export --checkpoint ml/runs/model_b_rgb_mobilenet_v3_large/best.pt
"""
from __future__ import annotations

import argparse
from pathlib import Path

import coremltools as ct
import torch
from torch import nn

from ml.common import IMAGENET_MEAN, IMAGENET_STD, ROOT
from ml.nutrition_estimation.dataset import TARGETS
from ml.nutrition_estimation.model import load_checkpoint


class RealUnitsWrapper(nn.Module):
    def __init__(self, model: nn.Module, stats: dict) -> None:
        super().__init__()
        self.model = model
        self.register_buffer("mean_rgb", torch.tensor(IMAGENET_MEAN).view(1, 3, 1, 1))
        self.register_buffer("std_rgb", torch.tensor(IMAGENET_STD).view(1, 3, 1, 1))
        self.register_buffer("target_mean", torch.tensor(stats["mean"]))
        self.register_buffer("target_std", torch.tensor(stats["std"]))

    def forward(self, image: torch.Tensor):
        z = self.model((image - self.mean_rgb) / self.std_rgb)
        real = torch.clamp(torch.expm1(z * self.target_std + self.target_mean), min=0.0)
        return tuple(real[:, i] for i in range(len(TARGETS)))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--out", type=Path, default=ROOT / "ml" / "exports" / "NutritionEstimator.mlpackage")
    parser.add_argument("--fp32", action="store_true")
    args = parser.parse_args()

    model, checkpoint = load_checkpoint(args.checkpoint)
    if tuple(checkpoint["inputs"]) != ("rgb",):
        raise SystemExit(f"Checkpoint uses inputs {checkpoint['inputs']}; only an RGB-only "
                         "model can ship in the app. Train with --inputs rgb.")
    size = checkpoint["size"]
    wrapper = RealUnitsWrapper(model, checkpoint["stats"]).eval()
    traced = torch.jit.trace(wrapper, torch.rand(1, 3, size, size) * 255)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, size, size), scale=1 / 255.0,
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name=name) for name in TARGETS],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT32 if args.fp32 else ct.precision.FLOAT16,
    )
    mlmodel.short_description = ("Whole-dish mass and nutrition estimate (Model B). "
                                 "Approximate: trained on overhead Nutrition5k photos.")
    mlmodel.author = "NutritionTracker ml/nutrition_estimation"
    mlmodel.license = "Model: BSD-3 (torchvision). Nutrition5k: see its licence."
    mlmodel.user_defined_metadata["backbone"] = checkpoint["backbone"]
    mlmodel.user_defined_metadata["val_calories_mae"] = str(checkpoint["metrics"].get("calories_mae"))

    args.out.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(args.out))
    print(f"Saved {args.out}. Copy it to NutritionTracker/Resources/ and regenerate the project.")


if __name__ == "__main__":
    main()
