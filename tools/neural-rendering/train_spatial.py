#!/usr/bin/env python3
"""Train and evaluate the NR-0001 spatial residual upscaler."""

from __future__ import annotations

import argparse
import math
import random
import time
from pathlib import Path

import numpy as np
import torch
from torch.nn import functional
from torch.utils.data import DataLoader

from nr_common import (
    atomic_json,
    create_new_directory,
    environment_record,
    load_json,
    psnr_from_mse,
    require_absolute,
    select_device,
    sha256_file,
    synchronize,
    tensor_to_image,
)
from nr_dataset import PairedFrameDataset
from nr_model import SpatialResidualUpscaler


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--epochs", required=True, type=int)
    parser.add_argument("--batch-size", required=True, type=int)
    parser.add_argument("--learning-rate", required=True, type=float)
    parser.add_argument("--features", type=int, default=32)
    parser.add_argument("--seed", type=int, default=20260805)
    parser.add_argument("--device", choices=("auto", "mps", "cpu"), default="auto")
    return parser.parse_args()


def edge_loss(output: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
    output_x = output[:, :, :, 1:] - output[:, :, :, :-1]
    target_x = target[:, :, :, 1:] - target[:, :, :, :-1]
    output_y = output[:, :, 1:, :] - output[:, :, :-1, :]
    target_y = target[:, :, 1:, :] - target[:, :, :-1, :]
    return functional.l1_loss(output_x, target_x) + functional.l1_loss(
        output_y, target_y
    )


def evaluate(
    model: torch.nn.Module,
    loader: DataLoader,
    device: torch.device,
    scale: int,
    sample_directory: Path,
    sample_prefix: str,
) -> dict[str, float | int]:
    model.eval()
    model_absolute = 0.0
    model_squared = 0.0
    baseline_absolute = 0.0
    baseline_squared = 0.0
    pixel_count = 0
    frame_count = 0
    inference_ms: list[float] = []
    sample_written = False
    with torch.inference_mode():
        for low, target, frame_ids in loader:
            low = low.to(device)
            target = target.to(device)
            synchronize(device)
            started = time.perf_counter()
            output = model(low)
            synchronize(device)
            inference_ms.append((time.perf_counter() - started) * 1000.0)
            baseline = functional.interpolate(
                low,
                scale_factor=float(scale),
                mode="bicubic",
                align_corners=False,
            ).clamp(0.0, 1.0)
            model_delta = output - target
            baseline_delta = baseline - target
            model_absolute += model_delta.abs().sum().item()
            model_squared += model_delta.square().sum().item()
            baseline_absolute += baseline_delta.abs().sum().item()
            baseline_squared += baseline_delta.square().sum().item()
            pixel_count += target.numel()
            frame_count += target.shape[0]
            if not sample_written:
                sample_directory.mkdir(parents=True, exist_ok=True)
                tensor_to_image(low[0]).save(sample_directory / f"{sample_prefix}-input.png")
                tensor_to_image(baseline[0]).save(
                    sample_directory / f"{sample_prefix}-bicubic.png"
                )
                tensor_to_image(output[0]).save(
                    sample_directory / f"{sample_prefix}-model.png"
                )
                tensor_to_image(target[0]).save(
                    sample_directory / f"{sample_prefix}-target.png"
                )
                (sample_directory / f"{sample_prefix}-frame-id.txt").write_text(
                    str(frame_ids[0]) + "\n", encoding="utf-8"
                )
                sample_written = True
    model_mse = model_squared / pixel_count
    baseline_mse = baseline_squared / pixel_count
    ordered_ms = sorted(inference_ms)
    return {
        "frames": frame_count,
        "batches": len(inference_ms),
        "model_mae": model_absolute / pixel_count,
        "model_mse": model_mse,
        "model_psnr_db": psnr_from_mse(model_mse),
        "bicubic_mae": baseline_absolute / pixel_count,
        "bicubic_mse": baseline_mse,
        "bicubic_psnr_db": psnr_from_mse(baseline_mse),
        "model_minus_bicubic_mae": (model_absolute - baseline_absolute) / pixel_count,
        "batch_inference_ms_p50": float(np.percentile(ordered_ms, 50)),
        "batch_inference_ms_p95": float(np.percentile(ordered_ms, 95)),
        "batch_inference_ms_p99": float(np.percentile(ordered_ms, 99)),
    }


def main() -> None:
    args = arguments()
    manifest_path = require_absolute(args.dataset, "--dataset")
    output = create_new_directory(args.output, "--output")
    if args.epochs <= 0 or args.batch_size <= 0 or args.learning_rate <= 0:
        raise ValueError("epochs, batch size, and learning rate must be positive")
    if args.features <= 0:
        raise ValueError("features must be positive")
    manifest = load_json(manifest_path)
    dimensions = manifest.get("dimensions")
    if not isinstance(dimensions, dict):
        raise ValueError("dataset has no dimensions")
    scale = int(dimensions["scale"])
    device = select_device(args.device)

    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    generator = torch.Generator().manual_seed(args.seed)
    datasets = {
        split: PairedFrameDataset(manifest_path, split)
        for split in ("train", "validation", "test")
    }
    loaders = {
        "train": DataLoader(
            datasets["train"],
            batch_size=args.batch_size,
            shuffle=True,
            generator=generator,
        ),
        "validation": DataLoader(
            datasets["validation"], batch_size=args.batch_size, shuffle=False
        ),
        "test": DataLoader(
            datasets["test"], batch_size=args.batch_size, shuffle=False
        ),
    }
    model = SpatialResidualUpscaler(scale=scale, features=args.features).to(device)
    optimizer = torch.optim.Adam(model.parameters(), lr=args.learning_rate)
    history: list[dict[str, float | int]] = []
    started = time.perf_counter()
    for epoch in range(1, args.epochs + 1):
        model.train()
        loss_sum = 0.0
        batches = 0
        epoch_started = time.perf_counter()
        for low, target, _frame_ids in loaders["train"]:
            low = low.to(device)
            target = target.to(device)
            optimizer.zero_grad(set_to_none=True)
            output_image = model(low)
            reconstruction = functional.smooth_l1_loss(
                output_image, target, beta=0.01
            )
            loss = reconstruction + 0.1 * edge_loss(output_image, target)
            loss.backward()
            optimizer.step()
            loss_sum += loss.item()
            batches += 1
        synchronize(device)
        history.append(
            {
                "epoch": epoch,
                "train_loss": loss_sum / batches,
                "duration_ms": (time.perf_counter() - epoch_started) * 1000.0,
            }
        )
        print(
            f"epoch={epoch} loss={history[-1]['train_loss']:.8f} "
            f"duration_ms={history[-1]['duration_ms']:.2f}",
            flush=True,
        )
    training_ms = (time.perf_counter() - started) * 1000.0

    checkpoint_path = output / "checkpoint.pt"
    torch.save(
        {
            "schema": 1,
            "model": {"name": "spatial_residual_upscaler", "scale": scale, "features": args.features},
            "state_dict": {key: value.detach().cpu() for key, value in model.state_dict().items()},
            "dataset_sha256": sha256_file(manifest_path),
            "seed": args.seed,
        },
        checkpoint_path,
    )
    samples = output / "samples"
    evaluations = {
        split: evaluate(model, loaders[split], device, scale, samples, split)
        for split in ("validation", "test")
    }
    repo_root = Path(__file__).resolve().parents[2]
    report = {
        "schema": 1,
        "status": "complete",
        "experiment": "nr-0001-spatial-overfit",
        "dataset_manifest": str(manifest_path),
        "dataset_sha256": sha256_file(manifest_path),
        "checkpoint": str(checkpoint_path),
        "checkpoint_sha256": sha256_file(checkpoint_path),
        "configuration": {
            "epochs": args.epochs,
            "batch_size": args.batch_size,
            "learning_rate": args.learning_rate,
            "features": args.features,
            "scale": scale,
            "seed": args.seed,
            "device": str(device),
        },
        "parameter_count": sum(parameter.numel() for parameter in model.parameters()),
        "training_ms": training_ms,
        "history": history,
        "evaluation": evaluations,
        "environment": environment_record(repo_root),
    }
    atomic_json(output / "training.json", report)
    print(output / "training.json")


if __name__ == "__main__":
    main()
