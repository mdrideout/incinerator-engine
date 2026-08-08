#!/usr/bin/env python3
"""Evaluate one immutable NR0-C candidate over complete NR0-D stress captures."""

from __future__ import annotations

import argparse
import json
import resource
import time
from pathlib import Path

import numpy as np
import torch
from PIL import Image, ImageDraw
from torch.nn import functional

from inspect_nr0_capture import load_capture
from nr0_d_metrics import (
    categorical_boundary,
    decode_instance,
    metrics,
    temporal_reprojection,
    upsample_mask,
)
from nr0_dataset import CHANNELS, MODEL_PLANES, load_frame
from nr0_model import checkpoint_model
from nr_common import (
    atomic_json,
    create_new_directory,
    environment_record,
    require_absolute,
    select_device,
    sha256_file,
    synchronize,
    tensor_to_image,
)


BASELINES = ("nearest", "bilinear", "bicubic")
METHODS = (*BASELINES, "model")
FIXTURE_FINGERPRINT = (
    "nr0-d-fixture-v1|rigid-edges|thin-features|small-objects|depth-layers|"
    "moving-occluder|rotating-parts|stable-identities"
)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", required=True, type=Path)
    parser.add_argument("--capture", required=True, action="append", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--device", choices=("auto", "mps", "cpu"), default="auto")
    return parser.parse_args()


def rgba(path: Path, width: int, height: int) -> torch.Tensor:
    pixels = np.fromfile(path, dtype=np.uint8).reshape(height, width, 4)
    return torch.from_numpy(pixels.copy()).permute(2, 0, 1)


def frame_record(root: Path, frame: dict) -> dict:
    channels = {item["name"]: item for item in frame["channels"]}
    return {
        "frame_id": frame["frame_id"],
        "channel_paths": {name: str(root / channels[name]["raw_path"]) for name in CHANNELS},
        "target_path": str(root / frame["target"]["raw_path"]),
    }


def baseline(appearance: torch.Tensor, scale: int, name: str) -> torch.Tensor:
    arguments = {"scale_factor": float(scale), "mode": name}
    if name != "nearest":
        arguments["align_corners"] = False
    return functional.interpolate(appearance, **arguments).clamp(0, 1)


def ndjson(path: Path, records: list[dict]) -> None:
    with path.open("x", encoding="utf-8") as output:
        for record in records:
            output.write(json.dumps(record, sort_keys=True) + "\n")


def save_views(directory: Path, outputs: dict[str, torch.Tensor], target: torch.Tensor, semantic: torch.Tensor, instance: torch.Tensor) -> dict[str, str]:
    directory.mkdir(parents=True)
    images: list[tuple[str, Image.Image]] = [("target", tensor_to_image(target[0]))]
    images.extend((name, tensor_to_image(outputs[name][0])) for name in METHODS)
    error = (outputs["model"] - target).abs().mean(dim=1, keepdim=True).repeat(1, 3, 1, 1) * 4
    images.append(("model-error-x4", tensor_to_image(error[0])))
    images.append(("semantic", tensor_to_image(semantic.float() / 255.0)))
    images.append(("instance", tensor_to_image(instance.float() / 255.0)))
    result = {}
    for name, image in images:
        path = directory / f"{name}.png"
        image.save(path)
        result[name] = str(path)
    header = 28
    sheet = Image.new("RGB", (images[0][1].width * len(images), images[0][1].height + header), "white")
    draw = ImageDraw.Draw(sheet)
    for index, (name, image) in enumerate(images):
        x = index * image.width
        sheet.paste(image, (x, header))
        draw.text((x + 8, 7), name, fill="black")
    sheet_path = directory / "comparison.png"
    sheet.save(sheet_path)
    result["comparison"] = str(sheet_path)
    return result


def crop_box(error: torch.Tensor, crop_width: int = 256, crop_height: int = 256) -> tuple[int, int, int, int]:
    height, width = error.shape
    flat = int(error.argmax())
    y, x = divmod(flat, width)
    left = min(max(x - crop_width // 2, 0), max(width - crop_width, 0))
    top = min(max(y - crop_height // 2, 0), max(height - crop_height, 0))
    return left, top, min(left + crop_width, width), min(top + crop_height, height)


def mps_memory() -> dict:
    if not torch.backends.mps.is_available():
        return {"current_allocated_bytes": None, "driver_allocated_bytes": None}
    return {
        "current_allocated_bytes": int(torch.mps.current_allocated_memory()),
        "driver_allocated_bytes": int(torch.mps.driver_allocated_memory()),
    }


def aggregate_spatial(records: list[dict]) -> dict:
    result = {}
    for method in METHODS:
        result[method] = {}
        for scope in ("full", "coverage", "semantic_boundary", "instance_boundary"):
            values = [record["metrics"][method][scope] for record in records]
            weighted = [value for value in values if value["pixels"] and value["mae"] is not None]
            pixels = sum(value["pixels"] for value in weighted)
            if pixels == 0:
                result[method][scope] = {"pixels": 0, "mae": None, "mse": None, "psnr_db": None, "gradient_mae": None}
                continue
            mae = sum(value["mae"] * value["pixels"] for value in weighted) / pixels
            mse = sum(value["mse"] * value["pixels"] for value in weighted) / pixels
            gradient = sum(value["gradient_mae"] * value["pixels"] for value in weighted) / pixels
            result[method][scope] = {
                "pixels": pixels,
                "mae": mae,
                "mse": mse,
                "psnr_db": None if mse == 0 else 10.0 * float(np.log10(1.0 / mse)),
                "gradient_mae": gradient,
            }
            if scope == "full":
                result[method][scope]["mean_frame_ssim"] = float(np.mean([value["ssim"] for value in values]))
    return result


def main() -> None:
    args = arguments()
    checkpoint_path = require_absolute(args.checkpoint, "--checkpoint")
    capture_roots = [require_absolute(path, "--capture") for path in args.capture]
    output = create_new_directory(args.output, "--output")
    started = time.perf_counter()
    atomic_json(output / "evaluation-state.json", {"schema": 1, "status": "partial"})
    loaded = [load_capture(root) for root in capture_roots]
    sequences: set[str] = set()
    provenance = None
    for capture in loaded:
        manifest = capture["capture"]
        if manifest["cohort"] != "stress":
            raise ValueError(f"NR0-D requires stress cohort ownership: {capture['root']}")
        if manifest["sequence"] in sequences:
            raise ValueError(f"NR0-D stress sequence repeated: {manifest['sequence']}")
        sequences.add(manifest["sequence"])
        current = {
            "input_schema": manifest["input_schema"],
            "shader_fingerprint": manifest["shader_fingerprint"],
            "shader_sha256": manifest["shader_sha256"],
            "content_digest": manifest["content_digest"],
        }
        if provenance is None:
            provenance = current
        elif provenance != current:
            raise ValueError("NR0-D captures disagree on schema/shader/content provenance")

    checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=False)
    if tuple(checkpoint["model"].get("input_planes", ())) != MODEL_PLANES:
        raise ValueError("candidate checkpoint model-plane ABI drift")
    device = select_device(args.device)
    model = checkpoint_model(checkpoint).to(device).eval()
    parameter_count = sum(parameter.numel() for parameter in model.parameters())
    frame_metrics: list[dict] = []
    instance_metrics: list[dict] = []
    temporal_metrics: list[dict] = []
    inference_ms: list[float] = []
    review_candidates: dict[str, tuple[float, Path, tuple[int, int, int, int]]] = {}
    previous = None
    memory_before = mps_memory()

    with torch.inference_mode():
        for capture in loaded:
            root = capture["root"]
            previous = None
            for frame in capture["frames"]:
                record = frame_record(root, frame)
                inputs_cpu, target_cpu = load_frame(record, (400, 225), (1600, 900))
                inputs = inputs_cpu[None].to(device)
                target = target_cpu[None].to(device)
                synchronize(device)
                inference_started = time.perf_counter()
                model_output = model(inputs)
                synchronize(device)
                elapsed_ms = (time.perf_counter() - inference_started) * 1000
                inference_ms.append(elapsed_ms)
                outputs = {name: baseline(inputs[:, :3], 4, name) for name in BASELINES}
                outputs["model"] = model_output

                channel_paths = {name: Path(path) for name, path in record["channel_paths"].items()}
                semantic_low = rgba(channel_paths["semantic"], 400, 225)[:3].to(device)
                instance_rgb_low = rgba(channel_paths["instance"], 400, 225)[:3].to(device)
                appearance_low = rgba(channel_paths["appearance"], 400, 225).to(device)
                motion_low = rgba(channel_paths["motion"], 400, 225)[:3].float().to(device) / 255.0
                coverage_low = appearance_low[3] != 0
                semantic_boundary = upsample_mask(
                    categorical_boundary(semantic_low, coverage_low), (900, 1600)
                )
                coverage = upsample_mask(coverage_low, (900, 1600))
                instance_low = decode_instance(instance_rgb_low)
                instance_boundary = upsample_mask(
                    categorical_boundary(instance_rgb_low, coverage_low), (900, 1600)
                )
                method_metrics = {}
                for name, value in outputs.items():
                    method_metrics[name] = {
                        "full": metrics(value, target),
                        "coverage": metrics(value, target, coverage),
                        "semantic_boundary": metrics(value, target, semantic_boundary),
                        "instance_boundary": metrics(value, target, instance_boundary),
                    }
                frame_directory = output / "frames" / frame["frame_id"]
                semantic_high = functional.interpolate(semantic_low[None].float(), size=(900, 1600), mode="nearest")[0]
                instance_rgb_high = functional.interpolate(instance_rgb_low[None].float(), size=(900, 1600), mode="nearest")[0]
                views = save_views(frame_directory, outputs, target, semantic_high, instance_rgb_high)
                frame_metrics.append({
                    "frame_id": frame["frame_id"],
                    "sequence": frame["sequence"],
                    "camera_path": frame["camera_path"],
                    "presentation_frame": frame["presentation_frame"],
                    "source_scene_size": frame["source_scene_size"],
                    "history_reset": frame["camera"]["history_reset"],
                    "inference_ms": elapsed_ms,
                    "metrics": method_metrics,
                    "views": views,
                })

                identity_by_code = {item["compact_rgb24"]: item for item in frame["identities"]}
                for code in torch.unique(instance_low[coverage_low]).tolist():
                    code = int(code)
                    if code == 0:
                        continue
                    mask = upsample_mask(instance_low == code, (900, 1600))
                    boundary = mask & instance_boundary
                    identity = identity_by_code[code]
                    instance_metrics.append({
                        "frame_id": frame["frame_id"],
                        "compact_rgb24": code,
                        "stable_key": identity["stable_key"],
                        "semantic": identity["semantic"],
                        "part": identity["part"],
                        "low_resolution_pixels": int((instance_low == code).sum()),
                        "target_pixels": int(mask.sum()),
                        "metrics": {
                            name: {
                                "interior": metrics(value, target, mask),
                                "boundary": metrics(value, target, boundary),
                            }
                            for name, value in outputs.items()
                        },
                    })

                error_map = (model_output - target).abs().mean(dim=1)[0]
                categories = {
                    "overall": error_map,
                    "semantic-boundary": error_map * semantic_boundary[0, 0],
                    "instance-boundary": error_map * instance_boundary[0, 0],
                }
                for category, error in categories.items():
                    score = float(error.max())
                    if category not in review_candidates or score > review_candidates[category][0]:
                        review_candidates[category] = (score, Path(views["comparison"]), crop_box(error))

                reset = frame["camera"]["history_reset"]
                if previous is not None and reset == "none":
                    temporal_methods = {}
                    disoccluded = None
                    model_temporal_error = None
                    for name in METHODS:
                        warped, valid, disoccluded = temporal_reprojection(
                            previous["outputs"][name],
                            motion_low,
                            previous["semantic"],
                            semantic_low,
                            previous["instance"],
                            instance_low,
                            coverage_low,
                            (900, 1600),
                        )
                        target_warped, _, _ = temporal_reprojection(
                            previous["target"],
                            motion_low,
                            previous["semantic"],
                            semantic_low,
                            previous["instance"],
                            instance_low,
                            coverage_low,
                            (900, 1600),
                        )
                        output_delta = outputs[name] - warped
                        target_delta = target - target_warped
                        temporal_methods[name] = {
                            "valid_history_residual": metrics(output_delta, target_delta, valid),
                            "disoccluded_current": metrics(outputs[name], target, disoccluded),
                        }
                        if name == "model":
                            model_temporal_error = (output_delta - target_delta).abs().mean(dim=1)[0]
                    if model_temporal_error is None:
                        raise AssertionError("model temporal error was not measured")
                    temporal_masks = {
                        "temporal-valid-history": valid[0, 0],
                        "disocclusion-current": disoccluded[0, 0],
                    }
                    current_model_error = (outputs["model"] - target).abs().mean(dim=1)[0]
                    temporal_error_maps = {
                        "temporal-valid-history": model_temporal_error,
                        "disocclusion-current": current_model_error,
                    }
                    for category, mask in temporal_masks.items():
                        if not bool(mask.any()):
                            continue
                        error = temporal_error_maps[category] * mask
                        score = float(error.max())
                        if category not in review_candidates or score > review_candidates[category][0]:
                            review_candidates[category] = (
                                score,
                                Path(views["comparison"]),
                                crop_box(error),
                            )
                    temporal_metrics.append({
                        "previous_frame_id": previous["frame_id"],
                        "frame_id": frame["frame_id"],
                        "history_reset": reset,
                        "valid_history_pixels": int(valid.sum()),
                        "disoccluded_pixels": int(disoccluded.sum()),
                        "metrics": temporal_methods,
                    })
                else:
                    temporal_metrics.append({
                        "previous_frame_id": previous["frame_id"] if previous else None,
                        "frame_id": frame["frame_id"],
                        "history_reset": reset,
                        "excluded": True,
                    })
                previous = {
                    "frame_id": frame["frame_id"],
                    "outputs": {name: value.detach() for name, value in outputs.items()},
                    "target": target.detach(),
                    "semantic": semantic_low,
                    "instance": instance_low,
                }

    review_directory = output / "review-crops"
    review_directory.mkdir()
    review_records = []
    for category, (score, comparison_path, box) in sorted(review_candidates.items()):
        with Image.open(comparison_path) as comparison:
            # Crop every synchronized column at the same measured scene coordinates.
            scene_width = 1600
            header = 28
            crops = []
            columns = comparison.width // scene_width
            for column in range(columns):
                shifted = (box[0] + column * scene_width, box[1] + header, box[2] + column * scene_width, box[3] + header)
                crops.append(comparison.crop(shifted))
            sheet = Image.new("RGB", (sum(image.width for image in crops), max(image.height for image in crops)), "white")
            x = 0
            for image in crops:
                sheet.paste(image, (x, 0))
                x += image.width
            path = review_directory / f"{category}.png"
            sheet.save(path)
        review_records.append({"category": category, "score": score, "source": str(comparison_path), "box": box, "path": str(path)})

    ndjson(output / "frame-metrics.ndjson", frame_metrics)
    ndjson(output / "instance-metrics.ndjson", instance_metrics)
    ndjson(output / "temporal-metrics.ndjson", temporal_metrics)
    aggregate = aggregate_spatial(frame_metrics)
    atomic_json(output / "aggregate.json", aggregate)
    ordered_ms = np.asarray(inference_ms, dtype=np.float64)
    evidence_files = [
        {"path": str(path), "sha256": sha256_file(path)}
        for path in sorted(output.rglob("*.png"))
    ]
    repo_root = Path(__file__).resolve().parents[2]
    tool_paths = (
        Path(__file__).resolve(),
        repo_root / "tools/neural-rendering/nr0_d_metrics.py",
        repo_root / "tools/neural-rendering/nr0_dataset.py",
        repo_root / "tools/neural-rendering/nr0_model.py",
        repo_root / "tools/neural-rendering/inspect_nr0_capture.py",
    )
    complete = {
        "schema": 1,
        "status": "complete",
        "phase": "NR0-D evaluation and failure analysis",
        "result": "pending_human_review",
        "fixture_fingerprint": FIXTURE_FINGERPRINT,
        "candidate": {
            "checkpoint": str(checkpoint_path),
            "checkpoint_sha256": sha256_file(checkpoint_path),
            "parameter_count": parameter_count,
            "model_planes": list(MODEL_PLANES),
            "promotion": "external unpromoted candidate",
        },
        "captures": [
            {
                "root": str(item["root"]),
                "manifest_sha256": sha256_file(item["root"] / "capture.json"),
                "sequence": item["capture"]["sequence"],
                "camera_path": item["capture"]["camera_path"],
                "frames": len(item["frames"]),
            }
            for item in loaded
        ],
        "provenance": provenance,
        "records": {
            "frames": len(frame_metrics),
            "instances": len(instance_metrics),
            "temporal_pairs": len(temporal_metrics),
            "frame_metrics": "frame-metrics.ndjson",
            "instance_metrics": "instance-metrics.ndjson",
            "temporal_metrics": "temporal-metrics.ndjson",
            "aggregate": "aggregate.json",
        },
        "aggregate": aggregate,
        "inference_ms": {
            "p50": float(np.percentile(ordered_ms, 50)),
            "p95": float(np.percentile(ordered_ms, 95)),
            "p99": float(np.percentile(ordered_ms, 99)),
            "maximum": float(ordered_ms.max()),
        },
        "memory": {
            "mps_before": memory_before,
            "mps_after": mps_memory(),
            "process_peak_rss_bytes": int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss),
        },
        "review_crops": review_records,
        "evidence_files": evidence_files,
        "tool_sources": {
            str(path.relative_to(repo_root)): sha256_file(path) for path in tool_paths
        },
        "duration_ms": (time.perf_counter() - started) * 1000,
        "capability_gaps": [
            "no explicit roughness, metallic, emissive, alpha-test, transparency, or volumetric fields in the current renderer/input ABI",
            "exposure is frame metadata but is not an NR-0002 input plane",
            "installed GPU-resident 17-plane inference, composition, fallback, frame pacing, and residency remain NR0-F",
        ],
        "environment": environment_record(repo_root),
    }
    atomic_json(output / "evaluation.json", complete)
    atomic_json(output / "evaluation-state.json", {"schema": 1, "status": "complete", "manifest": "evaluation.json"})
    print(output / "evaluation.json")


if __name__ == "__main__":
    main()
