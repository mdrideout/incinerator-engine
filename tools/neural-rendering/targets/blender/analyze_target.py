#!/usr/bin/env python3
"""Materialize exact identity/depth alignment evidence for one native still."""

from __future__ import annotations

import argparse
import math
import struct
from pathlib import Path

from nr4_common import (
    artifact,
    atomic_json,
    create_absent,
    load_json,
    read_ppm,
    sha256_file,
    validate_frame_package,
    verify_artifacts,
    write_ppm,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--frame-package", required=True, type=Path)
    parser.add_argument("--capture-frame", required=True, type=Path)
    parser.add_argument("--target", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def compact_codes(raw: bytes) -> list[int]:
    if len(raw) % 4:
        raise ValueError("instance RGBA8 byte count is invalid")
    result = []
    for offset in range(0, len(raw), 4):
        if raw[offset + 3] == 0:
            result.append(0)
        else:
            result.append(raw[offset] | raw[offset + 1] << 8 | raw[offset + 2] << 16)
    return result


def main() -> None:
    args = parse_args()
    package_path = args.frame_package.resolve()
    capture_frame_path = args.capture_frame.resolve()
    target_root = args.target.resolve()
    output = create_absent(args.output.resolve(), "alignment output")
    package = load_json(package_path)
    capture = load_json(capture_frame_path)
    target = load_json(target_root / "target-run.json")
    validate_frame_package(package)
    if capture.get("frame_id") != package["frame_id"] or target.get("frame_id") != package["frame_id"]:
        raise ValueError("source, target package, and target render frame identities disagree")
    if target.get("status") != "complete" or target.get("frame_package_sha256") != sha256_file(package_path):
        raise ValueError("target render is incomplete or references a stale package")
    verify_artifacts(target_root, target["artifacts"])
    if capture.get("input_size") != package["input_extent"]:
        raise ValueError("capture and target package input extents disagree")
    if capture.get("paired_target_size") != package["target_extent"]:
        raise ValueError("capture and target package paired-target extents disagree")
    if capture.get("sampling_map") != package["sampling_map"]:
        raise ValueError("capture and target package sampling maps disagree")

    instance = next(channel for channel in capture["channels"] if channel["name"] == "instance")
    capture_root = capture_frame_path.parent.parent
    source_raw_path = capture_root / instance["raw_path"]
    if sha256_file(source_raw_path) != instance["raw_sha256"]:
        raise ValueError("captured instance buffer digest mismatch")
    input_width, input_height = capture["input_size"]
    source_codes = compact_codes(source_raw_path.read_bytes())
    target_width, target_height = package["target_extent"]
    identity_path = target_root / "identity.u32"
    target_bytes = identity_path.read_bytes()
    if len(target_bytes) != target_width * target_height * 4:
        raise ValueError("target identity byte count is invalid")
    target_indices = list(struct.unpack(f"<{target_width * target_height}I", target_bytes))
    index_to_compact = {
        int(record["object_index"]): int(record["compact_rgb24"])
        for record in target["object_index_mapping"]
    }
    if any(index not in index_to_compact and index != 0 for index in target_indices):
        raise ValueError("target identity buffer contains an unmapped object index")
    target_codes = [index_to_compact.get(index, 0) for index in target_indices]

    package_by_code = {int(draw["compact_rgb24"]): draw for draw in package["draws"]}
    source_counts = {code: 0 for code in package_by_code}
    target_counts = {code: 0 for code in package_by_code}
    intersections = {code: 0 for code in package_by_code}
    unions = {code: 0 for code in package_by_code}
    overlay = bytearray(target_width * target_height * 3)
    exact_pixels = 0
    source_fixture_pixels = 0
    target_fixture_pixels = 0
    source_boundary_pixels = 0
    target_boundary_pixels = 0
    for y in range(target_height):
        source_y = y * input_height // target_height
        for x in range(target_width):
            source_x = x * input_width // target_width
            source_code = source_codes[source_y * input_width + source_x]
            target_code = target_codes[y * target_width + x]
            source_known = source_code in package_by_code
            target_known = target_code in package_by_code
            if source_known:
                source_counts[source_code] += 1
                source_fixture_pixels += 1
                if x in (0, target_width - 1) or y in (0, target_height - 1):
                    source_boundary_pixels += 1
            if target_known:
                target_counts[target_code] += 1
                target_fixture_pixels += 1
                if x in (0, target_width - 1) or y in (0, target_height - 1):
                    target_boundary_pixels += 1
            if source_known and target_known and source_code == target_code:
                exact_pixels += 1
            if source_known:
                unions[source_code] += 1
                if target_code == source_code:
                    intersections[source_code] += 1
            if target_known and target_code != source_code:
                unions[target_code] += 1
            offset = (y * target_width + x) * 3
            if source_code == target_code and source_known:
                overlay[offset : offset + 3] = bytes((40, 220, 90))
            elif source_known and not target_known:
                overlay[offset : offset + 3] = bytes((255, 40, 210))
            elif target_known and not source_known:
                overlay[offset : offset + 3] = bytes((20, 210, 255))
            elif source_known and target_known:
                overlay[offset : offset + 3] = bytes((255, 190, 20))
    write_ppm(output / "identity-alignment.ppm", target_width, target_height, overlay)

    records = []
    missing_target = []
    for code, draw in package_by_code.items():
        source_pixels = source_counts[code]
        target_pixels = target_counts[code]
        union = unions[code]
        iou = intersections[code] / union if union else None
        if source_pixels > 0 and target_pixels == 0:
            missing_target.append(draw["stable_key"])
        records.append(
            {
                "label": draw["label"],
                "stable_key": draw["stable_key"],
                "compact_rgb24": code,
                "source_pixels_nearest_target_extent": source_pixels,
                "target_pixels": target_pixels,
                "intersection_pixels": intersections[code],
                "union_pixels": union,
                "iou": iou,
            }
        )
    if missing_target:
        raise ValueError(f"target omitted identities visible in the cheap render: {missing_target}")
    if source_fixture_pixels == 0 or target_fixture_pixels == 0:
        raise ValueError("fixture has no visible source or target identity coverage")
    union_all = sum(
        1
        for source, target_code in zip(
            (
                source_codes[(y * input_height // target_height) * input_width + (x * input_width // target_width)]
                for y in range(target_height)
                for x in range(target_width)
            ),
            target_codes,
            strict=True,
        )
        if source in package_by_code or target_code in package_by_code
    )
    result = {
        "schema": 1,
        "status": "complete",
        "frame_id": package["frame_id"],
        "source_frame": str(capture_frame_path),
        "source_frame_sha256": sha256_file(capture_frame_path),
        "frame_package": str(package_path),
        "frame_package_sha256": sha256_file(package_path),
        "target_manifest": str(target_root / "target-run.json"),
        "target_manifest_sha256": sha256_file(target_root / "target-run.json"),
        "extents": {"source": [input_width, input_height], "target": [target_width, target_height]},
        "method": "nearest-upsampled cheap instance identity versus exact Cycles IndexOB coverage; edge differences measured, not threshold-hidden",
        "aggregate": {
            "source_fixture_pixels": source_fixture_pixels,
            "target_fixture_pixels": target_fixture_pixels,
            "exact_identity_pixels": exact_pixels,
            "union_fixture_pixels": union_all,
            "exact_over_union": exact_pixels / union_all if union_all else None,
            "source_boundary_pixels": source_boundary_pixels,
            "target_boundary_pixels": target_boundary_pixels,
        },
        "identities": records,
        "missing_target_identities": missing_target,
        "artifacts": [artifact(output / "identity-alignment.ppm", output)],
    }
    atomic_json(output / "alignment.json", result)
    print(output / "alignment.json")


if __name__ == "__main__":
    main()
