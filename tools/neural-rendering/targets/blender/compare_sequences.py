#!/usr/bin/env python3
"""Compare two native NR4-C proofs and measure renderer variation per frame."""

from __future__ import annotations

import argparse
from pathlib import Path

from compare_runs import (
    canonical_json_digest,
    float_difference,
    image_difference,
    normalized_package,
)
from inspect_sequence import inspect
from nr4_common import atomic_json, load_json, sha256_file


def capture_signature(frame: dict) -> dict:
    return {
        "frame_id": frame["frame_id"],
        "camera": frame["camera"],
        "effects": frame["effects"],
        "global_controls": frame["global_controls"],
        "channels": [channel["raw_sha256"] for channel in frame["channels"]],
        "identities": frame["identities"],
    }


def compare(left_root: Path, right_root: Path) -> dict:
    inspect(left_root)
    inspect(right_root)
    left_run = load_json(left_root / "run.json")
    right_run = load_json(right_root / "run.json")
    left_tools = [
        (record["repository_path"], record["sha256"])
        for record in left_run["environment"]["tool_sources"]
    ]
    right_tools = [
        (record["repository_path"], record["sha256"])
        for record in right_run["environment"]["tool_sources"]
    ]
    if left_tools != right_tools:
        raise ValueError("NR4-C tooling changed between reproducibility runs")
    left_sequence = load_json(left_root / left_run["sequence"]["manifest"])
    right_sequence = load_json(right_root / right_run["sequence"]["manifest"])
    if left_sequence["segments"] != right_sequence["segments"]:
        raise ValueError("NR4-C sequence ownership changed between runs")

    frames = []
    max_display_error = 0
    max_normal_error = 0.0
    max_normal_rmse = 0.0
    all_engine_equal = True
    all_packages_equal = True
    all_identity_equal = True
    all_depth_equal = True
    for left_frame, right_frame in zip(
        left_sequence["frames"], right_sequence["frames"], strict=True
    ):
        left_capture_path = left_root / left_frame["capture_frame"]
        right_capture_path = right_root / right_frame["capture_frame"]
        engine_equal = capture_signature(load_json(left_capture_path)) == capture_signature(
            load_json(right_capture_path)
        )
        left_package_path = left_root / left_frame["frame_package"]
        right_package_path = right_root / right_frame["frame_package"]
        package_equal = canonical_json_digest(
            normalized_package(load_json(left_package_path))
        ) == canonical_json_digest(normalized_package(load_json(right_package_path)))
        left_target = left_root / left_frame["target_root"]
        right_target = right_root / right_frame["target_root"]
        identity_equal = sha256_file(left_target / "identity.u32") == sha256_file(
            right_target / "identity.u32"
        )
        depth_equal = sha256_file(left_target / "depth.f32") == sha256_file(
            right_target / "depth.f32"
        )
        if not engine_equal or not package_equal or not identity_equal or not depth_equal:
            raise ValueError(
                "NR4-C repeated source/identity truth drifted: "
                f"engine={engine_equal} package={package_equal} "
                f"identity={identity_equal} depth={depth_equal}"
            )
        normal = float_difference(left_target / "normal.f32", right_target / "normal.f32")
        display = image_difference(
            left_target / "target-display.png", right_target / "target-display.png"
        )
        max_display_error = max(max_display_error, display["max_channel_error_u8"])
        max_normal_error = max(max_normal_error, normal["max_absolute_error"])
        max_normal_rmse = max(max_normal_rmse, normal["root_mean_square_error"])
        all_engine_equal = all_engine_equal and engine_equal
        all_packages_equal = all_packages_equal and package_equal
        all_identity_equal = all_identity_equal and identity_equal
        all_depth_equal = all_depth_equal and depth_equal
        frames.append(
            {
                "frame_id": left_frame["frame_id"],
                "segment": left_frame["segment"],
                "sample_index": left_frame["sample_index"],
                "engine_capture_equal": engine_equal,
                "normalized_frame_package_equal": package_equal,
                "target_identity_byte_equal": identity_equal,
                "target_depth_byte_equal": depth_equal,
                "target_normal_numeric_variation": normal,
                "target_exr_byte_equal": sha256_file(left_target / "target.exr")
                == sha256_file(right_target / "target.exr"),
                "display_numeric_variation": display,
            }
        )
    return {
        "schema": 1,
        "status": "complete",
        "phase": "NR4-C",
        "left": str(left_root),
        "right": str(right_root),
        "tool_sources_equal": left_tools == right_tools,
        "engine_capture_equal": all_engine_equal,
        "normalized_frame_packages_equal": all_packages_equal,
        "target_identity_byte_equal": all_identity_equal,
        "target_depth_byte_equal": all_depth_equal,
        "maximum_display_channel_error_u8": max_display_error,
        "maximum_normal_absolute_error": max_normal_error,
        "maximum_normal_rmse": max_normal_rmse,
        "frames": frames,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("left", type=Path)
    parser.add_argument("right", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists():
        raise FileExistsError(f"comparison output already exists: {output}")
    atomic_json(output, compare(args.left.resolve(), args.right.resolve()))
    print(output)


if __name__ == "__main__":
    main()
