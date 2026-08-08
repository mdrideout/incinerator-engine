#!/usr/bin/env python3
"""Reduce a complete NR0-C run into one auditable experiment manifest."""

from __future__ import annotations

import argparse
import time
from pathlib import Path

from nr_common import atomic_json, environment_record, load_json, require_absolute, sha256_file


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--visual-review", choices=("accepted", "pending", "rejected"), required=True)
    parser.add_argument("--visual-review-note", required=True)
    return parser.parse_args()


def main() -> None:
    args = arguments()
    root = require_absolute(args.root, "--root")
    output = root / ("experiment-pending.json" if args.visual_review == "pending" else "experiment.json")
    if output.exists():
        raise FileExistsError(f"experiment result already exists: {output}")
    dataset_path = root / "dataset/dataset.json"
    overfit_path = root / "overfit-run/training.json"
    heldout_path = root / "heldout-run/training.json"
    export_path = root / "coreml-export/export.json"
    benchmark_path = root / "coreml-export/benchmark-all.json"
    dataset = load_json(dataset_path)
    overfit = load_json(overfit_path)
    heldout = load_json(heldout_path)
    export = load_json(export_path)
    benchmark = load_json(benchmark_path)
    test_metrics = heldout["evaluation"]["test"]["metrics"]
    test_baseline = min(("nearest", "bilinear", "bicubic"), key=lambda name: test_metrics[name]["mae"])
    test_passed = test_metrics["model"]["mae"] < test_metrics[test_baseline]["mae"]
    numerical_passed = bool(overfit["gate"]["passed"] and heldout["gate"]["passed"] and test_passed)
    if not numerical_passed or args.visual_review == "rejected":
        result = "rejected"
    elif args.visual_review == "accepted":
        result = "candidate"
    else:
        result = "inconclusive_pending_human_review"
    samples = sorted((root / "heldout-run/samples").rglob("*-comparison.png"))
    repo_root = Path(__file__).resolve().parents[2]
    atomic_json(
        output,
        {
            "schema": 1,
            "status": "complete",
            "experiment": "nr-0002-multichannel-spatial-baseline",
            "result": result,
            "completed_unix_ms": time.time_ns() // 1_000_000,
            "scope": "NR0-C spatial reconstruction against the S13 conformance scene",
            "non_claims": [
                "not a temporal model or temporal-quality result",
                "not an art-direction or photorealism result",
                "not a shipping-runtime integration or end-to-end frame budget",
                "not promoted or selected by the engine",
            ],
            "dataset": {
                "manifest": str(dataset_path),
                "manifest_sha256": sha256_file(dataset_path),
                "counts": dataset["counts"],
                "captures": dataset["captures"],
                "input_schema": dataset["provenance"]["input_schema"],
                "source_revision": dataset["provenance"]["source_revision"],
                "source_dirty": dataset["provenance"]["source_dirty"],
                "source_dirty_fingerprint": dataset["provenance"]["source_dirty_fingerprint"],
            },
            "model": {
                "parameter_count": heldout["parameter_count"],
                "selected_epoch": heldout["selected_epoch"],
                "configuration": heldout["configuration"],
                "checkpoint": heldout["checkpoint"],
                "checkpoint_sha256": heldout["checkpoint_sha256"],
            },
            "gates": {
                "controlled_fit": overfit["gate"],
                "heldout_validation": heldout["gate"],
                "post_selection_test": {
                    "best_non_neural_baseline": test_baseline,
                    "beats_best_non_neural_baseline_by_mae": test_passed,
                },
                "numerical_passed": numerical_passed,
                "visual_review": args.visual_review,
                "visual_review_note": args.visual_review_note,
            },
            "metrics": {
                split: heldout["evaluation"][split]["metrics"]
                for split in ("train", "validation", "test")
            },
            "samples": [
                {"path": str(path), "sha256": sha256_file(path)}
                for path in samples
            ],
            "coreml": {
                "export_manifest": str(export_path),
                "export_manifest_sha256": sha256_file(export_path),
                "package": export["package"],
                "precision": export["precision"],
                "agreement": export["agreement"],
                "benchmark_manifest": str(benchmark_path),
                "benchmark_manifest_sha256": sha256_file(benchmark_path),
                "compute_units": benchmark["compute_units"],
                "prediction_ms": benchmark["prediction_ms"],
            },
            "promotion": "unpromoted candidate; NR0-E owns any future selection",
            "environment": environment_record(repo_root),
        },
    )
    print(output)


if __name__ == "__main__":
    main()
