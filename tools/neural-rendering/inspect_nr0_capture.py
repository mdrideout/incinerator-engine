#!/usr/bin/env python3
"""Validate NR0-B capture integrity, split ownership, and optional recapture identity."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


CHANNELS = (
    "appearance",
    "linear-depth",
    "world-normal",
    "motion",
    "semantic",
    "instance",
)
RAW_CHANNEL_BYTES = 400 * 225 * 4
RAW_TARGET_BYTES = 1600 * 900 * 4
RAW_BYTES_PER_FRAME = len(CHANNELS) * RAW_CHANNEL_BYTES + RAW_TARGET_BYTES
SEMANTIC_PALETTE = {
    ("background", "whole"): (0, 0, 0),
    ("environment", "whole"): (128, 128, 128),
    ("district", "whole"): (64, 160, 255),
    ("crate", "whole"): (196, 96, 32),
    ("carryable", "whole"): (255, 220, 32),
    ("vehicle", "whole"): (32, 224, 224),
    ("vehicle", "vehicle_chassis"): (32, 224, 224),
    ("vehicle", "vehicle_wheel_front_left"): (32, 96, 255),
    ("vehicle", "vehicle_wheel_front_right"): (64, 128, 255),
    ("vehicle", "vehicle_wheel_rear_left"): (96, 64, 224),
    ("vehicle", "vehicle_wheel_rear_right"): (128, 64, 224),
    ("character", "whole"): (64, 224, 96),
    ("npc", "whole"): (255, 64, 64),
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def ppm_extent(path: Path) -> tuple[int, int]:
    with path.open("rb") as stream:
        if stream.readline().strip() != b"P6":
            raise ValueError(f"unsupported debug image: {path}")
        dimensions = stream.readline().split()
        if len(dimensions) != 2 or stream.readline().strip() != b"255":
            raise ValueError(f"malformed debug image: {path}")
    return int(dimensions[0]), int(dimensions[1])


def validate_pixels(frame_id: str, raw_by_name: dict[str, bytes], identities: list[dict]) -> dict:
    masks = {name: data[3::4] for name, data in raw_by_name.items()}
    coverage = masks[CHANNELS[0]]
    if any(alpha not in (0, 255) for alpha in coverage):
        raise ValueError(f"non-binary appearance coverage in {frame_id}")
    for name, mask in masks.items():
        if mask != coverage:
            raise ValueError(f"coverage mask drift for {name} in {frame_id}")

    depth = raw_by_name["linear-depth"]
    if any(depth[offset] != depth[offset + 1] or depth[offset] != depth[offset + 2]
           for offset in range(0, len(depth), 4)):
        raise ValueError(f"linear depth is not grayscale in {frame_id}")

    normals = raw_by_name["world-normal"]
    for offset, alpha in zip(range(0, len(normals), 4), coverage):
        if alpha == 0:
            continue
        vector = tuple(normals[offset + component] / 127.5 - 1.0 for component in range(3))
        length_squared = sum(component * component for component in vector)
        if not 0.94 <= length_squared <= 1.06:
            raise ValueError(f"non-unit world normal in {frame_id} at pixel {offset // 4}")

    motion = raw_by_name["motion"]
    if any(motion[offset + 2] not in (0, 255)
           for offset in range(0, len(motion), 4)):
        raise ValueError(f"non-binary motion history in {frame_id}")

    semantic = raw_by_name["semantic"]
    allowed_semantics = {(0, 0, 0)}
    for identity in identities:
        key = (identity["semantic"], identity["part"])
        try:
            allowed_semantics.add(SEMANTIC_PALETTE[key])
        except KeyError as error:
            raise ValueError(f"unknown semantic ABI value {key} in {frame_id}") from error
    visible_semantics = {
        tuple(semantic[offset : offset + 3])
        for offset in range(0, len(semantic), 4)
        if semantic[offset + 3] != 0
    }
    if not visible_semantics <= allowed_semantics:
        raise ValueError(f"undeclared semantic pixel in {frame_id}")

    instances = raw_by_name["instance"]
    allowed_instances = {identity["compact_rgb24"] for identity in identities}
    visible_instances = {
        instances[offset] | instances[offset + 1] << 8 | instances[offset + 2] << 16
        for offset in range(0, len(instances), 4)
        if instances[offset + 3] != 0
    }
    if 0 in visible_instances or not visible_instances <= allowed_instances:
        raise ValueError(f"unmapped instance pixel in {frame_id}")

    return {
        "coverage_pixels": sum(alpha != 0 for alpha in coverage),
        "visible_semantic_colors": len(visible_semantics),
        "visible_instance_ids": len(visible_instances),
        "motion_history_pixels": sum(
            motion[offset + 2] == 255 for offset in range(0, len(motion), 4)
        ),
    }


def load_capture(root: Path) -> dict:
    if not root.is_absolute():
        raise ValueError(f"capture root must be absolute: {root}")
    capture = json.loads((root / "capture.json").read_text())
    if capture["schema"] != 2:
        raise ValueError(f"unsupported capture schema in {root}")
    if capture["status"] != "complete":
        raise ValueError(f"capture is not complete: {root}")
    if capture["capture_failures"] != 0:
        raise ValueError(f"capture recorded failures: {root}")
    index_lines = [line for line in (root / "frames.ndjson").read_text().splitlines() if line]
    summaries = [json.loads(line) for line in index_lines]
    if len(summaries) != capture["recorded_frames"]:
        raise ValueError(f"index/manifest frame count mismatch in {root}")
    if capture["recorded_frames"] != capture["selection"]["requested_frames"]:
        raise ValueError(f"capture did not satisfy its requested frame count: {root}")
    if capture["raw_bytes_per_frame"] != RAW_BYTES_PER_FRAME:
        raise ValueError(f"unexpected raw frame byte count in {root}")

    frame_ids: set[str] = set()
    stable_identity: dict[str, dict] = {}
    frames: list[dict] = []
    frame_stats: list[dict] = []
    for summary in summaries:
        if summary["frame_id"] in frame_ids:
            raise ValueError(f"duplicate frame ID: {summary['frame_id']}")
        frame_ids.add(summary["frame_id"])
        frame = json.loads((root / summary["frame_manifest"]).read_text())
        if frame["frame_id"] != summary["frame_id"]:
            raise ValueError(f"frame identity mismatch: {summary['frame_id']}")
        if frame["cohort"] != capture["cohort"] or frame["sequence"] != capture["sequence"]:
            raise ValueError(f"split ownership drift in {summary['frame_id']}")
        if frame["input_schema"] != capture["input_schema"]:
            raise ValueError(f"input schema drift in {summary['frame_id']}")
        if frame["shader_fingerprint"] != capture["shader_fingerprint"] or frame["shader_sha256"] != capture["shader_sha256"]:
            raise ValueError(f"shader provenance drift in {summary['frame_id']}")
        if tuple(frame["cheap_size"]) != (400, 225) or tuple(frame["target_size"]) != (1600, 900):
            raise ValueError(f"unexpected capture extent in {summary['frame_id']}")
        if any(value <= 0 for value in frame["source_scene_size"]):
            raise ValueError(f"invalid source scene extent in {summary['frame_id']}")
        by_name = {channel["name"]: channel for channel in frame["channels"]}
        if tuple(by_name) != CHANNELS:
            raise ValueError(f"channel ABI/order mismatch in {summary['frame_id']}")
        raw_by_name: dict[str, bytes] = {}
        for name in CHANNELS:
            channel = by_name[name]
            raw = root / channel["raw_path"]
            debug = root / channel["debug_path"]
            if raw.stat().st_size != RAW_CHANNEL_BYTES:
                raise ValueError(f"bad raw byte count: {raw}")
            if channel["raw_bytes"] != RAW_CHANNEL_BYTES:
                raise ValueError(f"bad declared raw byte count: {raw}")
            if sha256(raw) != channel["raw_sha256"]:
                raise ValueError(f"raw digest mismatch: {raw}")
            raw_by_name[name] = raw.read_bytes()
            if sha256(debug) != channel["debug_sha256"]:
                raise ValueError(f"debug digest mismatch: {debug}")
            if ppm_extent(debug) != (400, 225):
                raise ValueError(f"bad debug extent: {debug}")
        target = frame["target"]
        if target["format"] != "rgba8" or target["source_gpu_format"] not in {"rgba8", "bgra8"}:
            raise ValueError(f"noncanonical target format in {summary['frame_id']}")
        target_raw = root / target["raw_path"]
        if target_raw.stat().st_size != RAW_TARGET_BYTES:
            raise ValueError(f"bad target byte count: {target_raw}")
        if target["raw_bytes"] != RAW_TARGET_BYTES:
            raise ValueError(f"bad declared target byte count in {summary['frame_id']}")
        if sha256(target_raw) != target["raw_sha256"]:
            raise ValueError(f"target raw digest mismatch: {target_raw}")
        if sha256(root / target["debug_path"]) != target["debug_sha256"]:
            raise ValueError(f"target debug digest mismatch in {summary['frame_id']}")
        if ppm_extent(root / target["debug_path"]) != (1600, 900):
            raise ValueError(f"bad target debug extent in {summary['frame_id']}")

        compact: dict[int, str] = {}
        for identity in frame["identities"]:
            code = identity["compact_rgb24"]
            stable = identity["stable_key"]
            if code == 0:
                raise ValueError(f"background instance ID used by draw in {summary['frame_id']}")
            if code in compact and compact[code] != stable:
                raise ValueError(f"compact identity collision in {summary['frame_id']}")
            compact[code] = stable
            description = {
                key: value
                for key, value in identity.items()
                if key not in {"compact_rgb24"}
            }
            previous = stable_identity.setdefault(stable, description)
            if previous != description:
                raise ValueError(f"stable identity mapping drift for {stable}")
        stats = validate_pixels(frame["frame_id"], raw_by_name, frame["identities"])
        stats["frame_id"] = frame["frame_id"]
        frame_stats.append(stats)
        frames.append(frame)
    return {"root": root, "capture": capture, "frames": frames, "frame_stats": frame_stats}


def logical_signature(loaded: dict) -> list[dict]:
    return [
        {
            "authority_tick": frame["authority_tick"],
            "presentation_frame": frame["presentation_frame"],
            "interpolation_alpha": frame["interpolation_alpha"],
            "camera": frame["camera"],
            "effects": frame["effects"],
            "identities": frame["identities"],
            "channels": [
                {"name": item["name"], "raw_sha256": item["raw_sha256"]}
                for item in frame["channels"]
            ],
            "target_sha256": frame["target"]["raw_sha256"],
        }
        for frame in loaded["frames"]
    ]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("roots", nargs="+", type=Path)
    parser.add_argument(
        "--require-identical",
        action="store_true",
        help="require every supplied capture to have the same logical and byte signature",
    )
    args = parser.parse_args()
    loaded = [load_capture(root.resolve()) for root in args.roots]
    sequence_cohorts: dict[str, str] = {}
    for item in loaded:
        capture = item["capture"]
        previous = sequence_cohorts.setdefault(capture["sequence"], capture["cohort"])
        if previous != capture["cohort"]:
            raise ValueError(
                f"sequence {capture['sequence']} leaks across {previous}/{capture['cohort']}"
            )
    if args.require_identical:
        expected = logical_signature(loaded[0])
        for item in loaded[1:]:
            if logical_signature(item) != expected:
                raise ValueError(
                    f"capture differs from deterministic baseline: {item['root']}"
                )
    print(
        json.dumps(
            {
                "status": "pass",
                "captures": len(loaded),
                "frames": sum(len(item["frames"]) for item in loaded),
                "sequences": sequence_cohorts,
                "identical": args.require_identical,
                "schema_fingerprint": loaded[0]["capture"]["input_schema"]["fingerprint"],
                "capture_summaries": [
                    {
                        "root": str(item["root"]),
                        "recorded_frames": len(item["frames"]),
                        "frame_stats": item["frame_stats"],
                    }
                    for item in loaded
                ],
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
