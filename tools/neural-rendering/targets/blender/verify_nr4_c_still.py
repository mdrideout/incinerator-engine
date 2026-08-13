#!/usr/bin/env python3
"""Execute two fresh native NR4-C still proofs and compare their truth."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from nr4_common import atomic_json, create_absent


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--validation", required=True, type=Path)
    parser.add_argument("--content-root", required=True, type=Path)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--blender", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    repo = args.repo.resolve()
    output = create_absent(args.output.resolve(), "NR4-C still acceptance root")
    tools = repo / "tools" / "neural-rendering" / "targets" / "blender"
    common = [
        sys.executable,
        str(tools / "run_nr4_c_still.py"),
        "--validation",
        str(args.validation.resolve()),
        "--content-root",
        str(args.content_root.resolve()),
        "--repo",
        str(repo),
        "--blender",
        str(args.blender.resolve()),
    ]
    left = output / "run-a"
    right = output / "run-b"
    subprocess.run(common + ["--output", str(left)], cwd=repo, check=True)
    subprocess.run(common + ["--output", str(right)], cwd=repo, check=True)
    comparison = output / "reproducibility.json"
    subprocess.run(
        [sys.executable, str(tools / "compare_runs.py"), str(left), str(right), str(comparison)],
        cwd=repo,
        check=True,
    )
    atomic_json(
        output / "acceptance.json",
        {
            "schema": 1,
            "status": "complete",
            "phase": "NR4-C-still",
            "review": "product_owner_preapproved_native_160x90_to_640x360_direction_2026-08-11",
            "runs": ["run-a/run.json", "run-b/run.json"],
            "reproducibility": "reproducibility.json",
        },
    )
    print(output)


if __name__ == "__main__":
    main()
