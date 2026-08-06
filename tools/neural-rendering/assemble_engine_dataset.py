#!/usr/bin/env python3
"""Assemble declared engine capture runs into whole-run dataset splits."""

from __future__ import annotations

import argparse
import json
import shutil
import time
from collections import Counter
from pathlib import Path

from nr_common import (
    atomic_json,
    create_new_directory,
    environment_record,
    load_json,
    require_absolute,
    sha256_file,
)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--train-capture", required=True, action="append", type=Path)
    parser.add_argument("--validation-capture", required=True, action="append", type=Path)
    parser.add_argument("--test-capture", required=True, action="append", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def read_capture(root: Path) -> tuple[dict, list[dict]]:
    require_absolute(root, "capture root")
    manifest = load_json(root / "capture.json")
    if manifest.get("schema") != 1 or manifest.get("status") != "complete":
        raise ValueError(f"capture is not schema-1 complete: {root}")
    frames = []
    with (root / str(manifest["frame_index"])).open("r", encoding="utf-8") as source:
        for line_number, line in enumerate(source, 1):
            try:
                frame = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f"invalid frame index {root}:{line_number}") from error
            frames.append(frame)
    if len(frames) != manifest.get("recorded_frames"):
        raise ValueError(f"frame count does not match capture manifest: {root}")
    return manifest, frames


def main() -> None:
    args = arguments()
    output = create_new_directory(args.output, "--output")
    split_roots = {
        "train": args.train_capture,
        "validation": args.validation_capture,
        "test": args.test_capture,
    }
    identities = [str(require_absolute(root, "capture root")) for roots in split_roots.values() for root in roots]
    if len(identities) != len(set(identities)):
        raise ValueError("one capture run cannot appear in more than one split")

    dimensions = None
    dataset_frames = []
    counts: Counter[str] = Counter()
    captures = []
    started = time.perf_counter()
    for split, roots in split_roots.items():
        for root in roots:
            root = require_absolute(root, "capture root")
            manifest, frames = read_capture(root)
            capture_dimensions = {
                "input": manifest["input_size"],
                "target": manifest["target_size"],
                "scale": manifest["scale"],
            }
            if dimensions is None:
                dimensions = capture_dimensions
            elif dimensions != capture_dimensions:
                raise ValueError(f"capture dimensions disagree: {root}")
            run_id = root.name
            captures.append(
                {
                    "split": split,
                    "root": str(root),
                    "manifest_sha256": sha256_file(root / "capture.json"),
                    "frames": len(frames),
                }
            )
            for frame in frames:
                frame_id = f"{run_id}-{frame['frame_id']}"
                input_relative = Path("inputs") / split / f"{frame_id}.ppm"
                target_relative = Path("targets") / split / f"{frame_id}.ppm"
                (output / input_relative).parent.mkdir(parents=True, exist_ok=True)
                (output / target_relative).parent.mkdir(parents=True, exist_ok=True)
                source_input = root / frame["input_path"]
                source_target = root / frame["target_path"]
                if sha256_file(source_input) != frame["input_sha256"]:
                    raise ValueError(f"input digest mismatch: {source_input}")
                if sha256_file(source_target) != frame["target_sha256"]:
                    raise ValueError(f"target digest mismatch: {source_target}")
                shutil.copyfile(source_input, output / input_relative)
                shutil.copyfile(source_target, output / target_relative)
                dataset_frames.append(
                    {
                        "frame_id": frame_id,
                        "split": split,
                        "source_run": run_id,
                        "source_capture_root": str(root),
                        "source_authority_tick": frame["authority_tick"],
                        "source_presentation_frame": frame["presentation_frame"],
                        "input_path": str(input_relative),
                        "input_sha256": frame["input_sha256"],
                        "target_path": str(target_relative),
                        "target_sha256": frame["target_sha256"],
                    }
                )
                counts[split] += 1
    if dimensions is None or any(counts[name] == 0 for name in split_roots):
        raise ValueError("every dataset split must be non-empty")
    repo_root = Path(__file__).resolve().parents[2]
    atomic_json(
        output / "dataset.json",
        {
            "schema": 1,
            "status": "complete",
            "purpose": "exact same-frame engine product-color spatial pipeline proof; not NR0 auxiliary-buffer capture",
            "created_unix_ms": time.time_ns() // 1_000_000,
            "duration_ms": (time.perf_counter() - started) * 1000.0,
            "split_policy": {"unit": "whole_engine_capture_run"},
            "dimensions": dimensions,
            "counts": dict(sorted(counts.items())),
            "captures": captures,
            "environment": environment_record(repo_root),
            "frames": dataset_frames,
        },
    )
    print(output / "dataset.json")


if __name__ == "__main__":
    main()
