#!/usr/bin/env python3
"""Read-only integrity inspector for one complete native NR4 paired sequence."""

from __future__ import annotations

import argparse
import math
import struct
from array import array
from pathlib import Path

from nr4_common import (
    CAPTURE_ROOT_SCHEMA,
    INPUT_EXTENT,
    TARGET_EXTENT,
    TARGET_FRAME_SCHEMA,
    capture_global_control_values,
    load_json,
    read_ndjson,
    sha256_file,
    target_global_control_values,
    validate_frame_package,
    verify_artifacts,
)
from sequence_contract import FRAME_COUNT, FRAMES, SEGMENTS, audit_packages, expected_event


def inspect(root: Path, expected_phase: str = "NR4-C") -> dict:
    root = root.resolve()
    if not root.is_absolute():
        raise ValueError("NR4 sequence root must be absolute")
    run = load_json(root / "run.json")
    if (
        run.get("schema") != 1
        or run.get("status") != "complete"
        or run.get("phase") != expected_phase
    ):
        raise ValueError("NR4 run manifest is incomplete or unexpected")
    causal_proof = expected_phase == "NR4-C"
    if expected_phase not in {"NR4-C", "NR4-D"}:
        raise ValueError("unsupported NR4 phase")
    tool_sources = run.get("environment", {}).get("tool_sources")
    if not isinstance(tool_sources, list) or not tool_sources:
        raise ValueError("NR4 run has no immutable tooling snapshot")
    verify_artifacts(root, tool_sources)
    verify_artifacts(root, run["environment"]["logs"])
    snapshot_by_source = {record["repository_path"]: record for record in tool_sources}

    capture_root = root / run["source"]["capture_root"]
    frame_root = root / run["source"]["target_frame_root"]
    capture = load_json(capture_root / "capture.json")
    frame_set = load_json(frame_root / "target-frames.json")
    if capture.get("schema") != CAPTURE_ROOT_SCHEMA or capture.get("status") != "complete":
        raise ValueError("NR4 source capture is incomplete")
    if frame_set.get("schema") != TARGET_FRAME_SCHEMA or frame_set.get("status") != "complete":
        raise ValueError("NR4 target-frame set is incomplete")
    capture_records = read_ndjson(capture_root / capture["frame_index"])
    frame_records = read_ndjson(frame_root / frame_set["frame_index"])
    if len(capture_records) != FRAME_COUNT or len(frame_records) != FRAME_COUNT:
        raise ValueError("NR4 source roots do not contain the exact frame count")
    if [record["presentation_frame"] for record in frame_records] != list(FRAMES):
        raise ValueError("NR4 target-frame schedule changed")
    if [record["presentation_frame"] for record in capture_records] != list(FRAMES):
        raise ValueError("NR4 capture schedule changed")

    sequence_path = root / run["sequence"]["manifest"]
    if sha256_file(sequence_path) != run["sequence"]["manifest_sha256"]:
        raise ValueError("NR4 sequence manifest digest changed")
    sequence = load_json(sequence_path)
    if (
        sequence.get("schema") != 1
        or sequence.get("status") != "complete"
        or sequence.get("phase") != expected_phase
        or sequence.get("segments") != list(SEGMENTS)
        or len(sequence.get("frames", [])) != FRAME_COUNT
    ):
        raise ValueError("NR4 sequence manifest is incomplete or unexpected")
    if sequence.get("sequence") != capture.get("sequence") or sequence.get("camera_path") != capture.get("camera_path"):
        raise ValueError("NR4 sequence identity disagrees with its capture")
    causal = None
    if causal_proof:
        causal_path = root / sequence["causal_audit"]
        if sha256_file(causal_path) != sequence["causal_audit_sha256"]:
            raise ValueError("NR4-C causal audit digest changed")
        causal = load_json(causal_path)
        if causal.get("status") != "complete" or causal.get("frame_schedule") != list(FRAMES):
            raise ValueError("NR4-C causal audit is incomplete")
    elif sequence.get("cohort") != capture.get("cohort"):
        raise ValueError("NR4-D sequence cohort disagrees with its capture")

    packages = []
    minimum_alignment = 1.0
    maximum_alignment = 0.0
    total_render_ns = 0
    visible_counts = []
    for index, (frame, frame_record, capture_record) in enumerate(
        zip(sequence["frames"], frame_records, capture_records, strict=True)
    ):
        package_path = root / frame["frame_package"]
        capture_frame_path = root / frame["capture_frame"]
        target_root = root / frame["target_root"]
        alignment_root = root / frame["alignment_root"]
        if sha256_file(package_path) != frame["frame_package_sha256"]:
            raise ValueError("NR4 frame package digest changed")
        if sha256_file(package_path) != frame_record["sha256"]:
            raise ValueError("NR4 frame index references a stale package")
        if sha256_file(capture_frame_path) != frame["capture_frame_sha256"]:
            raise ValueError("NR4 capture frame digest changed")
        package = load_json(package_path)
        validate_frame_package(package)
        packages.append(package)
        capture_frame = load_json(capture_frame_path)
        if capture_frame.get("input_size") != INPUT_EXTENT:
            raise ValueError("NR4 frame contains a foreign input extent")
        if capture_frame.get("paired_target_size") != TARGET_EXTENT:
            raise ValueError("NR4 frame contains a foreign paired-target extent")
        if len({package["frame_id"], capture_frame["frame_id"], frame["frame_id"]}) != 1:
            raise ValueError("NR4 source and target frame identities disagree")
        if package["sequence"] != sequence["sequence"] or package["camera_path"] != sequence["camera_path"]:
            raise ValueError("NR4 frame package belongs to another sequence")
        if causal_proof:
            expected = expected_event(index)
            if any(package["sequence_event"][name] != value for name, value in expected.items() if name != "progress"):
                raise ValueError("NR4-C frame event schedule changed")
        if package["source"]["content_sha256"] != capture["content_digest"]:
            raise ValueError("NR4 package and capture content fingerprints disagree")
        if package["source"]["input_schema"] != capture["input_schema"]["fingerprint"]:
            raise ValueError("NR4 package and capture input schemas disagree")
        if target_global_control_values(package) != capture_global_control_values(
            capture_frame,
            capture_root,
        ):
            raise ValueError("NR4 package and capture global controls disagree")

        target = load_json(target_root / "target-run.json")
        if sha256_file(target_root / "target-run.json") != frame["target_manifest_sha256"]:
            raise ValueError("NR4 target manifest digest changed")
        if target.get("status") != "complete" or target.get("frame_id") != package["frame_id"]:
            raise ValueError("NR4 target is incomplete or belongs to another frame")
        if target.get("frame_package_sha256") != sha256_file(package_path):
            raise ValueError("NR4 target references a stale frame package")
        if target["sequence_event"] != package["sequence_event"]:
            raise ValueError("NR4 target dropped sequence metadata")
        if target["cycles"]["use_denoising"] or target["cycles"]["denoising_observed"]:
            raise ValueError("NR4 target provenance contains learned denoising")
        if target["rights"]["external_art"] or target["rights"]["pretrained_weights"]:
            raise ValueError("NR4 target provenance is not rights-clean")
        for source in target.get("adapter", {}).get("sources", []):
            snapshot = snapshot_by_source.get(source.get("repository_path"))
            if snapshot is None or snapshot["sha256"] != source.get("sha256"):
                raise ValueError("NR4 target adapter differs from the immutable tool snapshot")
        verify_artifacts(target_root, target["artifacts"])
        if (target_root / "target.exr").read_bytes()[:4] != b"\x76\x2f\x31\x01":
            raise ValueError("NR4 canonical target is not OpenEXR")
        width, height = package["target_extent"]
        pixel_count = width * height
        identities = (target_root / "identity.u32").read_bytes()
        depths = (target_root / "depth.f32").read_bytes()
        normals = (target_root / "normal.f32").read_bytes()
        if len(identities) != pixel_count * 4 or len(depths) != pixel_count * 4 or len(normals) != pixel_count * 12:
            raise ValueError("NR4 target evidence byte counts disagree with the extent")
        mapping = {int(record["object_index"]) for record in target["object_index_mapping"]}
        observed = set(struct.unpack(f"<{pixel_count}I", identities)) - {0}
        if not observed or not observed.issubset(mapping):
            raise ValueError("NR4 target identity coverage is absent or unmapped")
        for path in (target_root / "depth.f32", target_root / "normal.f32"):
            values = array("f")
            values.frombytes(path.read_bytes())
            if any(not math.isfinite(value) for value in values):
                raise ValueError("NR4 target depth/normal evidence contains non-finite values")
        visible_counts.append(len(observed))

        alignment = load_json(alignment_root / "alignment.json")
        if sha256_file(alignment_root / "alignment.json") != frame["alignment_manifest_sha256"]:
            raise ValueError("NR4 alignment manifest digest changed")
        if alignment.get("status") != "complete" or alignment.get("frame_id") != package["frame_id"]:
            raise ValueError("NR4 alignment is incomplete or stale")
        if alignment["missing_target_identities"]:
            raise ValueError("NR4 target omitted an identity visible in the cheap source")
        verify_artifacts(alignment_root, alignment["artifacts"])
        baseline_root = root / frame["baseline_root"]
        baseline = load_json(baseline_root / "baselines.json")
        if sha256_file(baseline_root / "baselines.json") != frame["baseline_manifest_sha256"]:
            raise ValueError("NR4 baseline manifest digest changed")
        if (
            baseline.get("status") != "complete"
            or baseline.get("input_extent") != INPUT_EXTENT
            or baseline.get("target_extent") != TARGET_EXTENT
        ):
            raise ValueError("NR4 baseline evidence contains a foreign extent")
        verify_artifacts(baseline_root, baseline["artifacts"])
        value = float(alignment["aggregate"]["exact_over_union"])
        minimum_alignment = min(minimum_alignment, value)
        maximum_alignment = max(maximum_alignment, value)
        total_render_ns += int(target["cycles"]["render_ns"])

    if causal_proof:
        recomputed_audit = audit_packages(packages)
        if recomputed_audit["segments"] != causal["segments"]:
            raise ValueError("NR4-C causal audit no longer matches its frame packages")
    if total_render_ns != sequence["total_render_ns"] or total_render_ns != run["sequence"]["total_render_ns"]:
        raise ValueError("NR4 total render timing record drifted")

    report_root = root / run["evaluation"]["report_root"]
    report = load_json(report_root / "report.json")
    if sha256_file(report_root / "report.json") != run["evaluation"]["report_manifest_sha256"]:
        raise ValueError("NR4 report manifest digest changed")
    if report.get("status") != "complete" or report.get("frame_count") != FRAME_COUNT:
        raise ValueError("NR4 synchronized report is incomplete")
    verify_artifacts(report_root, report["artifacts"])
    overview = root / run["evaluation"]["overview"]
    if sha256_file(overview) != run["evaluation"]["overview_sha256"]:
        raise ValueError("NR4-C overview digest changed")
    return {
        "root": str(root),
        "phase": expected_phase,
        "cohort": capture["cohort"],
        "sequence": capture["sequence"],
        "frame_count": FRAME_COUNT,
        "segments": len(SEGMENTS),
        "minimum_exact_identity_over_union": minimum_alignment,
        "maximum_exact_identity_over_union": maximum_alignment,
        "visible_identity_counts": visible_counts,
        "total_render_ns": total_render_ns,
        "overview": str(overview),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--phase", choices=("NR4-C", "NR4-D"), default="NR4-C")
    args = parser.parse_args()
    result = inspect(args.root, args.phase)
    print(
        "NR4_SEQUENCE_INSPECT_PASS "
        f"phase={result['phase']} cohort={result['cohort']} "
        f"sequence={result['sequence']} frames={result['frame_count']} segments={result['segments']} "
        f"identity_iou={result['minimum_exact_identity_over_union']:.6f}.."
        f"{result['maximum_exact_identity_over_union']:.6f} "
        f"render_s={result['total_render_ns'] / 1_000_000_000:.3f} "
        f"overview={result['overview']}"
    )


if __name__ == "__main__":
    main()
