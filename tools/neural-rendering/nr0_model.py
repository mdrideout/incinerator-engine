"""Compact NR0-C multi-channel spatial residual model."""

from __future__ import annotations

import torch
from torch import nn
from torch.nn import functional

from nr0_dataset import MODEL_PLANES


class ResidualBlock(nn.Module):
    def __init__(self, features: int) -> None:
        super().__init__()
        self.conv_0 = nn.Conv2d(features, features, kernel_size=3, padding=1)
        self.conv_1 = nn.Conv2d(features, features, kernel_size=3, padding=1)

    def forward(self, value: torch.Tensor) -> torch.Tensor:
        residual = functional.silu(self.conv_0(value))
        return value + self.conv_1(residual)


class Nr0SpatialResidualUpscaler(nn.Module):
    """Low-resolution encoder with a late pixel-shuffle RGB decoder."""

    def __init__(self, *, scale: int = 4, features: int = 24, blocks: int = 3) -> None:
        super().__init__()
        if scale <= 1 or features <= 0 or blocks <= 0:
            raise ValueError("scale, features, and blocks must be positive")
        self.scale = scale
        self.features = features
        self.blocks_count = blocks
        self.encoder = nn.Conv2d(len(MODEL_PLANES), features, kernel_size=5, padding=2)
        self.blocks = nn.ModuleList(ResidualBlock(features) for _ in range(blocks))
        self.decoder = nn.Conv2d(features, 3 * scale * scale, kernel_size=3, padding=1)
        self.shuffle = nn.PixelShuffle(scale)

    def forward(self, neural_inputs: torch.Tensor) -> torch.Tensor:
        appearance = neural_inputs[:, :3]
        base = functional.interpolate(
            appearance,
            scale_factor=float(self.scale),
            mode="bilinear",
            align_corners=False,
        )
        features = functional.silu(self.encoder(neural_inputs))
        for block in self.blocks:
            features = block(features)
        residual = self.shuffle(self.decoder(features))
        return torch.clamp(base + residual, 0.0, 1.0)


def checkpoint_model(checkpoint: dict[str, object]) -> Nr0SpatialResidualUpscaler:
    if checkpoint.get("schema") != 2:
        raise ValueError("unsupported NR0-C checkpoint schema")
    config = checkpoint.get("model")
    if not isinstance(config, dict) or config.get("name") != "nr0_multichannel_spatial_residual":
        raise ValueError("checkpoint has no NR0-C model configuration")
    model = Nr0SpatialResidualUpscaler(
        scale=int(config["scale"]),
        features=int(config["features"]),
        blocks=int(config["blocks"]),
    )
    state_dict = checkpoint.get("state_dict")
    if not isinstance(state_dict, dict):
        raise ValueError("checkpoint has no state_dict")
    model.load_state_dict(state_dict)
    return model
