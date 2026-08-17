#!/usr/bin/env python3
"""Write the immutable technical conclusion after complete visual review."""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

from title_renderer.io import atomic_json, load_json, sha256_file


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", required=True, type=Path)
    parser.add_argument("--disposition", required=True, choices=("accepted", "rejected", "inconclusive"))
    parser.add_argument("--review", required=True)
    args = parser.parse_args()
    root = args.run.resolve()
    conclusion_path = root / "conclusion.json"
    if conclusion_path.exists():
        raise ValueError("NR5-D conclusion is immutable and already exists")
    run = load_json(root / "run.json")
    rf9 = run.get("phase") == "RF9-D/F"
    rf10 = run.get("phase") == "RF10-D/E"
    validation = load_json(root / run["validation"])
    test_opening = load_json(root / "test-opening.json")
    test_rejection = load_json(root / "test-reopen-rejection.json")
    test = load_json(root / test_opening["evaluation"])
    stress_owner = load_json(root / "stress-evaluation.json")
    stress = load_json(root / stress_owner["evaluation"])
    export = load_json(root / run["export"])
    automated = (
        validation.get("automated_gate_passed") is True
        and test.get("automated_gate_passed") is True
        and stress.get("automated_gate_passed") is True
        and export.get("maximum_absolute_agreement") == 0.0
        and (
            test_opening.get("reopen_guard_installed") is True
            or test_opening.get("second_open_rejected") is True
        )
        and test_rejection.get("status") == "rejected"
        and test_rejection.get("test_opening_sha256") == sha256_file(root / "test-opening.json")
        and test_rejection.get("pixels_opened_by_rejected_attempt") is False
    )
    if args.disposition == "accepted" and not automated:
        raise ValueError("cannot accept NR5-D when an automated gate failed")
    source_records = []
    for source in (
        Path(__file__).resolve(),
        Path(__file__).with_name("evaluate_selected.py"),
        Path(__file__).with_name("inspect_candidate.py"),
    ):
        snapshot = root / "source" / "post-selection" / source.name
        snapshot.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, snapshot)
        source_records.append(
            {
                "source": str(source),
                "source_sha256": sha256_file(source),
                "snapshot": str(snapshot.relative_to(root)),
                "snapshot_sha256": sha256_file(snapshot),
                "bytes": snapshot.stat().st_size,
            }
        )
    conclusion = {
        "schema": 1,
        "experiment": "RF10" if rf10 else ("RF9" if rf9 else "NR-0005"),
        "phase": "RF10-H" if rf10 else ("RF9-H" if rf9 else "NR5-D"),
        "status": args.disposition,
        "review": args.review,
        "run_sha256": sha256_file(root / "run.json"),
        "selection_sha256": sha256_file(root / "selection.json"),
        "test_opening_sha256": sha256_file(root / "test-opening.json"),
        "test_reopen_rejection_sha256": sha256_file(root / "test-reopen-rejection.json"),
        "test_evaluation_sha256": sha256_file(root / test_opening["evaluation"]),
        "stress_evaluation_sha256": sha256_file(root / stress_owner["evaluation"]),
        "stress_corpus_manifest_sha256": stress["dataset"]["corpus_manifest_sha256"],
        "export_sha256": sha256_file(root / run["export"]),
        "post_selection_tool_sources": source_records,
        "automated_gate_passed": automated,
        "complete_visual_review": True,
        "test_pixels_opened_once": True,
        "promotion_authorized": False,
        "next_phase_authorized": ("RF10 external native-720p playable trial" if rf10 else ("RF9 external playable trial" if rf9 else "NR6")) if args.disposition == "accepted" else None,
    }
    atomic_json(conclusion_path, conclusion)
    print(f"NR5_D_FINALIZED disposition={args.disposition} root={root}")


if __name__ == "__main__":
    main()
