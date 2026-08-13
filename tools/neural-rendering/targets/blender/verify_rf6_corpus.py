#!/usr/bin/env python3
"""Manufacture one fresh RF6 corpus through the proven native NR4 owners."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from inspect_sequence import inspect as inspect_sequence
from nr4_common import atomic_json, create_absent, load_json, sha256_file


# Each split owns a distinct deterministic camera program. All six programs
# exercise the same accepted 49-draw RF catalog and six causal fidelity kinds.
SEQUENCES = (
    ("overfit", "rf6-overfit-rich-0001", "nr4-sequence"),
    ("train", "rf6-train-rich-0001", "nr4-corpus-train"),
    ("validation", "rf6-validation-rich-0001", "nr4-corpus-validation"),
    ("test", "rf6-test-rich-sealed-0001", "camera-cut"),
    ("stress", "rf6-stress-rich-near-0001", "nr4-corpus-stress-near"),
    ("stress", "rf6-stress-rich-high-0001", "nr4-corpus-stress-high"),
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--validation", required=True, type=Path)
    parser.add_argument("--content-root", required=True, type=Path)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--blender", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args()
    repo = args.repo.resolve()
    output = args.output.resolve()
    if args.resume:
        if not output.is_dir():
            raise FileNotFoundError("RF6 resume root does not exist")
        if load_json(output / "acceptance.json").get("status") != "partial":
            raise ValueError("RF6 resume requires a partial acceptance root")
    else:
        output = create_absent(output, "RF6 corpus root")
    runs = output / "runs"
    runs.mkdir(exist_ok=args.resume)
    acceptance = output / "acceptance.json"
    if not args.resume:
        atomic_json(
            acceptance,
            {
                "schema": 1,
                "status": "partial",
                "phase": "RF6-C",
                "purpose": "fresh cumulative RF0-RF5 whole-sequence corpus",
                "rf5_target_approval": "product_owner_accepted_2026_08_10",
                "preexisting_pixels_reused": False,
            },
        )

    tools = repo / "tools" / "neural-rendering" / "targets" / "blender"
    sequence_arguments: list[str] = []
    run_records = []
    for split, sequence, camera_path in SEQUENCES:
        run_root = runs / sequence
        if run_root.exists():
            if not args.resume:
                raise FileExistsError(f"RF6 run already exists: {run_root}")
            inspect_sequence(run_root, "NR4-D")
        else:
            subprocess.run(
                [
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
                    "--output",
                    str(run_root),
                    "--phase",
                    "NR4-D",
                    "--cohort",
                    split,
                    "--sequence",
                    sequence,
                    "--camera-path",
                    camera_path,
                ],
                cwd=repo,
                check=True,
            )
        sequence_arguments.extend(["--sequence", f"{split}={run_root}"])
        run_records.append(
            {
                "split": split,
                "sequence": sequence,
                "camera_path": camera_path,
                "root": str(run_root.relative_to(output)),
                "run_manifest_sha256": sha256_file(run_root / "run.json"),
            }
        )

    corpus = output / "corpus"
    subprocess.run(
        [
            sys.executable,
            str(tools / "assemble_nr4_d_corpus.py"),
            *sequence_arguments,
            "--output",
            str(corpus),
        ],
        cwd=repo,
        check=True,
    )
    subprocess.run(
        [sys.executable, str(tools / "inspect_nr4_d_corpus.py"), str(corpus)],
        cwd=repo,
        check=True,
    )
    corpus_manifest = load_json(corpus / "corpus.json")
    atomic_json(
        acceptance,
        {
            "schema": 1,
            "status": "complete",
            "phase": "RF6-C",
            "purpose": "fresh cumulative RF0-RF5 whole-sequence corpus",
            "rf5_target_approval": "product_owner_accepted_2026_08_10",
            "component_contract": "NR4-D native whole-sequence corpus schema",
            "runs": run_records,
            "corpus": "corpus/corpus.json",
            "corpus_sha256": sha256_file(corpus / "corpus.json"),
            "frame_count": corpus_manifest["frame_count"],
            "sequence_count": corpus_manifest["sequence_count"],
            "splits": corpus_manifest["splits"],
            "review": "corpus/review/nr4-d-corpus-review.png",
            "test_pixels_in_review": False,
            "preexisting_pixels_reused": False,
            "model_training": False,
        },
    )
    print(output)


if __name__ == "__main__":
    main()
