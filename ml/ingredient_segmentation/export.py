"""Convert segmentation logits to Core ML. iOS decoder needs matching class metadata."""
import argparse
import json
from pathlib import Path

import coremltools as ct
import torch
from torchvision.models.segmentation import deeplabv3_mobilenet_v3_large


class Output(torch.nn.Module):
    def __init__(self, model):
        super().__init__(); self.model = model

    def forward(self, x):
        return self.model(x)["out"]


parser = argparse.ArgumentParser()
parser.add_argument("--checkpoint", default="ml/checkpoints/segmentation.pt")
parser.add_argument("--output", default="ml/runs/FoodRecognition.mlpackage")
args = parser.parse_args()
checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=True)
model = deeplabv3_mobilenet_v3_large(weights=None, weights_backbone=None, num_classes=checkpoint["classes"])
model.load_state_dict(checkpoint["model"]); model.eval()
traced = torch.jit.trace(Output(model), torch.rand(1, 3, 384, 384))
converted = ct.convert(traced, inputs=[ct.ImageType(name="image", shape=(1, 3, 384, 384), scale=1/255)],
                       outputs=[ct.TensorType(name="segmentation_logits")], minimum_deployment_target=ct.target.iOS17)
Path(args.output).parent.mkdir(parents=True, exist_ok=True)
converted.save(args.output)
print(json.dumps({"output": args.output, "classes": checkpoint["classes"]}))
