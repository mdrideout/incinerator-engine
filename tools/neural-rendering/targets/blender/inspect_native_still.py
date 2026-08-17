#!/usr/bin/env python3
"""Read-only integrity inspector for a complete native NR4-C still proof."""

from __future__ import annotations

import argparse
import math
import struct
from pathlib import Path

from nr4_common import (
    CAPTURE_ROOT_SCHEMA,
    TARGET_FRAME_SCHEMA,
    capture_global_control_values,
    load_json,
    read_ndjson,
    sha256_file,
    target_global_control_values,
    validate_frame_package,
    verify_artifacts,
)


def inspect(root: Path) -> dict:
    root = root.resolve()
    if not root.is_absolute():
        raise ValueError("NR4-C still root must be absolute")
    run = load_json(root / "run.json")
    if run.get("schema") != 1 or run.get("status") != "complete" or run.get("phase") != "NR4-C-still":
        raise ValueError("NR4-C still run manifest is incomplete or unexpected")
    tool_sources = run.get("environment", {}).get("tool_sources")
    if not isinstance(tool_sources, list) or not tool_sources:
        raise ValueError("NR4-C still run has no immutable tooling snapshot")
    verify_artifacts(root, tool_sources)
    capture_root = root / run["source"]["capture_root"]
    frame_root = root / run["source"]["target_frame_root"]
    target_root = root / run["target"]["root"]
    alignment_root = root / run["evaluation"]["alignment_root"]
    capture = load_json(capture_root / "capture.json")
    frame_set = load_json(frame_root / "target-frames.json")
    if capture.get("schema") != CAPTURE_ROOT_SCHEMA or capture.get("status") != "complete":
        raise ValueError("source capture is incomplete")
    if frame_set.get("schema") != TARGET_FRAME_SCHEMA or frame_set.get("status") != "complete":
        raise ValueError("target-frame set is incomplete")
    capture_records = read_ndjson(capture_root / capture["frame_index"])
    frame_records = read_ndjson(frame_root / frame_set["frame_index"])
    if len(capture_records) != 1 or len(frame_records) != 1:
        raise ValueError("NR4-C exact-still proof requires one source and one target package")
    package_path = frame_root / frame_records[0]["path"]
    if sha256_file(package_path) != frame_records[0]["sha256"]:
        raise ValueError("target-frame package digest mismatch")
    package = load_json(package_path)
    validate_frame_package(package)
    capture_frame_path = capture_root / capture_records[0]["frame_manifest"]
    capture_frame = load_json(capture_frame_path)
    if len({package["frame_id"], capture_frame["frame_id"], capture_records[0]["frame_id"]}) != 1:
        raise ValueError("source frame and target package identities disagree")
    if package["source"]["content_sha256"] != capture["content_digest"]:
        raise ValueError("source capture and target package content fingerprints disagree")
    if package["source"]["input_schema"] != capture["input_schema"]["fingerprint"]:
        raise ValueError("source capture and target package input schemas disagree")
    if target_global_control_values(package) != capture_global_control_values(
        capture_frame,
        capture_root,
    ):
        raise ValueError("source capture and target package global controls disagree")

    target = load_json(target_root / "target-run.json")
    if target.get("schema") != 1 or target.get("status") != "complete":
        raise ValueError("Cycles target is incomplete")
    if target.get("frame_id") != package["frame_id"]:
        raise ValueError("Cycles target frame identity drifted")
    if target.get("frame_package_sha256") != sha256_file(package_path):
        raise ValueError("Cycles target references a stale frame package")
    if target["cycles"]["use_denoising"] or target["cycles"]["denoising_observed"]:
        raise ValueError("NR4-C target provenance contains learned denoising")
    if target["rights"]["external_art"] or target["rights"]["pretrained_weights"]:
        raise ValueError("NR4-C target provenance is not rights-clean")
    snapshot_by_source = {record["repository_path"]: record for record in tool_sources}
    adapter_sources = target.get("adapter", {}).get("sources")
    if not isinstance(adapter_sources, list) or not adapter_sources:
        raise ValueError("Cycles target does not declare its adapter sources")
    for source in adapter_sources:
        snapshot = snapshot_by_source.get(source.get("repository_path"))
        if snapshot is None or snapshot["sha256"] != source.get("sha256"):
            raise ValueError("Cycles target adapter does not match the immutable tooling snapshot")
    verify_artifacts(target_root, target["artifacts"])
    if (target_root / "target.exr").read_bytes()[:4] != b"\x76\x2f\x31\x01":
        raise ValueError("canonical target is not an OpenEXR file")
    width, height = package["target_extent"]
    pixel_count = width * height
    identities = (target_root / "identity.u32").read_bytes()
    depths = (target_root / "depth.f32").read_bytes()
    normals = (target_root / "normal.f32").read_bytes()
    if len(identities) != pixel_count * 4 or len(depths) != pixel_count * 4 or len(normals) != pixel_count * 12:
        raise ValueError("target evidence byte counts do not match the declared extent")
    mapping = {int(record["object_index"]) for record in target["object_index_mapping"]}
    observed = set(struct.unpack(f"<{pixel_count}I", identities)) - {0}
    if not observed or not observed.issubset(mapping):
        raise ValueError("target identity coverage is absent or unmapped")
    depth_values = struct.unpack(f"<{pixel_count}f", depths)
    normal_values = struct.unpack(f"<{pixel_count * 3}f", normals)
    if any(not math.isfinite(value) for value in depth_values + normal_values):
        raise ValueError("target depth/normal evidence contains non-finite data")

    alignment = load_json(alignment_root / "alignment.json")
    if alignment.get("schema") != 1 or alignment.get("status") != "complete":
        raise ValueError("alignment analysis is incomplete")
    if alignment.get("frame_id") != package["frame_id"] or alignment["missing_target_identities"]:
        raise ValueError("alignment identity coverage is incomplete")
    verify_artifacts(alignment_root, alignment["artifacts"])
    baseline_root = root / run["evaluation"]["baseline_root"]
    baseline = load_json(baseline_root / "baselines.json")
    if sha256_file(baseline_root / "baselines.json") != run["evaluation"]["baseline_manifest_sha256"]:
        raise ValueError("native baseline manifest is stale")
    if baseline.get("input_extent") != [256, 144] or baseline.get("target_extent") != [1280, 720]:
        raise ValueError("native still baseline contains a foreign extent")
    verify_artifacts(baseline_root, baseline["artifacts"])
    report_path = root / run["evaluation"]["report"]
    if sha256_file(report_path) != run["evaluation"]["report_sha256"]:
        raise ValueError("native still review report is stale")
    return {
        "root": str(root),
        "frame_id": package["frame_id"],
        "draw_count": len(package["draws"]),
        "visible_target_identities": len(observed),
        "exact_identity_over_union": alignment["aggregate"]["exact_over_union"],
        "render_ns": target["cycles"]["render_ns"],
        "report": str(report_path),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    result = inspect(args.root)
    print(
        "NR4_TARGET_INSPECT_PASS "
        f"frame={result['frame_id']} draws={result['draw_count']} "
        f"visible_target_identities={result['visible_target_identities']} "
        f"exact_identity_over_union={result['exact_identity_over_union']:.6f} "
        f"render_ms={result['render_ns'] / 1_000_000:.3f} report={result['report']}"
    )


if __name__ == "__main__":
    main()
