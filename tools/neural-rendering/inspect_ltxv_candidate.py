#!/usr/bin/env python3
"""Validate and summarize one immutable NR-0003 LTX candidate folder."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

from nr_common import load_json, sha256_file


def inspect(root: Path) -> dict[str, Any]:
    root = root.resolve()
    manifest_path = root / "candidate.json"
    manifest = load_json(manifest_path)
    if manifest.get("schema") != 2 or manifest.get("status") != "complete":
        raise ValueError("candidate must be complete schema 2")
    if manifest.get("not_promotion_eligible") is not True:
        raise ValueError("stock LTX baseline must remain explicitly unpromotable")
    if manifest["configuration"]["source_sha256"] != manifest["configuration"]["snapshot_sha256"]:
        raise ValueError("configuration snapshot did not preserve the invoked source")
    if manifest["prompt"]["source_sha256"] != manifest["prompt"]["snapshot_sha256"]:
        raise ValueError("prompt snapshot did not preserve the invoked source")
    checks = [
        (Path(manifest["sequence_manifest"]), manifest["sequence_manifest_sha256"]),
        (
            Path(manifest["configuration"]["snapshot"]),
            manifest["configuration"]["snapshot_sha256"],
        ),
        (Path(manifest["prompt"]["snapshot"]), manifest["prompt"]["snapshot_sha256"]),
        (Path(manifest["model"]["checkpoint"]), manifest["model"]["checkpoint_sha256"]),
        (
            Path(manifest["model"]["license"]["artifact"]),
            manifest["model"]["license"]["artifact_sha256"],
        ),
        (Path(manifest["generated_video"]), manifest["generated_video_sha256"]),
        (Path(manifest["contact_sheet"]), manifest["contact_sheet_sha256"]),
        (Path(manifest["comparison_sheet"]), manifest["comparison_sheet_sha256"]),
    ]
    if manifest["model"].get("spatial_upscaler"):
        checks.append(
            (
                Path(manifest["model"]["spatial_upscaler"]),
                manifest["model"]["spatial_upscaler_sha256"],
            )
        )
    if manifest["model"]["license"].get("promotion_and_distribution_review_required") is not True:
        raise ValueError("candidate must retain the LTX model-license review gate")
    for path, expected in checks:
        if not path.is_absolute() or not path.is_file():
            raise ValueError(f"candidate artifact is absent or non-absolute: {path}")
        if sha256_file(path) != expected:
            raise ValueError(f"candidate artifact digest mismatch: {path}")
    measurements = manifest.get("measurements")
    if not isinstance(measurements, dict) or measurements.get("warm_effective_fps", 0) <= 0:
        raise ValueError("candidate has no positive warm throughput measurement")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    manifest = inspect(args.root)
    measurement = manifest["measurements"]
    print(
        "NR0003_LTX_INSPECT_PASS "
        f"result={manifest['result']} warm_fps={measurement['warm_effective_fps']:.3f} "
        f"peak_rss_bytes={measurement['peak_process_rss_bytes']}"
    )


if __name__ == "__main__":
    main()
