"""Pure NR0-D spatial, categorical-boundary, instance, and temporal metrics."""

from __future__ import annotations

import math

import torch
from torch.nn import functional


def ssim(output: torch.Tensor, target: torch.Tensor) -> float:
    kernel = min(11, output.shape[-2], output.shape[-1])
    if kernel % 2 == 0:
        kernel -= 1
    padding = kernel // 2
    mean_output = functional.avg_pool2d(output, kernel, 1, padding)
    mean_target = functional.avg_pool2d(target, kernel, 1, padding)
    variance_output = functional.avg_pool2d(output.square(), kernel, 1, padding) - mean_output.square()
    variance_target = functional.avg_pool2d(target.square(), kernel, 1, padding) - mean_target.square()
    covariance = functional.avg_pool2d(output * target, kernel, 1, padding) - mean_output * mean_target
    c1 = 0.01**2
    c2 = 0.03**2
    score = ((2 * mean_output * mean_target + c1) * (2 * covariance + c2)) / (
        (mean_output.square() + mean_target.square() + c1)
        * (variance_output + variance_target + c2)
    )
    return float(score.mean())


def gradient_error_map(output: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
    horizontal = functional.pad(
        (output[:, :, :, 1:] - output[:, :, :, :-1])
        - (target[:, :, :, 1:] - target[:, :, :, :-1]),
        (0, 1, 0, 0),
    ).abs()
    vertical = functional.pad(
        (output[:, :, 1:, :] - output[:, :, :-1, :])
        - (target[:, :, 1:, :] - target[:, :, :-1, :]),
        (0, 0, 0, 1),
    ).abs()
    return (horizontal + vertical).mean(dim=1, keepdim=True) * 0.5


def metrics(output: torch.Tensor, target: torch.Tensor, mask: torch.Tensor | None = None) -> dict:
    absolute = (output - target).abs()
    squared = (output - target).square()
    gradient = gradient_error_map(output, target)
    if mask is None:
        mae = float(absolute.mean())
        mse = float(squared.mean())
        gradient_mae = float(gradient.mean())
        pixels = int(output.shape[-2] * output.shape[-1])
    else:
        selected = mask.to(dtype=torch.bool)
        pixels = int(selected.sum())
        if pixels == 0:
            return {"pixels": 0, "mae": None, "mse": None, "psnr_db": None, "gradient_mae": None}
        expanded = selected.expand(-1, output.shape[1], -1, -1)
        mae = float(absolute[expanded].mean())
        mse = float(squared[expanded].mean())
        gradient_mae = float(gradient[selected].mean())
    return {
        "pixels": pixels,
        "mae": mae,
        "mse": mse,
        "psnr_db": None if mse == 0 else 10.0 * math.log10(1.0 / mse),
        "gradient_mae": gradient_mae,
        **({"ssim": ssim(output, target)} if mask is None else {}),
    }


def categorical_boundary(values: torch.Tensor, coverage: torch.Tensor) -> torch.Tensor:
    """Return a four-neighbor boundary mask for CHW categorical bytes."""
    if values.ndim != 3 or coverage.ndim != 2:
        raise ValueError("categorical boundary expects CHW values and HW coverage")
    boundary = torch.zeros_like(coverage, dtype=torch.bool)
    horizontal = (values[:, :, 1:] != values[:, :, :-1]).any(dim=0)
    vertical = (values[:, 1:, :] != values[:, :-1, :]).any(dim=0)
    boundary[:, 1:] |= horizontal
    boundary[:, :-1] |= horizontal
    boundary[1:, :] |= vertical
    boundary[:-1, :] |= vertical
    return boundary & coverage


def decode_instance(rgb: torch.Tensor) -> torch.Tensor:
    if rgb.shape[0] != 3:
        raise ValueError("instance RGB must have three channels")
    values = rgb.to(torch.int64)
    return values[0] | (values[1] << 8) | (values[2] << 16)


def upsample_mask(mask: torch.Tensor, size: tuple[int, int]) -> torch.Tensor:
    return functional.interpolate(
        mask[None, None].float(), size=size, mode="nearest"
    ).to(torch.bool)


def temporal_reprojection(
    previous_image: torch.Tensor,
    current_motion: torch.Tensor,
    previous_semantic: torch.Tensor,
    current_semantic: torch.Tensor,
    previous_instance: torch.Tensor,
    current_instance: torch.Tensor,
    current_coverage: torch.Tensor,
    output_size: tuple[int, int],
) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    """Warp a previous NCHW image and return valid/disoccluded current masks."""
    low_height, low_width = current_motion.shape[-2:]
    y, x = torch.meshgrid(
        (torch.arange(low_height, device=current_motion.device) + 0.5) * 2 / low_height - 1,
        (torch.arange(low_width, device=current_motion.device) + 0.5) * 2 / low_width - 1,
        indexing="ij",
    )
    delta = (current_motion[:2] - 0.5) * 2.0
    grid = torch.stack((x - delta[0], y + delta[1]), dim=-1)[None]
    warped_semantic = functional.grid_sample(
        previous_semantic[None].float(), grid, mode="nearest", padding_mode="zeros", align_corners=False
    )[0].to(current_semantic.dtype)
    warped_instance = functional.grid_sample(
        previous_instance[None, None].float(), grid, mode="nearest", padding_mode="zeros", align_corners=False
    )[0, 0].to(current_instance.dtype)
    history_declared = current_motion[2] > 0.5
    valid_low = (
        history_declared
        & current_coverage
        & (warped_semantic == current_semantic).all(dim=0)
        & (warped_instance == current_instance)
        & (current_instance != 0)
    )
    output_height, output_width = output_size
    high_motion = functional.interpolate(
        delta[None], size=output_size, mode="bilinear", align_corners=False
    )[0]
    high_y, high_x = torch.meshgrid(
        (torch.arange(output_height, device=current_motion.device) + 0.5) * 2 / output_height - 1,
        (torch.arange(output_width, device=current_motion.device) + 0.5) * 2 / output_width - 1,
        indexing="ij",
    )
    high_grid = torch.stack(
        (high_x - high_motion[0], high_y + high_motion[1]), dim=-1
    )[None]
    warped_image = functional.grid_sample(
        previous_image,
        high_grid,
        mode="bilinear",
        padding_mode="zeros",
        align_corners=False,
    )
    valid = upsample_mask(valid_low, output_size)
    coverage = upsample_mask(current_coverage, output_size)
    return warped_image, valid, coverage & ~valid
