"""Non-learned reconstruction losses, metrics, and display derivatives."""

from __future__ import annotations

import math
from pathlib import Path
from typing import Any

import numpy as np
import torch
from PIL import Image, ImageDraw
from torch.nn import functional


BASELINES = ("nearest", "bilinear", "bicubic")


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


def loss_terms(
    output: torch.Tensor,
    target: torch.Tensor,
    semantic: torch.Tensor,
    instance: torch.Tensor,
    target_coverage: torch.Tensor,
) -> tuple[torch.Tensor, dict[str, float]]:
    reconstruction = functional.smooth_l1_loss(output, target, beta=0.02)
    output_x, output_y = _gradient(output)
    target_x, target_y = _gradient(target)
    gradient = functional.l1_loss(output_x, target_x) + functional.l1_loss(output_y, target_y)
    output_low = functional.avg_pool2d(output, 5, stride=1, padding=2)
    target_low = functional.avg_pool2d(target, 5, stride=1, padding=2)
    high_frequency = functional.l1_loss(output - output_low, target - target_low)
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
    total = reconstruction + 0.12 * gradient + 0.08 * high_frequency + 0.04 * semantic_edge + 0.04 * instance_edge + 0.04 * geometry
    return total, {
        "reconstruction": float(reconstruction.detach()),
        "gradient": float(gradient.detach()),
        "high_frequency": float(high_frequency.detach()),
        "semantic_boundary": float(semantic_edge.detach()),
        "instance_boundary": float(instance_edge.detach()),
        "authored_geometry_boundary": float(geometry.detach()),
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
    return {
        "linear_hdr_mae": mae,
        "linear_hdr_mse": mse,
        "linear_hdr_psnr_db": 20.0 * math.log10(peak) - 10.0 * math.log10(max(mse, 1.0e-20)),
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
