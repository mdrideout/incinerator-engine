#!/usr/bin/env python3
"""Compare two complete native NR4-C still proofs."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
from array import array
from pathlib import Path

from PIL import Image, ImageChops, ImageStat

from inspect_native_still import inspect
from nr4_common import atomic_json, load_json, read_ndjson, sha256_file


def canonical_json_digest(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
    ).hexdigest()


def normalized_package(package: dict) -> dict:
    value = copy.deepcopy(package)
    value["source_capture_frame"] = "<same-run-capture-frame>"
    return value


def image_difference(left: Path, right: Path) -> dict:
    with Image.open(left) as left_image, Image.open(right) as right_image:
        a = left_image.convert("RGB")
        b = right_image.convert("RGB")
        if a.size != b.size:
            raise ValueError("comparison images have different extents")
        difference = ImageChops.difference(a, b)
        extrema = difference.getextrema()
        mean = ImageStat.Stat(difference).mean
        return {
            "extent": list(a.size),
            "max_channel_error_u8": max(channel[1] for channel in extrema),
            "mean_channel_error_u8": mean,
            "byte_identical": left.read_bytes() == right.read_bytes(),
        }


def float_difference(left: Path, right: Path) -> dict:
    left_values = array("f")
    right_values = array("f")
    left_values.frombytes(left.read_bytes())
    right_values.frombytes(right.read_bytes())
    if len(left_values) != len(right_values):
        raise ValueError("comparison float buffers have different lengths")
    changed = 0
    squared_error = 0.0
    max_absolute_error = 0.0
    for left_value, right_value in zip(left_values, right_values, strict=True):
        if not math.isfinite(left_value) or not math.isfinite(right_value):
            raise ValueError("comparison float buffers contain non-finite evidence")
        difference = abs(left_value - right_value)
        if difference != 0.0:
            changed += 1
            squared_error += difference * difference
            max_absolute_error = max(max_absolute_error, difference)
    return {
        "value_count": len(left_values),
        "changed_value_count": changed,
        "max_absolute_error": max_absolute_error,
        "root_mean_square_error": math.sqrt(squared_error / len(left_values))
        if left_values
        else 0.0,
        "byte_identical": changed == 0,
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
    tool_sources_equal = left_tools == right_tools
    if not tool_sources_equal:
        raise ValueError("NR4-C tooling changed between reproducibility runs")
    left_capture = left_root / left_run["source"]["capture_root"]
    right_capture = right_root / right_run["source"]["capture_root"]
    left_capture_frame = load_json(
        left_capture / read_ndjson(left_capture / "frames.ndjson")[0]["frame_manifest"]
    )
    right_capture_frame = load_json(
        right_capture / read_ndjson(right_capture / "frames.ndjson")[0]["frame_manifest"]
    )
    capture_equal = {
        "frame_identity": left_capture_frame["frame_id"] == right_capture_frame["frame_id"],
        "camera": left_capture_frame["camera"] == right_capture_frame["camera"],
        "effects": left_capture_frame["effects"] == right_capture_frame["effects"],
        "global_controls": left_capture_frame["global_controls"]
        == right_capture_frame["global_controls"],
        "channels": [channel["raw_sha256"] for channel in left_capture_frame["channels"]]
        == [channel["raw_sha256"] for channel in right_capture_frame["channels"]],
        "identities": left_capture_frame["identities"] == right_capture_frame["identities"],
    }
    if not all(capture_equal.values()):
        raise ValueError(f"engine source recapture drifted: {capture_equal}")
    left_package_path = left_root / left_run["source"]["frame_package"]
    right_package_path = right_root / right_run["source"]["frame_package"]
    package_equal = canonical_json_digest(normalized_package(load_json(left_package_path))) == canonical_json_digest(
        normalized_package(load_json(right_package_path))
    )
    if not package_equal:
        raise ValueError("normalized target-frame package drifted")
    left_target = left_root / left_run["target"]["root"]
    right_target = right_root / right_run["target"]["root"]
    raw_equal = {
        name: sha256_file(left_target / name) == sha256_file(right_target / name)
        for name in ("identity.u32", "depth.f32", "normal.f32")
    }
    if not raw_equal["identity.u32"] or not raw_equal["depth.f32"]:
        raise ValueError(f"target identity/depth evidence drifted: {raw_equal}")
    normal_variation = float_difference(
        left_target / "normal.f32", right_target / "normal.f32"
    )
    return {
        "schema": 1,
        "status": "complete",
        "phase": "NR4-C-still",
        "left": str(left_root),
        "right": str(right_root),
        "engine_capture_equal": capture_equal,
        "tool_sources_equal": tool_sources_equal,
        "normalized_frame_package_equal": package_equal,
        "target_evidence_byte_equal": raw_equal,
        "target_normal_numeric_variation": normal_variation,
        "target_exr_byte_equal": sha256_file(left_target / "target.exr")
        == sha256_file(right_target / "target.exr"),
        "display_numeric_variation": image_difference(
            left_target / "target-display.png", right_target / "target-display.png"
        ),
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
    result = compare(args.left.resolve(), args.right.resolve())
    atomic_json(output, result)
    print(output)


if __name__ == "__main__":
    main()
