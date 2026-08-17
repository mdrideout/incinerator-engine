#!/usr/bin/env python3
"""Execute one immutable native-resolution NR4-C still proof."""

from __future__ import annotations

import argparse
import hashlib
import os
import platform
import subprocess
import sys
import time
from pathlib import Path

from nr4_common import (
    artifact,
    atomic_json,
    create_absent,
    load_json,
    read_ndjson,
    sha256_file,
)


def require_file(path: Path, label: str) -> Path:
    path = path.resolve()
    if not path.is_file():
        raise FileNotFoundError(f"{label} does not exist: {path}")
    return path


def run_command(command: list[str], log: Path, *, cwd: Path, env: dict[str, str] | None = None) -> None:
    started = time.time_ns()
    result = subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True)
    log.write_text(
        f"COMMAND: {command!r}\nSTARTED_UNIX_NS: {started}\nRETURN_CODE: {result.returncode}\n\nSTDOUT\n{result.stdout}\nSTDERR\n{result.stderr}",
        encoding="utf-8",
    )
    if result.returncode != 0:
        raise subprocess.CalledProcessError(result.returncode, command, result.stdout, result.stderr)


def git_record(repo: Path) -> dict:
    revision = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=repo, check=True, text=True, capture_output=True
    ).stdout.strip()
    status = subprocess.run(
        ["git", "status", "--porcelain=v1", "--untracked-files=all"],
        cwd=repo,
        check=True,
        capture_output=True,
    ).stdout
    return {
        "revision": revision,
        "dirty": bool(status),
        "status_sha256": hashlib.sha256(status).hexdigest(),
        "status_lines": status.decode("utf-8").splitlines(),
    }


def snapshot_tool_sources(tools: Path, environment_root: Path, output: Path, repo: Path) -> list[dict]:
    snapshot_root = environment_root / "tool-sources"
    snapshot_root.mkdir()
    records = []
    for source in sorted(tools.iterdir()):
        if not source.is_file() or source.suffix not in {".py", ".sh", ".json"}:
            continue
        destination = snapshot_root / source.name
        destination.write_bytes(source.read_bytes())
        record = artifact(destination, output)
        record["repository_path"] = str(source.relative_to(repo))
        records.append(record)
    if not records:
        raise ValueError("NR4-C tooling snapshot is empty")
    return records


