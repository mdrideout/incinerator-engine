#!/usr/bin/env python3
"""Train, select, and evaluate the NR0-C 17-plane spatial baseline."""

from __future__ import annotations

import argparse
import copy
import random
import time
from pathlib import Path

import numpy as np
import torch
from PIL import Image, ImageDraw
from torch.nn import functional
from torch.utils.data import DataLoader

from nr0_dataset import MODEL_PLANES, Nr0Dataset
from nr0_model import Nr0SpatialResidualUpscaler
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


BASELINES = ("nearest", "bilinear", "bicubic")


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--stage", choices=("overfit", "heldout"), required=True)
    parser.add_argument("--epochs", required=True, type=int)
    parser.add_argument("--batch-size", required=True, type=int)
    parser.add_argument("--learning-rate", required=True, type=float)
    parser.add_argument("--patch-size", required=True, type=int)
    parser.add_argument("--features", type=int, default=24)
    parser.add_argument("--blocks", type=int, default=3)
    parser.add_argument("--validation-every", type=int, default=5)
    parser.add_argument("--seed", type=int, default=20260806)
    parser.add_argument("--device", choices=("auto", "mps", "cpu"), default="auto")
    parser.add_argument("--require-gate", action="store_true")
    return parser.parse_args()


def edge_loss(output: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
    return functional.l1_loss(output[:, :, :, 1:] - output[:, :, :, :-1], target[:, :, :, 1:] - target[:, :, :, :-1]) + functional.l1_loss(output[:, :, 1:, :] - output[:, :, :-1, :], target[:, :, 1:, :] - target[:, :, :-1, :])


def ssim(output: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
    """Channel-averaged structural similarity with an 11x11 uniform window."""
    kernel = 11
    padding = kernel // 2
    mean_output = functional.avg_pool2d(output, kernel, stride=1, padding=padding)
    mean_target = functional.avg_pool2d(target, kernel, stride=1, padding=padding)
    variance_output = functional.avg_pool2d(output * output, kernel, 1, padding) - mean_output.square()
    variance_target = functional.avg_pool2d(target * target, kernel, 1, padding) - mean_target.square()
    covariance = functional.avg_pool2d(output * target, kernel, 1, padding) - mean_output * mean_target
    c1 = 0.01**2
    c2 = 0.03**2
    score = ((2 * mean_output * mean_target + c1) * (2 * covariance + c2)) / ((mean_output.square() + mean_target.square() + c1) * (variance_output + variance_target + c2))
    return score.mean()


def loss_terms(output: torch.Tensor, target: torch.Tensor) -> tuple[torch.Tensor, dict[str, float]]:
    reconstruction = functional.smooth_l1_loss(output, target, beta=0.01)
    edges = edge_loss(output, target)
    structure = 1.0 - ssim(output, target)
    total = reconstruction + 0.1 * edges + 0.05 * structure
    return total, {
        "reconstruction": float(reconstruction.detach()),
        "edge": float(edges.detach()),
        "structure": float(structure.detach()),
    }


def baseline(appearance: torch.Tensor, scale: int, name: str) -> torch.Tensor:
    kwargs = {"scale_factor": float(scale), "mode": name}
    if name in {"bilinear", "bicubic"}:
        kwargs["align_corners"] = False
    return functional.interpolate(appearance, **kwargs).clamp(0.0, 1.0)


def save_comparison(directory: Path, frame_id: str, images: dict[str, torch.Tensor], target: torch.Tensor) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    ordered = [("target", target)] + [(name, images[name]) for name in (*BASELINES, "model")]
    rendered = []
    for name, value in ordered:
        image = tensor_to_image(value)
        image.save(directory / f"{frame_id}-{name}.png")
        rendered.append(image)
    error = (images["model"] - target).abs() * 4.0
    tensor_to_image(error).save(directory / f"{frame_id}-model-error-x4.png")
    header_height = 28
    sheet = Image.new("RGB", (rendered[0].width * len(rendered), rendered[0].height + header_height), "white")
    labels = [name for name, _value in ordered]
    draw = ImageDraw.Draw(sheet)
    for index, image in enumerate(rendered):
        offset = index * image.width
        sheet.paste(image, (offset, header_height))
        draw.text((offset + 8, 7), labels[index], fill="black")
    sheet.save(directory / f"{frame_id}-comparison.png")


def evaluate(model: torch.nn.Module, loader: DataLoader, device: torch.device, scale: int, sample_directory: Path, split: str) -> dict:
    names = (*BASELINES, "model")
    accumulators = {name: {"absolute": 0.0, "squared": 0.0, "ssim": 0.0} for name in names}
    pixel_count = 0
    frame_count = 0
    inference_ms: list[float] = []
    model.eval()
    with torch.inference_mode():
        for inputs, target, frame_ids in loader:
            inputs = inputs.to(device)
            target = target.to(device)
            synchronize(device)
            started = time.perf_counter()
            model_output = model(inputs)
            synchronize(device)
            inference_ms.append((time.perf_counter() - started) * 1000.0)
            outputs = {name: baseline(inputs[:, :3], scale, name) for name in BASELINES}
            outputs["model"] = model_output
            for name, output in outputs.items():
                delta = output - target
                accumulators[name]["absolute"] += float(delta.abs().sum())
                accumulators[name]["squared"] += float(delta.square().sum())
                accumulators[name]["ssim"] += float(ssim(output, target)) * target.shape[0]
            pixel_count += target.numel()
            frame_count += target.shape[0]
            if frame_count == target.shape[0]:
                save_comparison(
                    sample_directory / split,
                    str(frame_ids[0]),
                    {name: output[0].cpu() for name, output in outputs.items()},
                    target[0].cpu(),
                )
    metrics = {}
    for name in names:
        mse = accumulators[name]["squared"] / pixel_count
        metrics[name] = {
            "mae": accumulators[name]["absolute"] / pixel_count,
            "mse": mse,
            "psnr_db": psnr_from_mse(mse),
            "ssim": accumulators[name]["ssim"] / frame_count,
        }
    ordered = sorted(inference_ms)
    return {
        "frames": frame_count,
        "metrics": metrics,
        "model_batch_inference_ms": {
            "p50": float(np.percentile(ordered, 50)),
            "p95": float(np.percentile(ordered, 95)),
            "p99": float(np.percentile(ordered, 99)),
        },
    }


def checkpoint(model: Nr0SpatialResidualUpscaler, args: argparse.Namespace, dataset_sha256: str, epoch: int) -> dict:
    return {
        "schema": 2,
        "model": {
            "name": "nr0_multichannel_spatial_residual",
            "scale": model.scale,
            "features": model.features,
            "blocks": model.blocks_count,
            "input_planes": list(MODEL_PLANES),
        },
        "state_dict": {key: value.detach().cpu() for key, value in model.state_dict().items()},
        "dataset_sha256": dataset_sha256,
        "stage": args.stage,
        "selected_epoch": epoch,
        "seed": args.seed,
    }


def main() -> None:
    args = arguments()
    dataset_path = require_absolute(args.dataset, "--dataset")
    output = create_new_directory(args.output, "--output")
    if min(args.epochs, args.batch_size, args.patch_size, args.features, args.blocks, args.validation_every) <= 0 or args.learning_rate <= 0:
        raise ValueError("training configuration values must be positive")
    manifest = load_json(dataset_path)
    scale = int(manifest["dimensions"]["scale"])
    device = select_device(args.device)
    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)

    train_split = "overfit" if args.stage == "overfit" else "train"
    selection_split = "overfit" if args.stage == "overfit" else "validation"
    train_dataset = Nr0Dataset(dataset_path, train_split, patch_size=args.patch_size, seed=args.seed)
    selection_dataset = Nr0Dataset(dataset_path, selection_split)
    generator = torch.Generator().manual_seed(args.seed)
    train_loader = DataLoader(train_dataset, batch_size=args.batch_size, shuffle=True, generator=generator)
    selection_loader = DataLoader(selection_dataset, batch_size=1, shuffle=False)
    model = Nr0SpatialResidualUpscaler(scale=scale, features=args.features, blocks=args.blocks).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.learning_rate, weight_decay=1e-5)
    history: list[dict] = []
    validation_history: list[dict] = []
    selected_state = copy.deepcopy(model.state_dict())
    selected_epoch = 0
    selected_mae = float("inf")
    started = time.perf_counter()
    for epoch in range(1, args.epochs + 1):
        train_dataset.set_epoch(epoch)
        model.train()
        totals = {"loss": 0.0, "reconstruction": 0.0, "edge": 0.0, "structure": 0.0}
        batches = 0
        epoch_started = time.perf_counter()
        for inputs, target, _frame_ids in train_loader:
            inputs, target = inputs.to(device), target.to(device)
            optimizer.zero_grad(set_to_none=True)
            output_image = model(inputs)
            loss, terms = loss_terms(output_image, target)
            loss.backward()
            optimizer.step()
            totals["loss"] += float(loss.detach())
            for name, value in terms.items():
                totals[name] += value
            batches += 1
        synchronize(device)
        record = {
            "epoch": epoch,
            **{name: value / batches for name, value in totals.items()},
            "duration_ms": (time.perf_counter() - epoch_started) * 1000.0,
        }
        history.append(record)
        print(f"epoch={epoch} loss={record['loss']:.8f} duration_ms={record['duration_ms']:.2f}", flush=True)
        should_select = args.stage == "heldout" and (epoch % args.validation_every == 0 or epoch == args.epochs)
        if should_select:
            evaluation = evaluate(model, selection_loader, device, scale, output / "selection-samples", f"epoch-{epoch:04d}")
            mae = float(evaluation["metrics"]["model"]["mae"])
            validation_history.append({"epoch": epoch, "model_mae": mae})
            if mae < selected_mae:
                selected_mae = mae
                selected_epoch = epoch
                selected_state = copy.deepcopy(model.state_dict())

    if args.stage == "overfit":
        selected_epoch = args.epochs
        selected_state = copy.deepcopy(model.state_dict())
    model.load_state_dict(selected_state)
    dataset_digest = sha256_file(dataset_path)
    checkpoint_path = output / "checkpoint.pt"
    torch.save(checkpoint(model, args, dataset_digest, selected_epoch), checkpoint_path)

    evaluation_splits = ("overfit",) if args.stage == "overfit" else ("train", "validation", "test")
    evaluations = {
        split: evaluate(
            model,
            DataLoader(Nr0Dataset(dataset_path, split), batch_size=1, shuffle=False),
            device,
            scale,
            output / "samples",
            split,
        )
        for split in evaluation_splits
    }
    gate_split = selection_split
    gate_metrics = evaluations[gate_split]["metrics"]
    best_baseline_name = min(BASELINES, key=lambda name: gate_metrics[name]["mae"])
    beats_best_baseline = gate_metrics["model"]["mae"] < gate_metrics[best_baseline_name]["mae"]
    test_comparison = None
    if args.stage == "heldout":
        test_metrics = evaluations["test"]["metrics"]
        test_baseline_name = min(BASELINES, key=lambda name: test_metrics[name]["mae"])
        test_comparison = {
            "best_non_neural_baseline": test_baseline_name,
            "beats_best_non_neural_baseline_by_mae": test_metrics["model"]["mae"] < test_metrics[test_baseline_name]["mae"],
        }
    optimization_descended = history[-1]["loss"] < history[0]["loss"]
    gate_passed = beats_best_baseline and optimization_descended and (
        test_comparison is None or test_comparison["beats_best_non_neural_baseline_by_mae"]
    )
    status = "controlled_fit_passed" if args.stage == "overfit" and gate_passed else "candidate_for_human_review" if args.stage == "heldout" and gate_passed else "rejected"
    repo_root = Path(__file__).resolve().parents[2]
    tool_sources = {
        str(path.relative_to(repo_root)): sha256_file(path)
        for path in (
            Path(__file__).resolve(),
            repo_root / "tools/neural-rendering/nr0_dataset.py",
            repo_root / "tools/neural-rendering/nr0_model.py",
            repo_root / "tools/neural-rendering/nr_common.py",
        )
    }
    atomic_json(
        output / "training.json",
        {
            "schema": 2,
            "status": status,
            "experiment": "nr-0002-multichannel-spatial-baseline",
            "stage": args.stage,
            "dataset_manifest": str(dataset_path),
            "dataset_sha256": dataset_digest,
            "checkpoint": str(checkpoint_path),
            "checkpoint_sha256": sha256_file(checkpoint_path),
            "configuration": {
                "epochs": args.epochs,
                "batch_size": args.batch_size,
                "learning_rate": args.learning_rate,
                "patch_size_low_resolution": args.patch_size,
                "features": args.features,
                "blocks": args.blocks,
                "scale": scale,
                "seed": args.seed,
                "device": str(device),
                "loss": "smooth_l1(beta=0.01) + 0.1*gradient_l1 + 0.05*(1-ssim)",
                "optimizer": "AdamW(weight_decay=1e-5)",
            },
            "parameter_count": sum(parameter.numel() for parameter in model.parameters()),
            "training_ms": (time.perf_counter() - started) * 1000.0,
            "selected_epoch": selected_epoch,
            "history": history,
            "validation_selection_history": validation_history,
            "evaluation": evaluations,
            "gate": {
                "split": gate_split,
                "best_non_neural_baseline": best_baseline_name,
                "beats_best_non_neural_baseline_by_mae": beats_best_baseline,
                "optimization_loss_descended": optimization_descended,
                "post_selection_test": test_comparison,
                "passed": gate_passed,
            },
            "test_use": "test split evaluated exactly once after validation model selection" if args.stage == "heldout" else "not used",
            "tool_sources": tool_sources,
            "environment": environment_record(repo_root),
        },
    )
    print(output / "training.json")
    if args.require_gate and not gate_passed:
        raise SystemExit("NR0-C empirical comparator gate failed; evidence was retained")


if __name__ == "__main__":
    main()
