import argparse
from pathlib import Path

import coremltools as ct
import torch
from train import create_model


class Output(torch.nn.Module):
    def __init__(self, model):
        super().__init__(); self.model = model

    def forward(self, image):
        result = self.model(image).clamp_min(0)
        return result[:, 0:1] * 500, result[:, 1:2] * 1000, result[:, 2:3] * 100, result[:, 3:4] * 100, result[:, 4:5] * 100


parser = argparse.ArgumentParser()
parser.add_argument("--checkpoint", default="ml/checkpoints/portion.pt")
parser.add_argument("--output", default="ml/runs/FoodPortion.mlpackage")
args = parser.parse_args()
model = create_model()
model.load_state_dict(torch.load(args.checkpoint, map_location="cpu", weights_only=True)["model"])
model.eval()
traced = torch.jit.trace(Output(model), torch.rand(1, 3, 224, 224))
converted = ct.convert(traced, inputs=[ct.ImageType(name="image", shape=(1, 3, 224, 224), scale=1/255)],
                       outputs=[ct.TensorType(name=name) for name in ("mass_g", "calories", "protein", "carbs", "fat")],
                       minimum_deployment_target=ct.target.iOS17)
Path(args.output).parent.mkdir(parents=True, exist_ok=True)
converted.save(args.output)