def tree_bytes(root: Path) -> int:
    return sum(path.stat().st_size for path in root.rglob("*") if path.is_file())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--validation", required=True, type=Path)
    parser.add_argument("--content-root", required=True, type=Path)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--blender", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    validation = require_file(args.validation, "installed validation binary")
    blender = require_file(args.blender, "pinned Blender binary")
    content_root = args.content_root.resolve()
    repo = args.repo.resolve()
    if not content_root.is_dir() or not repo.is_dir():
        raise FileNotFoundError("content root and repository root must exist")
    output = create_absent(args.output.resolve(), "NR4-C still run root")
    source = output / "source"
    target = output / "targets" / "frame-00000120"
    evaluation = output / "evaluation"
    environment_root = output / "environment"
    source.mkdir()
    (output / "targets").mkdir()
    environment_root.mkdir()
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
            "phase": "NR4-C-still",
            "purpose": "one native 256x144 Incinerator input paired with one direct native 1280x720 rights-clean Cycles target",
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
            "INCINERATOR_NR_CAPTURE_START_FRAME": "120",
            "INCINERATOR_NR_CAPTURE_STRIDE": "1",
            "INCINERATOR_NR_CAPTURE_FRAMES": "1",
            "INCINERATOR_NR_COHORT": "overfit",
            "INCINERATOR_NR_SEQUENCE": "nr4-urban-corner-still-0001",
            "INCINERATOR_NR_CAMERA_PATH": "orbit-wide",
        }
    )
    run_command(
        [str(validation), "--nr0-evaluation-smoke", "--frames=180", "--virtual-render-hz=240"],
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
    if len(frame_records) != 1 or len(capture_records) != 1:
        raise ValueError("NR4-C engine execution did not produce exactly one paired frame")
    package_path = target_frame_root / frame_records[0]["path"]
    capture_frame_path = capture_root / capture_records[0]["frame_manifest"]
    if frame_records[0]["presentation_frame"] != capture_records[0]["presentation_frame"]:
        raise ValueError("capture and target-frame selection drifted")

    run_command(
        [
            str(blender),
            "--background",
            "--factory-startup",
            "--python-exit-code",
            "1",
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
        environment_root / "blender.log",
        cwd=repo,
    )
    if not (target / "target-run.json").is_file():
        raise RuntimeError(
            "Blender returned without a complete target manifest; inspect environment/blender.log"
        )
    alignment = evaluation / "alignment"
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
        environment_root / "alignment.log",
        cwd=repo,
    )
    baseline_root = evaluation / "native-baselines"
    run_command(
        [
            sys.executable,
            str(tools / "native_baselines.py"),
            "--capture-frame",
            str(capture_frame_path),
            "--target",
            str(target),
            "--output",
            str(baseline_root),
        ],
        environment_root / "native-baselines.log",
        cwd=repo,
    )
    target_manifest = load_json(target / "target-run.json")
    alignment_manifest = load_json(alignment / "alignment.json")
    complete = {
        "schema": 1,
        "status": "complete",
        "phase": "NR4-C-still",
        "review": "preapproved_native_256x144_to_1280x720_still_review",
        "purpose": "one native 256x144 input paired only with one direct native 1280x720 Cycles target",
        "working_resolution": {
            "input_extent": [256, 144],
            "target_extent": [1280, 720],
            "linear_scale": "x=4:1,y=4:1",
            "foreign_extent_policy": "rejected",
        },
        "repository": git_record(repo),
        "platform": platform.platform(),
        "python": sys.version,
        "source": {
            "capture_root": str(capture_root.relative_to(output)),
            "capture_manifest_sha256": sha256_file(capture_root / "capture.json"),
            "capture_frame": str(capture_frame_path.relative_to(output)),
            "capture_frame_sha256": sha256_file(capture_frame_path),
            "target_frame_root": str(target_frame_root.relative_to(output)),
            "target_frame_manifest_sha256": sha256_file(target_frame_root / "target-frames.json"),
            "frame_package": str(package_path.relative_to(output)),
            "frame_package_sha256": sha256_file(package_path),
        },
        "target": {
            "root": str(target.relative_to(output)),
            "manifest_sha256": sha256_file(target / "target-run.json"),
            "render_ns": target_manifest["cycles"]["render_ns"],
            "blender": target_manifest["blender"],
            "cycles": target_manifest["cycles"],
            "rights": target_manifest["rights"],
            "memory": target_manifest["memory"],
        },
        "evaluation": {
            "alignment_root": str(alignment.relative_to(output)),
            "alignment_manifest_sha256": sha256_file(alignment / "alignment.json"),
            "exact_identity_over_union": alignment_manifest["aggregate"]["exact_over_union"],
            "baseline_root": str(baseline_root.relative_to(output)),
            "baseline_manifest_sha256": sha256_file(baseline_root / "baselines.json"),
            "report": str((baseline_root / "native-256x144-to-1280x720-review.png").relative_to(output)),
            "report_sha256": sha256_file(baseline_root / "native-256x144-to-1280x720-review.png"),
        },
        "evidence_bytes": {
            "native_input_capture": tree_bytes(capture_root),
            "target_frame_packages": tree_bytes(target_frame_root),
            "direct_target": tree_bytes(target),
            "alignment": tree_bytes(alignment),
            "display_baselines_and_report": tree_bytes(baseline_root),
        },
        "environment": {
            "configuration": str(environment.relative_to(repo)),
            "configuration_sha256": sha256_file(environment),
            "blender_binary": str(blender),
            "validation_binary": str(validation),
            "content_root": str(content_root),
            "tool_sources": tool_sources,
            "logs": [
                artifact(path, output)
                for path in sorted(environment_root.glob("*.log"))
            ],
        },
    }
    atomic_json(run_manifest, complete)
    run_command(
        [sys.executable, str(tools / "inspect_native_still.py"), str(output)],
        environment_root / "final-inspect.log",
        cwd=repo,
    )
    # The final inspector log was created after the immutable entry manifest;
    # retain it as supplemental execution evidence without rewriting lineage.
    print(output)


if __name__ == "__main__":
    main()
