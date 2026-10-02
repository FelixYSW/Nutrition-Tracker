"""Model A: DeepLabV3 + MobileNetV3-Large with an extra presence head.

Licence: torchvision models and weights are BSD-3-Clause, which keeps the
architecture free for distribution. A YOLO-segmentation model would also work
but Ultralytics' implementation is AGPL-3.0 - if you swap one in, check that
licence against how you distribute the app. The iOS adapter reads either this
model's summary outputs or a standard object detector, so the model is
replaceable without app changes (spec section 19).

Two heads share the backbone:
  segmentation  per-pixel class logits (trained on FoodSeg103 masks and,
                weakly, on Roboflow boxes)
  presence      per-class multi-label logits (trained on everything,
                including image-level labels from Malaysia Food-11 and MF-150)
"""
from __future__ import annotations

import torch
import torch.nn.functional as F
from torch import nn
from torchvision.models import MobileNet_V3_Large_Weights
from torchvision.models.segmentation import deeplabv3_mobilenet_v3_large

BACKBONE_CHANNELS = 960


class IngredientSegmenter(nn.Module):
    def __init__(self, num_classes: int, pretrained_backbone: bool = True) -> None:
        super().__init__()
        weights = MobileNet_V3_Large_Weights.IMAGENET1K_V1 if pretrained_backbone else None
        base = deeplabv3_mobilenet_v3_large(weights=None, weights_backbone=weights,
                                            num_classes=num_classes, aux_loss=False)
        self.backbone = base.backbone
        self.classifier = base.classifier
        self.presence = nn.Sequential(
            nn.AdaptiveAvgPool2d(1),
            nn.Flatten(),
            nn.Dropout(0.2),
            nn.Linear(BACKBONE_CHANNELS, num_classes),
        )

    def forward(self, x: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        features = self.backbone(x)["out"]
        seg = self.classifier(features)
        seg = F.interpolate(seg, size=x.shape[-2:], mode="bilinear", align_corners=False)
        return seg, self.presence(features)

    @property
    def num_classes(self) -> int:
        return self.presence[-1].out_features


def expand_classes(model: IngredientSegmenter, old_labels: list[str],
                   new_labels: list[str]) -> IngredientSegmenter:
    """Grows both heads to a larger label space, keeping learnt rows.

    Used when the Malaysian stage (or later, user corrections) introduces
    classes the base model never saw.
    """
    if old_labels == new_labels:
        return model
    old_index = {label: i for i, label in enumerate(old_labels)}

    old_conv: nn.Conv2d = model.classifier[-1]
    new_conv = nn.Conv2d(old_conv.in_channels, len(new_labels), kernel_size=1)
    old_linear: nn.Linear = model.presence[-1]
    new_linear = nn.Linear(old_linear.in_features, len(new_labels))

    with torch.no_grad():
        for new_i, label in enumerate(new_labels):
            old_i = old_index.get(label)
            if old_i is None:
                continue
            new_conv.weight[new_i] = old_conv.weight[old_i]
            new_conv.bias[new_i] = old_conv.bias[old_i]
            new_linear.weight[new_i] = old_linear.weight[old_i]
            new_linear.bias[new_i] = old_linear.bias[old_i]

    model.classifier[-1] = new_conv
    model.presence[-1] = new_linear
    return model


def load_checkpoint(path, device="cpu") -> tuple[IngredientSegmenter, dict]:
    checkpoint = torch.load(path, map_location=device, weights_only=False)
    model = IngredientSegmenter(len(checkpoint["labels"]), pretrained_backbone=False)
    model.load_state_dict(checkpoint["model"])
    return model, checkpoint
