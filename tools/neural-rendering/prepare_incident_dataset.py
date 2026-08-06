#!/usr/bin/env python3
"""Build a reproducible session-separated spatial smoke dataset."""

from __future__ import annotations

import argparse
import time
from collections import Counter
from pathlib import Path

from PIL import Image

from nr_common import (
    SCHEMA_VERSION,
    atomic_json,
    create_new_directory,
    environment_record,
    require_absolute,
    sha256_file,
)


def parse_size(value: str) -> tuple[int, int]:
    try:
        width_text, height_text = value.lower().split("x", 1)
        width, height = int(width_text), int(height_text)
    except (ValueError, TypeError) as error:
        raise argparse.ArgumentTypeError("size must be WIDTHxHEIGHT") from error
    if width <= 0 or height <= 0:
        raise argparse.ArgumentTypeError("dimensions must be positive")
    return width, height


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--incident-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--validation-run", required=True)
    parser.add_argument("--test-run", required=True)
    parser.add_argument("--target-size", type=parse_size, default=(320, 180))
    parser.add_argument("--scale", type=int, default=4)
    parser.add_argument(
        "--selection-stride",
        type=int,
        default=1,
        help="Take every Nth source frame. The chosen value is recorded.",
    )
    return parser.parse_args()


def main() -> None:
    args = arguments()
    incident_root = require_absolute(args.incident_root, "--incident-root")
    output = create_new_directory(args.output, "--output")
    if args.scale <= 1:
        raise ValueError("--scale must be greater than one")
    if args.selection_stride <= 0:
        raise ValueError("--selection-stride must be positive")
    target_width, target_height = args.target_size
    if target_width % args.scale or target_height % args.scale:
        raise ValueError("target dimensions must be divisible by --scale")
    input_size = (target_width // args.scale, target_height // args.scale)

    run_directories = sorted(
        path for path in incident_root.iterdir() if (path / "visual").is_dir()
    )
    names = {path.name for path in run_directories}
    for split_name in (args.validation_run, args.test_run):
        if split_name not in names:
            raise ValueError(f"declared split run is absent: {split_name}")
    if args.validation_run == args.test_run:
        raise ValueError("validation and test must use different runs")

    frames: list[dict[str, object]] = []
    counts: Counter[str] = Counter()
    started = time.perf_counter()
    for run in run_directories:
        if run.name == args.validation_run:
            split = "validation"
        elif run.name == args.test_run:
            split = "test"
        else:
            split = "train"
        sources = sorted((run / "visual").glob("*.ppm"))[:: args.selection_stride]
        for ordinal, source in enumerate(sources):
            frame_id = f"{run.name}-{ordinal:06d}"
            relative_target = Path("targets") / split / f"{frame_id}.png"
            relative_input = Path("inputs") / split / f"{frame_id}.png"
            target_path = output / relative_target
            input_path = output / relative_input
            target_path.parent.mkdir(parents=True, exist_ok=True)
            input_path.parent.mkdir(parents=True, exist_ok=True)
            with Image.open(source) as source_image:
                rgb = source_image.convert("RGB")
                target = rgb.resize(args.target_size, Image.Resampling.LANCZOS)
                low = target.resize(input_size, Image.Resampling.BICUBIC)
                target.save(target_path, format="PNG", optimize=False)
                low.save(input_path, format="PNG", optimize=False)
                source_size = list(rgb.size)
            frames.append(
                {
                    "frame_id": frame_id,
                    "split": split,
                    "source_run": run.name,
                    "source_path": str(source),
                    "source_sha256": sha256_file(source),
                    "source_size": source_size,
                    "target_path": str(relative_target),
                    "target_sha256": sha256_file(target_path),
                    "input_path": str(relative_input),
                    "input_sha256": sha256_file(input_path),
                }
            )
            counts[split] += 1

    if not frames or any(counts[split] == 0 for split in ("train", "validation", "test")):
        raise ValueError(f"all dataset splits must contain frames: {dict(counts)}")

    repo_root = Path(__file__).resolve().parents[2]
    atomic_json(
        output / "dataset.json",
        {
            "schema": SCHEMA_VERSION,
            "status": "complete",
            "purpose": "existing-frame spatial pipeline proof; not exact NR0 paired capture",
            "created_unix_ms": time.time_ns() // 1_000_000,
            "duration_ms": (time.perf_counter() - started) * 1000.0,
            "source_incident_root": str(incident_root),
            "split_policy": {
                "unit": "whole_incident_run",
                "validation_run": args.validation_run,
                "test_run": args.test_run,
                "selection_stride": args.selection_stride,
            },
            "dimensions": {
                "input": list(input_size),
                "target": list(args.target_size),
                "scale": args.scale,
            },
            "counts": dict(sorted(counts.items())),
            "environment": environment_record(repo_root),
            "frames": frames,
        },
    )
    print(output / "dataset.json")


if __name__ == "__main__":
    main()
