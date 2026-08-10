#!/usr/bin/env python3
"""Append one immutable human/agent disposition to an NR5-B run."""

from __future__ import annotations

import argparse
from pathlib import Path

from title_renderer.inspect_run import inspect
from title_renderer.io import atomic_json, load_json, sha256_file


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", required=True, type=Path)
    parser.add_argument("--disposition", required=True, choices=("accepted", "rejected", "inconclusive"))
    parser.add_argument("--review", required=True)
    args = parser.parse_args()
    root = args.run.resolve()
    if (root / "conclusion.json").exists():
        raise ValueError("NR5-B run already has an immutable conclusion")
    inspected = inspect(root)
    pending = load_json(root / "conclusion.pending.json")
    if args.disposition == "accepted" and not inspected["automated_gate_passed"]:
        raise ValueError("cannot accept an NR5-B run whose automated gate failed")
    conclusion = {
        "schema": 1,
        "phase": "NR5-B",
        "status": args.disposition,
        "review": args.review,
        "run_sha256": pending["run_sha256"],
        "pending_sha256": sha256_file(root / "conclusion.pending.json"),
        "automated_gate_passed": inspected["automated_gate_passed"],
        "test_pixels_opened": False,
        "promotion_authorized": False,
        "next_phase_authorized": "NR5-C" if args.disposition == "accepted" else None,
    }
    atomic_json(root / "conclusion.json", conclusion)
    print(f"NR5_B_FINALIZED disposition={args.disposition} root={root}")


if __name__ == "__main__":
    main()
