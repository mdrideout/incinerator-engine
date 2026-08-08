#!/usr/bin/env python3
"""Read-only integrity inspection for an external NR0-D evaluation root."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from nr_common import load_json, require_absolute, sha256_file


def lines(path: Path) -> int:
    with path.open("r", encoding="utf-8") as source:
        return sum(1 for line in source if line.strip())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    root = require_absolute(args.root, "root")
    state = load_json(root / "evaluation-state.json")
    if state != {"schema": 1, "status": "complete", "manifest": "evaluation.json"}:
        raise ValueError(f"NR0-D evaluation is not complete: {root}")
    evaluation = load_json(root / "evaluation.json")
    if evaluation.get("schema") != 1 or evaluation.get("status") != "complete":
        raise ValueError(f"unsupported NR0-D evaluation: {root}")
    candidate = evaluation["candidate"]
    if sha256_file(Path(candidate["checkpoint"])) != candidate["checkpoint_sha256"]:
        raise ValueError("candidate checkpoint digest drift")
    for capture in evaluation["captures"]:
        manifest = Path(capture["root"]) / "capture.json"
        if sha256_file(manifest) != capture["manifest_sha256"]:
            raise ValueError(f"capture manifest digest drift: {manifest}")
    records = evaluation["records"]
    expected = {
        "frame-metrics.ndjson": records["frames"],
        "instance-metrics.ndjson": records["instances"],
        "temporal-metrics.ndjson": records["temporal_pairs"],
    }
    for relative, count in expected.items():
        if lines(root / relative) != count:
            raise ValueError(f"record count drift: {relative}")
    for evidence in evaluation["evidence_files"]:
        path = Path(evidence["path"])
        if sha256_file(path) != evidence["sha256"]:
            raise ValueError(f"visual evidence digest drift: {path}")
    for relative, digest in evaluation["tool_sources"].items():
        path = Path(__file__).resolve().parents[2] / relative
        if sha256_file(path) != digest:
            raise ValueError(f"evaluation tool digest drift: {path}")
    conclusion_path = root / "conclusion.json"
    conclusion = load_json(conclusion_path) if conclusion_path.exists() else None
    print(json.dumps({
        "status": "pass",
        "root": str(root),
        "frames": records["frames"],
        "instances": records["instances"],
        "temporal_pairs": records["temporal_pairs"],
        "visual_evidence_files": len(evaluation["evidence_files"]),
        "review": conclusion["review"] if conclusion else "pending",
        "promotion": "unpromoted",
    }, sort_keys=True))


if __name__ == "__main__":
    main()
