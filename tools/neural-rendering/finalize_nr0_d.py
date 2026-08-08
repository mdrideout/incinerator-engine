#!/usr/bin/env python3
"""Append one immutable human review conclusion to a complete NR0-D root."""

from __future__ import annotations

import argparse
import time
from pathlib import Path

from nr_common import atomic_json, load_json, require_absolute, sha256_file


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--review", required=True, choices=("accepted", "rejected", "inconclusive"))
    parser.add_argument("--note", required=True)
    args = parser.parse_args()
    root = require_absolute(args.root, "--root")
    evaluation_path = root / "evaluation.json"
    evaluation = load_json(evaluation_path)
    if evaluation.get("status") != "complete" or evaluation.get("result") != "pending_human_review":
        raise ValueError(f"not a reviewable NR0-D evaluation: {root}")
    output = root / "conclusion.json"
    if output.exists():
        raise FileExistsError(f"NR0-D conclusion already exists: {output}")
    atomic_json(output, {
        "schema": 1,
        "status": "complete",
        "phase": "NR0-D evaluation and failure analysis",
        "review": args.review,
        "note": args.note,
        "completed_unix_ms": time.time_ns() // 1_000_000,
        "evaluation_manifest": str(evaluation_path),
        "evaluation_manifest_sha256": sha256_file(evaluation_path),
        "model_disposition": "external unpromoted candidate; NR0-E owns any future promotion",
    })
    print(output)


if __name__ == "__main__":
    main()
