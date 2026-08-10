"""Shared deterministic baselines, branch ablations, metrics, and visual evidence."""

from __future__ import annotations

import time
from pathlib import Path
from typing import Any

import numpy as np
import torch
from torch.utils.data import DataLoader

from .metrics import BASELINES, comparison_sheet, metrics, overview_sheet, resize_baseline


ABLATIONS = ("no_semantic", "no_instance", "no_globals", "appearance_only")


def synchronize(device: torch.device) -> None:
    if device.type == "mps":
        torch.mps.synchronize()


def model_output(model: torch.nn.Module, batch: dict[str, torch.Tensor], device: torch.device, mode: str) -> torch.Tensor:
    continuous = batch["continuous"].to(device)
    semantic = batch["semantic"].to(device)
    instance = batch["instance"].to(device)
    controls = batch["global_controls"].to(device)
    if mode == "no_semantic":
        semantic = torch.zeros_like(semantic)
    elif mode == "no_instance":
        instance = torch.zeros_like(instance)
    elif mode == "no_globals":
        controls = torch.zeros_like(controls)
    elif mode == "appearance_only":
        continuous = torch.cat((continuous[:, :3], torch.zeros_like(continuous[:, 3:])), dim=1)
        semantic = torch.zeros_like(semantic)
        instance = torch.zeros_like(instance)
        controls = torch.zeros_like(controls)
    elif mode != "model":
        raise ValueError(f"unknown model evaluation mode: {mode}")
    return model(continuous, semantic, instance, controls)


def evaluate(
    model: torch.nn.Module,
    loader: DataLoader,
    device: torch.device,
    *,
    sample_root: Path | None = None,
    overview_path: Path | None = None,
) -> dict[str, Any]:
    names = (*BASELINES, "model", *ABLATIONS)
    totals: dict[str, dict[str, float]] = {}
    per_frame: list[dict[str, Any]] = []
    inference_ms: list[float] = []
    model.eval()
    with torch.inference_mode():
        for index, batch in enumerate(loader):
            continuous = batch["continuous"].to(device)
            semantic = batch["semantic"].to(device)
            instance = batch["instance"].to(device)
            target = batch["target"].to(device)
            outputs = {
                name: resize_baseline(continuous[:, :3], (target.shape[2], target.shape[3]), name)
                for name in BASELINES
            }
            synchronize(device)
            started = time.perf_counter()
            outputs["model"] = model_output(model, batch, device, "model")
            synchronize(device)
            inference_ms.append((time.perf_counter() - started) * 1000.0)
            for name in ABLATIONS:
                outputs[name] = model_output(model, batch, device, name)
            frame_metrics = {name: metrics(value, target, semantic, instance) for name, value in outputs.items()}
            for name in names:
                totals.setdefault(name, {metric: 0.0 for metric in frame_metrics[name]})
                for metric, value in frame_metrics[name].items():
                    totals[name][metric] += value
            frame_id = str(batch["frame_id"][0])
            per_frame.append({"frame_id": frame_id, "metrics": frame_metrics})
            if sample_root is not None:
                comparison_sheet(
                    sample_root / f"{index:04d}-{frame_id}.png",
                    frame_id,
                    [
                        ("cheap bilinear", outputs["bilinear"][0]),
                        ("appearance only", outputs["appearance_only"][0]),
                        ("no semantic", outputs["no_semantic"][0]),
                        ("no instance", outputs["no_instance"][0]),
                        ("no globals", outputs["no_globals"][0]),
                        ("full model", outputs["model"][0]),
                        ("target", target[0]),
                    ],
                )
    count = len(per_frame)
    if count == 0:
        raise ValueError("cannot evaluate an empty title-renderer split")
    result = {
        "frames": count,
        "metrics": {
            name: {metric: value / count for metric, value in metric_totals.items()}
            for name, metric_totals in totals.items()
        },
        "per_frame": per_frame,
        "inference_ms": {
            "minimum": min(inference_ms),
            "median": float(np.percentile(inference_ms, 50)),
            "p95": float(np.percentile(inference_ms, 95)),
            "maximum": max(inference_ms),
            "scope": "offline PyTorch full-frame batch; not installed runtime",
        },
    }
    if sample_root is not None:
        sheets = sorted(sample_root.glob("*.png"))
        if len(sheets) != count:
            raise ValueError("split visual evidence is incomplete")
        if overview_path is None:
            raise ValueError("visual evaluation requires an overview path")
        overview_sheet(overview_path, sheets)
        result["visual_evidence"] = {
            "frame_sheets": len(sheets),
            "overview": str(overview_path),
        }
    return result
