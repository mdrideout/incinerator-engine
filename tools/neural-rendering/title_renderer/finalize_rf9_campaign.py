#!/usr/bin/env python3
"""Conclude RF9 only after its complete visual evidence has been reviewed."""

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
    campaign_path = root / "campaign.json"
    campaign = load_json(campaign_path)
    if campaign.get("status") != "pending_implementing_agent_visual_review":
        raise ValueError("RF9 campaign is not awaiting its one technical visual conclusion")
    selected = Path(campaign["selected_run"])
    corpus = Path(campaign["corpus"])
    inspected = inspect(selected)
    if inspected.get("phase") != "RF9-H" or inspected.get("test_opened") is not True:
        raise ValueError("RF9 selected evidence is incomplete")
    module_root = repository / "tools/neural-rendering"
    run(
        [sys.executable, str(module_root / "title_renderer/finalize_candidate.py"), "--run", str(selected), "--disposition", "accepted", "--review", args.review],
        repository=repository,
        log=root / "logs/conclusion.log",
    )
    run(
        [sys.executable, str(module_root / "title_renderer/measure_candidate.py"), "--run", str(selected), "--stress-corpus", str(corpus)],
        repository=repository,
        log=root / "logs/measurements.log",
    )
    trial = root / "trial-bundle"
    run(
        [sys.executable, str(module_root / "title_renderer/export_trial_bundle.py"), "--run", str(selected), "--repository", str(repository), "--output", str(trial)],
        repository=repository,
        log=root / "logs/trial-export.log",
    )
    campaign.update({
        "status": "complete",
        "implementing_agent_visual_review": args.review,
        "conclusion": str(selected / "conclusion.json"),
        "conclusion_sha256": sha256_file(selected / "conclusion.json"),
        "measurements": str(selected / "nr5-d-measurements.json"),
        "measurements_sha256": sha256_file(selected / "nr5-d-measurements.json"),
        "trial_bundle": str(trial),
        "trial_promoted": False,
        "product_owner_review": "pending",
    })
    atomic_json(campaign_path, campaign)
    print(f"RF9_CAMPAIGN_COMPLETE selected={selected} trial={trial} root={root}")


if __name__ == "__main__":
    main()
