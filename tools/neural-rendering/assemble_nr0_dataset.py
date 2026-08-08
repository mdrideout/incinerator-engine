#!/usr/bin/env python3
"""Assemble immutable capture-schema-2 runs into an NR0-C dataset manifest."""

from __future__ import annotations

import argparse
import json
import time
from collections import Counter
from pathlib import Path

from inspect_nr0_capture import CHANNELS, load_capture
from nr0_dataset import MODEL_PLANES
from nr_common import (
    atomic_json,
    create_new_directory,
    environment_record,
    require_absolute,
    sha256_file,
)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--overfit-capture", action="append", required=True, type=Path)
    parser.add_argument("--train-capture", action="append", required=True, type=Path)
    parser.add_argument("--validation-capture", action="append", required=True, type=Path)
    parser.add_argument("--test-capture", action="append", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    args = arguments()
    output = create_new_directory(args.output, "--output")
    split_roots = {
        "overfit": args.overfit_capture,
        "train": args.train_capture,
        "validation": args.validation_capture,
        "test": args.test_capture,
    }
    resolved = [
        str(require_absolute(root, "capture root").resolve())
        for roots in split_roots.values()
        for root in roots
    ]
    if len(resolved) != len(set(resolved)):
        raise ValueError("one capture run cannot appear in more than one split")

    dimensions: dict | None = None
    provenance: dict | None = None
    sequence_split: dict[str, str] = {}
    captures: list[dict] = []
    frames: list[dict] = []
    counts: Counter[str] = Counter()
    started = time.perf_counter()
    for split, roots in split_roots.items():
        for supplied_root in roots:
            root = require_absolute(supplied_root, "capture root").resolve()
            loaded = load_capture(root)
            capture = loaded["capture"]
            sequence = str(capture["sequence"])
            previous = sequence_split.setdefault(sequence, split)
            if previous != split:
                raise ValueError(f"sequence {sequence} leaks across {previous}/{split}")
            if capture["cohort"] != split:
                raise ValueError(f"capture cohort {capture['cohort']} does not match split {split}: {root}")
            current_dimensions = {
                "input": capture["input_size"],
                "target": capture["target_size"],
                "scale": capture["target_size"][0] // capture["input_size"][0],
            }
            if dimensions is None:
                dimensions = current_dimensions
            elif dimensions != current_dimensions:
                raise ValueError(f"capture dimensions disagree: {root}")
            current_provenance = {
                "input_schema": capture["input_schema"],
                "shader_fingerprint": capture["shader_fingerprint"],
                "shader_sha256": capture["shader_sha256"],
                "source_revision": capture["source_revision"],
                "source_dirty": capture["source_dirty"],
                "source_dirty_fingerprint": capture["source_dirty_fingerprint"],
                "content_digest": capture["content_digest"],
            }
            if provenance is None:
                provenance = current_provenance
            elif provenance != current_provenance:
                raise ValueError(f"capture provenance cohort disagrees: {root}")
            captures.append(
                {
                    "split": split,
                    "root": str(root),
                    "sequence": sequence,
                    "camera_path": capture["camera_path"],
                    "capture_manifest_sha256": sha256_file(root / "capture.json"),
                    "recorded_frames": capture["recorded_frames"],
                }
            )
            for frame in loaded["frames"]:
                by_name = {channel["name"]: channel for channel in frame["channels"]}
                frames.append(
                    {
                        "frame_id": frame["frame_id"],
                        "split": split,
                        "source_capture_root": str(root),
                        "source_frame_manifest": str(root / "frames" / f"frame-{frame['presentation_frame']:08d}.json"),
                        "source_authority_tick": frame["authority_tick"],
                        "source_presentation_frame": frame["presentation_frame"],
                        "sequence": sequence,
                        "camera_path": frame["camera_path"],
                        "channel_paths": {
                            name: str(root / by_name[name]["raw_path"])
                            for name in CHANNELS
                        },
                        "channel_sha256": {
                            name: by_name[name]["raw_sha256"]
                            for name in CHANNELS
                        },
                        "target_path": str(root / frame["target"]["raw_path"]),
                        "target_sha256": frame["target"]["raw_sha256"],
                    }
                )
                counts[split] += 1

    if dimensions is None or provenance is None or any(counts[split] == 0 for split in split_roots):
        raise ValueError("every NR0-C dataset split must be non-empty")
    repo_root = Path(__file__).resolve().parents[2]
    atomic_json(
        output / "dataset.json",
        {
            "schema": 2,
            "status": "complete",
            "purpose": "NR0-C 17-plane spatial reconstruction baseline",
            "created_unix_ms": time.time_ns() // 1_000_000,
            "duration_ms": (time.perf_counter() - started) * 1000.0,
            "split_policy": {
                "unit": "whole_capture_sequence",
                "no_sequence_crosses_splits": True,
                "test_is_evaluated_only_after_model_selection": True,
            },
            "dimensions": dimensions,
            "capture_channels": list(CHANNELS),
            "model_planes": list(MODEL_PLANES),
            "normalization": "raw RGBA8 planes divided by 255; target and appearance remain in captured sRGB byte domain",
            "counts": dict(sorted(counts.items())),
            "provenance": provenance,
            "captures": captures,
            "environment": environment_record(repo_root),
            "frames": frames,
        },
    )
    print(output / "dataset.json")


if __name__ == "__main__":
    main()
