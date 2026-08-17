#!/usr/bin/env python3
"""Conclude and export RF10 after complete technical visual review."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from title_renderer.inspect_candidate import inspect
from title_renderer.io import atomic_json, load_json, sha256_file


def run(command: list[str], *, repository: Path, log: Path) -> None:
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w", encoding="utf-8") as output:
        result = subprocess.run(command, cwd=repository, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode != 0:
        raise subprocess.CalledProcessError(result.returncode, command)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--campaign", required=True, type=Path)
    parser.add_argument("--repository", required=True, type=Path)
    parser.add_argument("--review", required=True)
    args = parser.parse_args()
    root = args.campaign.resolve()
    repository = args.repository.resolve()
    manifest_path = root / "campaign.json"
    manifest = load_json(manifest_path)
    if manifest.get("status") != "pending_technical_visual_review":
        raise ValueError("RF10 campaign is not awaiting technical visual review")
    candidate = Path(manifest["held_out"])
    inspected = inspect(candidate)
    if inspected.get("phase") != "RF10-F" or inspected.get("test_opened") is not True:
        raise ValueError("RF10 candidate evidence is incomplete")
    module = repository / "tools/neural-rendering/title_renderer"
    run([
        sys.executable, str(module / "finalize_candidate.py"), "--run", str(candidate),
        "--disposition", "accepted", "--review", args.review,
    ], repository=repository, log=root / "logs/conclusion.log")
    run([
        sys.executable, str(module / "measure_candidate.py"), "--run", str(candidate),
        "--stress-corpus", manifest["stress_corpus"],
    ], repository=repository, log=root / "logs/measurements.log")
    trial = root / "trial-bundle"
    run([
        sys.executable, str(module / "export_trial_bundle.py"), "--run", str(candidate),
        "--repository", str(repository), "--output", str(trial),
    ], repository=repository, log=root / "logs/trial-export.log")
    manifest.update({
        "status": "complete",
        "technical_visual_review": args.review,
        "conclusion": str(candidate / "conclusion.json"),
        "conclusion_sha256": sha256_file(candidate / "conclusion.json"),
        "measurements": str(candidate / "nr5-d-measurements.json"),
        "measurements_sha256": sha256_file(candidate / "nr5-d-measurements.json"),
        "trial_bundle": str(trial),
        "trial_promoted": False,
        "product_owner_review": "pending",
    })
    atomic_json(manifest_path, manifest)
    print(f"RF10_CAMPAIGN_COMPLETE candidate={candidate} trial={trial} root={root}")


if __name__ == "__main__":
    main()
