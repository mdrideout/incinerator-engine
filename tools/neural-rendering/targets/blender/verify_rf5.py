#!/usr/bin/env python3
"""Execute two fresh RF5 native sequences and retain a pending-review gate."""

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
    output = create_absent(args.output.resolve(), "RF5 acceptance root")
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
    runs = (output / "run-a", output / "run-b")
    for run in runs:
        subprocess.run(common + ["--output", str(run)], cwd=repo, check=True)
    comparison = output / "reproducibility.json"
    subprocess.run(
        [
            sys.executable,
            str(tools / "compare_sequences.py"),
            str(runs[0]),
            str(runs[1]),
            str(comparison),
        ],
        cwd=repo,
        check=True,
    )
    reproducibility = load_json(comparison)
    ablations = []
    for label, run in (("a", runs[0]), ("b", runs[1])):
        ablation_root = output / f"control-ablation-{label}"
        subprocess.run(
            [
                sys.executable,
                str(tools / "audit_native_ambiguity.py"),
                "--run",
                str(run),
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
            raise ValueError(f"RF5 frame-global control ablation failed in run {label}")
        ablations.append(f"control-ablation-{label}/control-ablation.json")
    atomic_json(
        output / "acceptance.json",
        {
            "schema": 1,
            "status": "technical_complete_human_review_pending",
            "phase": "RF5",
            "review": "pending_product_owner_rich_target_direction",
            "runs": ["run-a/run.json", "run-b/run.json"],
            "primary_still_review": (
                "run-a/evaluation/baselines/frame-00000240/"
                "native-160x90-to-640x360-review.png"
            ),
            "primary_sequence_review": (
                "run-a/evaluation/reports/direct-160x90-to-640x360-sequence-review.png"
            ),
            "reproducibility": "reproducibility.json",
            "control_ablations": ablations,
            "technical_gate": {
                "engine_capture_equal": reproducibility["engine_capture_equal"],
                "normalized_frame_packages_equal": reproducibility[
                    "normalized_frame_packages_equal"
                ],
                "target_identity_byte_equal": reproducibility[
                    "target_identity_byte_equal"
                ],
                "target_depth_byte_equal": reproducibility["target_depth_byte_equal"],
            },
        },
    )
    print(output)


if __name__ == "__main__":
    main()
