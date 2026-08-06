"""The NR-0001 fixed-scale spatial residual upscaler."""

from __future__ import annotations

import torch
from torch import nn
from torch.nn import functional as functional


class SpatialResidualUpscaler(nn.Module):
    """Most feature work stays at input resolution; output is a learned residual."""

    def __init__(self, scale: int = 4, features: int = 32) -> None:
        super().__init__()
        if scale <= 1:
            raise ValueError("scale must be greater than one")
        self.scale = scale
        self.features = features
        self.features_0 = nn.Conv2d(3, features, kernel_size=5, padding=2)
        self.features_1 = nn.Conv2d(features, features, kernel_size=3, padding=1)
        self.residual = nn.Conv2d(
            features, 3 * scale * scale, kernel_size=3, padding=1
        )
        self.shuffle = nn.PixelShuffle(scale)

    def forward(self, low_resolution: torch.Tensor) -> torch.Tensor:
        base = functional.interpolate(
            low_resolution,
            scale_factor=float(self.scale),
            mode="bilinear",
            align_corners=False,
        )
        features = functional.relu(self.features_0(low_resolution))
        features = functional.relu(self.features_1(features))
        residual = self.shuffle(self.residual(features))
        return torch.clamp(base + residual, 0.0, 1.0)


def checkpoint_model(checkpoint: dict[str, object]) -> SpatialResidualUpscaler:
    model_config = checkpoint.get("model")
    if not isinstance(model_config, dict):
        raise ValueError("checkpoint has no model configuration")
    model = SpatialResidualUpscaler(
        scale=int(model_config["scale"]),
        features=int(model_config["features"]),
    )
    state_dict = checkpoint.get("state_dict")
    if not isinstance(state_dict, dict):
        raise ValueError("checkpoint has no state_dict")
    model.load_state_dict(state_dict)
    return model
