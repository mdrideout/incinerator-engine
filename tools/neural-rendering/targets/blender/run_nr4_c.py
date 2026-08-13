#!/usr/bin/env python3
"""Execute one immutable native-resolution NR4 paired-sequence proof."""

from __future__ import annotations

import argparse
import os
import platform
import sys
from pathlib import Path

from nr4_common import artifact, atomic_json, create_absent, load_json, read_ndjson, sha256_file
from run_nr4_c_still import (
    git_record,
    require_file,
    run_command,
    snapshot_tool_sources,
    tree_bytes,
)
from sequence_contract import FRAME_COUNT, FRAME_STRIDE, FRAMES, SEGMENTS, START_FRAME


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--validation", required=True, type=Path)
    parser.add_argument("--content-root", required=True, type=Path)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--blender", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--phase", choices=("NR4-C", "NR4-D"), default="NR4-C")
    parser.add_argument(
        "--cohort",
        choices=("overfit", "train", "validation", "test", "stress"),
        default="overfit",
    )
    parser.add_argument(
        "--sequence",
        default="nr4-native-urban-corner-causal-motion-0001",
    )
    parser.add_argument("--camera-path", default="nr4-sequence")
    args = parser.parse_args()
    validation = require_file(args.validation, "installed validation binary")
    blender = require_file(args.blender, "pinned Blender binary")
    content_root = args.content_root.resolve()
    repo = args.repo.resolve()
    if not content_root.is_dir() or not repo.is_dir():
        raise FileNotFoundError("content root and repository root must exist")
    output = create_absent(args.output.resolve(), f"{args.phase} run root")
    causal_proof = args.phase == "NR4-C"
    if causal_proof and (
        args.cohort != "overfit"
        or args.sequence != "nr4-native-urban-corner-causal-motion-0001"
        or args.camera_path != "nr4-sequence"
    ):
        raise ValueError("NR4-C causal proof identity cannot be changed")
    source = output / "source"
    targets = output / "targets"
    evaluation = output / "evaluation"
    alignment_root = evaluation / "alignment"
    environment_root = output / "environment"
    for path in (source, targets, evaluation, alignment_root, environment_root):
        path.mkdir()
    capture_root = source / "capture"
    target_frame_root = source / "target-frames"
    tools = repo / "tools" / "neural-rendering" / "targets" / "blender"
    environment = tools / "environment.json"
    tool_sources = snapshot_tool_sources(tools, environment_root, output, repo)
    run_manifest = output / "run.json"
    atomic_json(
        run_manifest,
        {
            "schema": 1,
            "status": "partial",
            "phase": args.phase,
            "purpose": (
                "native 160x90 inputs paired with direct native 640x360 Cycles "
                + ("targets across six causal segments" if causal_proof else "corpus targets")
            ),
            "cohort": args.cohort,
            "sequence": args.sequence,
            "camera_path": args.camera_path,
            "repository": git_record(repo),
            "tool_sources": tool_sources,
            "platform": platform.platform(),
            "python": sys.version,
        },
    )

    engine_env = os.environ.copy()
    engine_env.update(
        {
            "INCINERATOR_CONTENT_ROOT": str(content_root),
            "INCINERATOR_NR_CAPTURE_ROOT": str(capture_root),
            "INCINERATOR_NR_TARGET_FRAME_ROOT": str(target_frame_root),
            "INCINERATOR_NR_CAPTURE_START_FRAME": str(START_FRAME),
            "INCINERATOR_NR_CAPTURE_STRIDE": str(FRAME_STRIDE),
            "INCINERATOR_NR_CAPTURE_FRAMES": str(FRAME_COUNT),
            "INCINERATOR_NR_COHORT": args.cohort,
            "INCINERATOR_NR_SEQUENCE": args.sequence,
            "INCINERATOR_NR_CAMERA_PATH": args.camera_path,
        }
    )
    run_command(
        [str(validation), "--nr0-evaluation-smoke", "--frames=400", "--virtual-render-hz=240"],
        environment_root / "engine.log",
        cwd=repo,
        env=engine_env,
    )
    run_command(
        [sys.executable, str(repo / "tools/neural-rendering/inspect_nr0_capture.py"), str(capture_root)],
        environment_root / "capture-inspect.log",
        cwd=repo,
    )
    frame_records = read_ndjson(target_frame_root / "frames.ndjson")
    capture_records = read_ndjson(capture_root / "frames.ndjson")
    if len(frame_records) != FRAME_COUNT or len(capture_records) != FRAME_COUNT:
        raise ValueError(f"{args.phase} engine execution did not produce the exact paired frame count")
    if [record["presentation_frame"] for record in frame_records] != list(FRAMES):
        raise ValueError(f"{args.phase} target-frame schedule drifted")
    if [record["presentation_frame"] for record in capture_records] != list(FRAMES):
        raise ValueError(f"{args.phase} capture schedule drifted")

    causal_path = evaluation / "causal-audit.json"
    if causal_proof:
        run_command(
            [
                sys.executable,
                str(tools / "audit_sequence.py"),
                "--target-frame-root",
                str(target_frame_root),
                "--output",
                str(causal_path),
            ],
            environment_root / "causal-audit.log",
            cwd=repo,
        )

    frame_results = []
    total_render_ns = 0
    maximum_process_peak_rss_bytes = 0
    for index, (frame_record, capture_record) in enumerate(
        zip(frame_records, capture_records, strict=True)
    ):
        if frame_record["presentation_frame"] != capture_record["presentation_frame"]:
            raise ValueError(f"{args.phase} capture and target selection drifted")
        package_path = target_frame_root / frame_record["path"]
        capture_frame_path = capture_root / capture_record["frame_manifest"]
        frame_number = frame_record["presentation_frame"]
        target = targets / f"frame-{frame_number:08d}"
        alignment = alignment_root / f"frame-{frame_number:08d}"
        run_command(
            [
                str(blender),
                "--background",
                "--factory-startup",
                "--python",
                str(tools / "render_target.py"),
                "--",
                "--frame-package",
                str(package_path),
                "--environment",
                str(environment),
                "--output",
                str(target),
            ],
            environment_root / f"blender-{frame_number:08d}.log",
            cwd=repo,
        )
        baseline = evaluation / "baselines" / f"frame-{frame_number:08d}"
        run_command(
            [
                sys.executable,
                str(tools / "native_baselines.py"),
                "--capture-frame",
                str(capture_frame_path),
                "--target",
                str(target),
                "--output",
                str(baseline),
            ],
            environment_root / f"baselines-{frame_number:08d}.log",
            cwd=repo,
        )
        run_command(
            [
                sys.executable,
                str(tools / "analyze_target.py"),
                "--frame-package",
                str(package_path),
                "--capture-frame",
                str(capture_frame_path),
                "--target",
                str(target),
                "--output",
                str(alignment),
            ],
            environment_root / f"alignment-{frame_number:08d}.log",
            cwd=repo,
        )
        package = load_json(package_path)
        target_manifest = load_json(target / "target-run.json")
        alignment_manifest = load_json(alignment / "alignment.json")
        total_render_ns += int(target_manifest["cycles"]["render_ns"])
        maximum_process_peak_rss_bytes = max(
            maximum_process_peak_rss_bytes,
            int(target_manifest["memory"]["process_peak_rss_bytes"]),
        )
        frame_results.append(
            {
                "index": index,
                "frame_id": package["frame_id"],
                "presentation_frame": frame_number,
                "segment": package["sequence_event"]["segment"],
                "segment_index": package["sequence_event"]["segment_index"],
                "sample_index": package["sequence_event"]["sample_index"],
                "progress": package["sequence_event"]["progress"],
                "capture_frame": str(capture_frame_path.relative_to(output)),
                "capture_frame_sha256": sha256_file(capture_frame_path),
                "frame_package": str(package_path.relative_to(output)),
                "frame_package_sha256": sha256_file(package_path),
                "target_root": str(target.relative_to(output)),
                "target_manifest_sha256": sha256_file(target / "target-run.json"),
                "alignment_root": str(alignment.relative_to(output)),
                "alignment_manifest_sha256": sha256_file(alignment / "alignment.json"),
                "baseline_root": str(baseline.relative_to(output)),
                "baseline_manifest_sha256": sha256_file(baseline / "baselines.json"),
                "render_ns": target_manifest["cycles"]["render_ns"],
                "process_peak_rss_bytes": target_manifest["memory"]["process_peak_rss_bytes"],
                "exact_identity_over_union": alignment_manifest["aggregate"]["exact_over_union"],
                "source_boundary_pixels": alignment_manifest["aggregate"]["source_boundary_pixels"],
                "target_boundary_pixels": alignment_manifest["aggregate"]["target_boundary_pixels"],
            }
        )

    sequence_path = evaluation / "sequence.json"
    sequence_manifest = {
            "schema": 1,
            "status": "complete",
            "phase": args.phase,
            "cohort": args.cohort,
            "sequence": args.sequence,
            "camera_path": args.camera_path,
            "segments": list(SEGMENTS),
            "selection": {
                "start_frame": START_FRAME,
                "frame_stride": FRAME_STRIDE,
                "frame_count": FRAME_COUNT,
            },
            "total_render_ns": total_render_ns,
            "frames": frame_results,
        }
    if causal_proof:
        sequence_manifest["causal_audit"] = str(causal_path.relative_to(output))
        sequence_manifest["causal_audit_sha256"] = sha256_file(causal_path)
    atomic_json(sequence_path, sequence_manifest)
    report_root = evaluation / "reports"
    run_command(
        [
            sys.executable,
            str(tools / "sequence_report.py"),
            "--run-root",
            str(output),
            "--sequence",
            str(sequence_path),
            "--output",
            str(report_root),
        ],
        environment_root / "sequence-report.log",
        cwd=repo,
    )
    report_manifest = report_root / "report.json"
    atomic_json(
        run_manifest,
        {
            "schema": 1,
            "status": "complete",
            "phase": args.phase,
            "review": (
                "pending_human_sequence_target_and_alignment_review"
                if causal_proof
                else "not_a_phase_acceptance_artifact"
            ),
            "cohort": args.cohort,
            "sequence_id": args.sequence,
            "camera_path": args.camera_path,
            "purpose": "native 160x90 inputs paired only with direct native 640x360 Cycles targets",
            "working_resolution": {
                "input_extent": [160, 90],
                "target_extent": [640, 360],
                "linear_scale": "x=4:1,y=4:1",
                "foreign_extent_policy": "rejected",
            },
            "repository": git_record(repo),
            "platform": platform.platform(),
            "python": sys.version,
            "source": {
                "capture_root": str(capture_root.relative_to(output)),
                "capture_manifest_sha256": sha256_file(capture_root / "capture.json"),
                "target_frame_root": str(target_frame_root.relative_to(output)),
                "target_frame_manifest_sha256": sha256_file(target_frame_root / "target-frames.json"),
            },
            "sequence": {
                "manifest": str(sequence_path.relative_to(output)),
                "manifest_sha256": sha256_file(sequence_path),
                "frame_count": FRAME_COUNT,
                "segments": list(SEGMENTS),
                "total_render_ns": total_render_ns,
                "maximum_process_peak_rss_bytes": maximum_process_peak_rss_bytes,
            },
            "evaluation": {
                "causal_audit": str(causal_path.relative_to(output)) if causal_proof else None,
                "causal_audit_sha256": sha256_file(causal_path) if causal_proof else None,
                "report_root": str(report_root.relative_to(output)),
                "report_manifest_sha256": sha256_file(report_manifest),
                "overview": str((report_root / "direct-160x90-to-640x360-sequence-review.png").relative_to(output)),
                "overview_sha256": sha256_file(report_root / "direct-160x90-to-640x360-sequence-review.png"),
            },
            "evidence_bytes": {
                "native_input_capture": tree_bytes(capture_root),
                "target_frame_packages": tree_bytes(target_frame_root),
                "direct_targets": tree_bytes(targets),
                "alignment_and_baselines_and_reports": tree_bytes(evaluation),
            },
            "environment": {
                "configuration": str(environment.relative_to(repo)),
                "configuration_sha256": sha256_file(environment),
                "blender_binary": str(blender),
                "validation_binary": str(validation),
                "content_root": str(content_root),
                "tool_sources": tool_sources,
                "logs": [artifact(path, output) for path in sorted(environment_root.glob("*.log"))],
            },
        },
    )
    run_command(
        [
            sys.executable,
            str(tools / "inspect_sequence.py"),
            str(output),
            "--phase",
            args.phase,
        ],
        environment_root / "final-inspect.log",
        cwd=repo,
    )
    print(output)


if __name__ == "__main__":
    main()
