#!/usr/bin/env python3
"""Execute two fresh native-resolution NR4-C proofs and compare their truth."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from nr4_common import atomic_json, create_absent, load_json


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--validation", required=True, type=Path)
    parser.add_argument("--content-root", required=True, type=Path)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--blender", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    repo = args.repo.resolve()
    output = create_absent(args.output.resolve(), "NR4-C acceptance root")
    tools = repo / "tools" / "neural-rendering" / "targets" / "blender"
    common = [
        sys.executable,
        str(tools / "run_nr4_c.py"),
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
        [
            sys.executable,
            str(tools / "compare_sequences.py"),
            str(left),
            str(right),
            str(comparison),
        ],
        cwd=repo,
        check=True,
    )
    reproducibility = load_json(comparison)
    ablations = []
    for label, run_root in (("a", left), ("b", right)):
        ablation_root = output / f"control-ablation-{label}"
        subprocess.run(
            [
                sys.executable,
                str(tools / "audit_native_ambiguity.py"),
                "--run",
                str(run_root),
                "--output",
                str(ablation_root),
            ],
            cwd=repo,
            check=True,
        )
        ablation = load_json(ablation_root / "control-ablation.json")
        if (
            ablation["baseline_ambiguous_segments"] != ["lighting_effect"]
            or ablation["ambiguous_segments"]
            or ablation["resolved_segments"] != ["lighting_effect"]
            or not ablation["global_controls_resolve_all_observed_ambiguity"]
        ):
            raise ValueError(f"NR4-C frame-global control ablation failed in run {label}")
        ablations.append(f"control-ablation-{label}/control-ablation.json")
    atomic_json(
        output / "acceptance.json",
        {
            "schema": 1,
            "status": "complete",
            "phase": "NR4-C",
            "review": "product_owner_preapproved_native_160x90_to_640x360_direction_2026-08-11",
            "runs": ["run-a/run.json", "run-b/run.json"],
            "reproducibility": "reproducibility.json",
            "control_ablations": ablations,
            "technical_gate": {
                "engine_capture_equal": reproducibility["engine_capture_equal"],
                "normalized_frame_packages_equal": reproducibility[
                    "normalized_frame_packages_equal"
                ],
                "target_identity_byte_equal": reproducibility["target_identity_byte_equal"],
                "target_depth_byte_equal": reproducibility["target_depth_byte_equal"],
            },
        },
    )
    print(output)


if __name__ == "__main__":
    main()
