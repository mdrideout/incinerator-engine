#!/usr/bin/env python3
"""Read-only integrity and acceptance inspection for an NR0-C run."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from nr_common import load_json, require_absolute, sha256_file


def verify_digest(path: Path, expected: str, label: str) -> None:
    actual = sha256_file(path)
    if actual != expected:
        raise ValueError(f"{label} digest mismatch: {path}: {actual} != {expected}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    root = require_absolute(args.root, "root")
    experiment = load_json(root / "experiment.json")
    if experiment.get("status") != "complete" or experiment.get("experiment") != "nr-0002-multichannel-spatial-baseline":
        raise ValueError(f"not a complete NR-0002 result: {root}")

    dataset = experiment["dataset"]
    verify_digest(Path(dataset["manifest"]), dataset["manifest_sha256"], "dataset manifest")
    model = experiment["model"]
    verify_digest(Path(model["checkpoint"]), model["checkpoint_sha256"], "checkpoint")
    coreml = experiment["coreml"]
    export_path = Path(coreml["export_manifest"])
    benchmark_path = Path(coreml["benchmark_manifest"])
    verify_digest(export_path, coreml["export_manifest_sha256"], "export manifest")
    verify_digest(benchmark_path, coreml["benchmark_manifest_sha256"], "benchmark manifest")
    export = load_json(export_path)
    package = Path(export["package"])
    for relative, digest in export["package_file_digests"].items():
        verify_digest(package / relative, digest, "Core ML package file")
    for sample in experiment["samples"]:
        verify_digest(Path(sample["path"]), sample["sha256"], "comparison sample")

    gates = experiment["gates"]
    if experiment["result"] == "candidate":
        if not gates["controlled_fit"]["passed"] or not gates["heldout_validation"]["passed"] or not gates["numerical_passed"] or gates["visual_review"] != "accepted":
            raise ValueError("candidate result does not have every declared gate")
    print(
        json.dumps(
            {
                "status": "pass",
                "root": str(root),
                "result": experiment["result"],
                "dataset_counts": dataset["counts"],
                "model_parameters": model["parameter_count"],
                "comparison_samples": len(experiment["samples"]),
                "coreml_package_files": len(export["package_file_digests"]),
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
