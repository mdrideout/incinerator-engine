"""Non-learned reconstruction losses, metrics, and display derivatives."""

from __future__ import annotations

import math
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import numpy as np
import torch
from PIL import Image, ImageDraw
from torch.nn import functional


BASELINES = ("nearest", "bilinear", "bicubic")


@dataclass(frozen=True)
class ReconstructionLossConfig:
    """Auditable weights for direct scene-linear and color-faithful reconstruction."""

    reconstruction: float = 1.0
    log_luminance: float = 0.20
    chroma: float = 0.15
    multiscale_color: float = 0.10
    gradient: float = 0.15
    high_frequency: float = 0.15
    laplacian: float = 0.12
    local_contrast: float = 0.08
    semantic_edge: float = 0.08
    instance_edge: float = 0.08
    geometry: float = 0.08
    negative_radiance: float = 0.02

    def json(self) -> dict[str, float]:
        return asdict(self)


def resize_baseline(appearance_linear: torch.Tensor, target_size: tuple[int, int], name: str) -> torch.Tensor:
    kwargs: dict[str, Any] = {"size": target_size, "mode": name}
    if name in {"bilinear", "bicubic"}:
        kwargs["align_corners"] = False
    return functional.interpolate(appearance_linear, **kwargs)


def _gradient(value: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
    return value[:, :, :, 1:] - value[:, :, :, :-1], value[:, :, 1:, :] - value[:, :, :-1, :]


def _boundary_mask(ids: torch.Tensor, target_size: tuple[int, int]) -> torch.Tensor:
    ids = functional.interpolate(ids[:, None].float(), size=target_size, mode="nearest-exact")[:, 0]
    horizontal = functional.pad((ids[:, :, 1:] != ids[:, :, :-1]).float(), (0, 1, 0, 0))
    vertical = functional.pad((ids[:, 1:, :] != ids[:, :-1, :]).float(), (0, 0, 0, 1))
    return torch.maximum(horizontal, vertical)[:, None]


def _dilate(mask: torch.Tensor) -> torch.Tensor:
    return functional.max_pool2d(mask, 3, stride=1, padding=1)


def _luminance(value: torch.Tensor) -> torch.Tensor:
    return 0.2126 * value[:, 0:1] + 0.7152 * value[:, 1:2] + 0.0722 * value[:, 2:3]


def _signed_log(value: torch.Tensor) -> torch.Tensor:
    return torch.sign(value) * torch.log1p(value.abs())


def _chroma(value: torch.Tensor) -> torch.Tensor:
    red, green, blue = value[:, 0:1], value[:, 1:2], value[:, 2:3]
    return torch.cat((0.5 * (red - blue), 0.5 * green - 0.25 * (red + blue)), dim=1)


def _multiscale_color(output: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
    losses = []
    for scale in (4, 8):
        losses.append(
            functional.l1_loss(
                functional.avg_pool2d(output, scale, stride=scale),
                functional.avg_pool2d(target, scale, stride=scale),
            )
        )
    return torch.stack(losses).mean()


def _laplacian_pyramid(value: torch.Tensor) -> tuple[torch.Tensor, ...]:
    bands = []
    current = value
    for _ in range(3):
        reduced = functional.avg_pool2d(current, 2, stride=2)
        restored = functional.interpolate(reduced, size=current.shape[-2:], mode="bilinear", align_corners=False)
        bands.append(current - restored)
        current = reduced
    return tuple(bands)


def _local_contrast(value: torch.Tensor) -> torch.Tensor:
    luminance = _signed_log(_luminance(value))
    mean = functional.avg_pool2d(luminance, 7, stride=1, padding=3)
    mean_square = functional.avg_pool2d(luminance.square(), 7, stride=1, padding=3)
    # Flat authored regions are common. Avoid sqrt's singular derivative at
    # exactly zero or those regions produce non-finite MPS gradients.
    variance = (mean_square - mean.square()).clamp_min(0.0)
    return (variance + 1.0e-6).sqrt()


def _sharpness_terms(output: torch.Tensor, target: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
    output_x, output_y = _gradient(output)
    target_x, target_y = _gradient(target)
    gradient = functional.l1_loss(output_x, target_x) + functional.l1_loss(output_y, target_y)
    output_low = functional.avg_pool2d(output, 5, stride=1, padding=2)
    target_low = functional.avg_pool2d(target, 5, stride=1, padding=2)
    high_frequency = functional.l1_loss(output - output_low, target - target_low)
    laplacian = torch.stack(
        [
            functional.l1_loss(output_band, target_band)
            for output_band, target_band in zip(_laplacian_pyramid(output), _laplacian_pyramid(target), strict=True)
        ]
    ).mean()
    local_contrast = functional.l1_loss(_local_contrast(output), _local_contrast(target))
    return gradient, high_frequency, laplacian, local_contrast


def loss_terms(
    output: torch.Tensor,
    target: torch.Tensor,
    semantic: torch.Tensor,
    instance: torch.Tensor,
    target_coverage: torch.Tensor,
    configuration: ReconstructionLossConfig | None = None,
) -> tuple[torch.Tensor, dict[str, float]]:
    weights = configuration or ReconstructionLossConfig()
    reconstruction = functional.smooth_l1_loss(output, target, beta=0.02)
    log_luminance = functional.l1_loss(
        torch.log1p(_luminance(output.clamp_min(0.0))),
        torch.log1p(_luminance(target.clamp_min(0.0))),
    )
    chroma = functional.l1_loss(_signed_log(_chroma(output)), _signed_log(_chroma(target)))
    multiscale_color = _multiscale_color(output, target)
    gradient, high_frequency, laplacian, local_contrast = _sharpness_terms(output, target)
    target_size = (target.shape[2], target.shape[3])
    semantic_boundary = _dilate(_boundary_mask(semantic, target_size))
    instance_boundary = _dilate(_boundary_mask(instance, target_size))
    absolute = (output - target).abs().mean(dim=1, keepdim=True)
    semantic_denominator = semantic_boundary.sum().clamp_min(1.0)
    instance_denominator = instance_boundary.sum().clamp_min(1.0)
    semantic_edge = (absolute * semantic_boundary).sum() / semantic_denominator
    instance_edge = (absolute * instance_boundary).sum() / instance_denominator
    coverage_edge = _dilate(
        torch.maximum(
            functional.pad((target_coverage[:, :, :, 1:] != target_coverage[:, :, :, :-1]).float(), (0, 1, 0, 0)),
            functional.pad((target_coverage[:, :, 1:, :] != target_coverage[:, :, :-1, :]).float(), (0, 0, 0, 1)),
        )
    )
    geometry = (absolute * coverage_edge).sum() / coverage_edge.sum().clamp_min(1.0)
    negative_radiance = functional.relu(-output).mean()
    total = (
        weights.reconstruction * reconstruction
        + weights.log_luminance * log_luminance
        + weights.chroma * chroma
        + weights.multiscale_color * multiscale_color
        + weights.gradient * gradient
        + weights.high_frequency * high_frequency
        + weights.laplacian * laplacian
        + weights.local_contrast * local_contrast
        + weights.semantic_edge * semantic_edge
        + weights.instance_edge * instance_edge
        + weights.geometry * geometry
        + weights.negative_radiance * negative_radiance
    )
    return total, {
        "reconstruction": float(reconstruction.detach()),
        "log_luminance": float(log_luminance.detach()),
        "chroma": float(chroma.detach()),
        "multiscale_color": float(multiscale_color.detach()),
        "gradient": float(gradient.detach()),
        "high_frequency": float(high_frequency.detach()),
        "laplacian": float(laplacian.detach()),
        "local_contrast": float(local_contrast.detach()),
        "semantic_boundary": float(semantic_edge.detach()),
        "instance_boundary": float(instance_edge.detach()),
        "authored_geometry_boundary": float(geometry.detach()),
        "negative_radiance": float(negative_radiance.detach()),
    }


def display_tensor(value: torch.Tensor) -> torch.Tensor:
    """Explicit diagnostic Reinhard plus sRGB derivative, never training truth."""

    value = value.clamp_min(0.0)
    mapped = value / (1.0 + value)
    return torch.where(mapped <= 0.0031308, mapped * 12.92, 1.055 * mapped.pow(1.0 / 2.4) - 0.055).clamp(0.0, 1.0)


def image(value: torch.Tensor) -> Image.Image:
    pixels = (display_tensor(value.detach().cpu()).permute(1, 2, 0).numpy() * 255.0).round().astype(np.uint8)
    return Image.fromarray(pixels, mode="RGB")


def metrics(output: torch.Tensor, target: torch.Tensor, semantic: torch.Tensor, instance: torch.Tensor) -> dict[str, float]:
    delta = output - target
    mae = float(delta.abs().mean())
    mse = float(delta.square().mean())
    peak = max(1.0, float(target.max()))
    display_delta = display_tensor(output) - display_tensor(target)
    semantic_mask = _dilate(_boundary_mask(semantic, (target.shape[2], target.shape[3])))
    instance_mask = _dilate(_boundary_mask(instance, (target.shape[2], target.shape[3])))
    absolute = delta.abs().mean(dim=1, keepdim=True)
    channel_mae = delta.abs().mean(dim=(0, 2, 3))
    log_luminance_mae = functional.l1_loss(
        torch.log1p(_luminance(output.clamp_min(0.0))),
        torch.log1p(_luminance(target.clamp_min(0.0))),
    )
    chroma_mae = functional.l1_loss(_signed_log(_chroma(output)), _signed_log(_chroma(target)))
    gradient_mae, high_frequency_mae, laplacian_mae, local_contrast_mae = _sharpness_terms(output, target)
    spatial_quality_score = (
        mae
        + 0.50 * float(gradient_mae)
        + 0.50 * float(high_frequency_mae)
        + 0.35 * float(laplacian_mae)
        + 0.25 * float(local_contrast_mae)
    )
    return {
        "linear_hdr_mae": mae,
        "linear_hdr_mae_r": float(channel_mae[0]),
        "linear_hdr_mae_g": float(channel_mae[1]),
        "linear_hdr_mae_b": float(channel_mae[2]),
        "linear_hdr_mse": mse,
        "linear_hdr_psnr_db": 20.0 * math.log10(peak) - 10.0 * math.log10(max(mse, 1.0e-20)),
        "log_luminance_mae": float(log_luminance_mae),
        "chroma_mae": float(chroma_mae),
        "gradient_mae": float(gradient_mae),
        "high_frequency_mae": float(high_frequency_mae),
        "laplacian_mae": float(laplacian_mae),
        "local_contrast_mae": float(local_contrast_mae),
        "spatial_quality_score": spatial_quality_score,
        "negative_radiance_fraction": float((output < 0).float().mean()),
        "diagnostic_display_mae": float(display_delta.abs().mean()),
        "semantic_boundary_mae": float((absolute * semantic_mask).sum() / semantic_mask.sum().clamp_min(1.0)),
        "instance_boundary_mae": float((absolute * instance_mask).sum() / instance_mask.sum().clamp_min(1.0)),
    }


def comparison_sheet(path: Path, frame_id: str, panels: list[tuple[str, torch.Tensor]]) -> None:
    rendered = [(label, image(value)) for label, value in panels]
    header = 28
    width = sum(value.width for _label, value in rendered)
    height = max(value.height for _label, value in rendered) + header
    sheet = Image.new("RGB", (width, height), "#10151d")
    draw = ImageDraw.Draw(sheet)
    offset = 0
    for label, value in rendered:
        sheet.paste(value, (offset, header))
        draw.text((offset + 6, 7), label, fill="white")
        offset += value.width
    path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(path)
    (path.parent / f"{frame_id}-display-transform.txt").write_text(
        "diagnostic only: clamp_min(0), Reinhard x/(1+x), linear-to-sRGB\n",
        encoding="utf-8",
    )


def overview_sheet(path: Path, sheets: list[Path]) -> None:
    if not sheets:
        raise ValueError("cannot create an empty title-renderer overview")
    columns = 3
    cell_width = 600
    opened = [Image.open(sheet).convert("RGB") for sheet in sheets]
    try:
        cell_height = round(opened[0].height * cell_width / opened[0].width)
        rows = (len(opened) + columns - 1) // columns
        overview = Image.new("RGB", (columns * cell_width, rows * cell_height), "#10151d")
        for index, source in enumerate(opened):
            if source.size != opened[0].size:
                raise ValueError("comparison-sheet dimensions drifted")
            rendered = source.resize((cell_width, cell_height), Image.Resampling.LANCZOS)
            overview.paste(rendered, ((index % columns) * cell_width, (index // columns) * cell_height))
        path.parent.mkdir(parents=True, exist_ok=True)
        overview.save(path)
    finally:
        for source in opened:
            source.close()
