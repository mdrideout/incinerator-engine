"""Direct random-initialized 160x90 to 640x360 spatial title renderer."""

from __future__ import annotations

from dataclasses import asdict, dataclass

import torch
from torch import nn
from torch.nn import functional

from title_renderer.contracts import INPUT_EXTENT, TARGET_EXTENT
from title_renderer.dataset import CONTINUOUS_PLANES, GLOBAL_CONTROLS


class ResidualBlock(nn.Module):
    def __init__(self, channels: int) -> None:
        super().__init__()
        self.first = nn.Conv2d(channels, channels, 3, padding=1)
        self.second = nn.Conv2d(channels, channels, 3, padding=1)

    def forward(self, value: torch.Tensor) -> torch.Tensor:
        return value + self.second(functional.silu(self.first(value)))


@dataclass(frozen=True)
class SpatialTitleRendererConfig:
    name: str = "rf8_direct_spatial_title_renderer_v2"
    features: int = 32
    low_blocks: int = 4
    output_blocks: int = 6
    semantic_embedding: int = 4
    instance_embedding: int = 8
    refinement_features: int = 48
    output_width: int = TARGET_EXTENT[0]
    output_height: int = TARGET_EXTENT[1]

    def json(self) -> dict[str, int | str]:
        return asdict(self)


class SpatialTitleRenderer(nn.Module):
    """Low-resolution conditioning followed by one direct learned native output."""

    def __init__(self, config: SpatialTitleRendererConfig, semantic_categories: int, instance_categories: int) -> None:
        super().__init__()
        if semantic_categories <= 0 or instance_categories <= 0:
            raise ValueError("categorical vocabularies must include background")
        if (config.output_width, config.output_height) != TARGET_EXTENT:
            raise ValueError("spatial title renderer requires the direct native 160x90 to 640x360 contract")
        if config.features <= 0 or config.refinement_features <= 0:
            raise ValueError("spatial title renderer feature counts must be positive")
        self.config = config
        self.semantic_categories = semantic_categories
        self.instance_categories = instance_categories
        self.semantic_embedding = nn.Embedding(semantic_categories, config.semantic_embedding)
        self.instance_embedding = nn.Embedding(instance_categories, config.instance_embedding)
        low_channels = len(CONTINUOUS_PLANES) + len(GLOBAL_CONTROLS) + config.semantic_embedding + config.instance_embedding
        self.low_encoder = nn.Conv2d(low_channels, config.features, 5, padding=2)
        self.context_blocks = nn.ModuleList(ResidualBlock(config.features) for _ in range(config.low_blocks))
        structural_channels = 1 + 3 + 1 + config.semantic_embedding + config.instance_embedding
        structural_features = max(8, config.features // 2)
        self.structural_encoder = nn.Sequential(
            nn.Conv2d(structural_channels, structural_features, 3, padding=1),
            nn.SiLU(),
            nn.Conv2d(structural_features, structural_features, 3, padding=1),
        )
        self.fusion = nn.Conv2d(config.features + structural_features, config.features, 3, padding=1)
        self.direct_projection = nn.Conv2d(config.features, config.refinement_features, 3, padding=1)
        self.output_structural_projection = nn.Conv2d(
            structural_features,
            config.refinement_features,
            3,
            padding=1,
        )
        self.output_fusion = nn.Conv2d(config.refinement_features * 2, config.refinement_features, 3, padding=1)
        self.output_blocks = nn.ModuleList(
            ResidualBlock(config.refinement_features) for _ in range(config.output_blocks)
        )
        self.output = nn.Conv2d(config.refinement_features, 3, 3, padding=1)

    def forward(
        self,
        continuous: torch.Tensor,
        semantic: torch.Tensor,
        instance: torch.Tensor,
        global_controls: torch.Tensor,
    ) -> torch.Tensor:
        semantic_features = self.semantic_embedding(semantic).permute(0, 3, 1, 2)
        instance_features = self.instance_embedding(instance).permute(0, 3, 1, 2)
        controls = global_controls[:, :, None, None].expand(
            -1, -1, continuous.shape[2], continuous.shape[3]
        )
        low = torch.cat((continuous, semantic_features, instance_features, controls), dim=1)
        low = functional.silu(self.low_encoder(low))
        for block in self.context_blocks:
            low = block(low)
        structural = self.structural_encoder(
            torch.cat(
                (
                    continuous[:, 3:4],
                    continuous[:, 4:7],
                    continuous[:, 10:11],
                    semantic_features,
                    instance_features,
                ),
                dim=1,
            )
        )
        fused = functional.silu(self.fusion(torch.cat((low, structural), dim=1)))
        output_size = (self.config.output_height, self.config.output_width)
        appearance_features = functional.interpolate(
            self.direct_projection(fused),
            size=output_size,
            mode="bilinear",
            align_corners=False,
        )
        structural_features = functional.interpolate(
            self.output_structural_projection(structural),
            size=output_size,
            mode="nearest",
        )
        fused = functional.silu(self.output_fusion(torch.cat((appearance_features, structural_features), dim=1)))
        for block in self.output_blocks:
            fused = block(fused)
        base = functional.interpolate(continuous[:, :3], size=output_size, mode="bilinear", align_corners=False)
        return base + self.output(fused)


def create_spatial_model(
    config: SpatialTitleRendererConfig,
    *,
    semantic_categories: int,
    instance_categories: int,
    initialization_seed: int,
) -> SpatialTitleRenderer:
    torch.manual_seed(initialization_seed)
    model = SpatialTitleRenderer(config, semantic_categories, instance_categories)
    for module in model.modules():
        if isinstance(module, (nn.Conv2d, nn.Linear)):
            nn.init.kaiming_uniform_(module.weight, a=5**0.5)
            if module.bias is not None:
                nn.init.zeros_(module.bias)
        elif isinstance(module, nn.Embedding):
            nn.init.normal_(module.weight, mean=0.0, std=0.02)
            with torch.no_grad():
                module.weight[0].zero_()
    return model
