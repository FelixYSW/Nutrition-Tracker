"""Model B: mobile backbone with a multi-task regression head.

Predicts whole-dish mass, calories, protein, carbs and fat. In the app these
are a portion signal and a consistency check; per-ingredient nutrition comes
from the reference tables wherever a canonical match exists (spec section 23).

Backbones: MobileNetV3-Large (default, smallest) or EfficientNet-B0. Both are
torchvision / BSD-3. Extra input channels (segmentation, depth) are added by
widening the first convolution, initialising the new filters from the mean
of the pretrained RGB filters so training starts from a sensible point.
"""
from __future__ import annotations

import torch
from torch import nn
from torchvision.models import (EfficientNet_B0_Weights, MobileNet_V3_Large_Weights,
                                efficientnet_b0, mobilenet_v3_large)

from ml.nutrition_estimation.dataset import TARGETS


def _widen_first_conv(features: nn.Sequential, in_channels: int) -> None:
    conv: nn.Conv2d = features[0][0]
    if in_channels == conv.in_channels:
        return
    wider = nn.Conv2d(in_channels, conv.out_channels, conv.kernel_size, conv.stride,
                      conv.padding, bias=conv.bias is not None)
    with torch.no_grad():
        wider.weight[:, :3] = conv.weight
        wider.weight[:, 3:] = conv.weight.mean(dim=1, keepdim=True)
        if conv.bias is not None:
            wider.bias.copy_(conv.bias)
    features[0][0] = wider


class NutritionEstimator(nn.Module):
    def __init__(self, backbone: str = "mobilenet_v3_large", in_channels: int = 3,
                 pretrained: bool = True) -> None:
        super().__init__()
        if backbone == "mobilenet_v3_large":
            net = mobilenet_v3_large(weights=MobileNet_V3_Large_Weights.IMAGENET1K_V1 if pretrained else None)
            feature_dim = 960
        elif backbone == "efficientnet_b0":
            net = efficientnet_b0(weights=EfficientNet_B0_Weights.IMAGENET1K_V1 if pretrained else None)
            feature_dim = 1280
        else:
            raise ValueError(f"unknown backbone {backbone!r}")

        self.features = net.features
        _widen_first_conv(self.features, in_channels)
        self.pool = nn.AdaptiveAvgPool2d(1)
        self.head = nn.Sequential(
            nn.Flatten(),
            nn.Linear(feature_dim, 512),
            nn.Hardswish(),
            nn.Dropout(0.2),
            nn.Linear(512, len(TARGETS)),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.head(self.pool(self.features(x)))


def load_checkpoint(path, device="cpu") -> tuple[NutritionEstimator, dict]:
    checkpoint = torch.load(path, map_location=device, weights_only=False)
    model = NutritionEstimator(checkpoint["backbone"], checkpoint["channels"], pretrained=False)
    model.load_state_dict(checkpoint["model"])
    return model, checkpoint
