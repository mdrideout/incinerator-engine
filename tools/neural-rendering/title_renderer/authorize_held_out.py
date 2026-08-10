#!/usr/bin/env python3
"""Authorize the exact NR5-C/D known-fixture cohort without opening test pixels."""

from __future__ import annotations

import argparse
import shutil
from collections import Counter
from pathlib import Path

from title_renderer.contracts import inspect_corpus_metadata
from title_renderer.io import (
    atomic_json,
    create_absent_absolute,
    environment_record,
    load_json,
    repository_record,
    require_existing_absolute,
    sha256_file,
)


SCOPE = "NR5-C held-out known-fixture reconstruction and NR5-D native stress conclusion"


def verified_artifact(root: Path, owner: dict, path_key: str, digest_key: str) -> Path:
    path = root / str(owner[path_key])
    if not path.is_file() or sha256_file(path) != owner[digest_key]:
        raise ValueError(f"authorization input drifted: {path}")
    return path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", required=True, type=Path)
    parser.add_argument("--nr4-e-acceptance", required=True, type=Path)
    parser.add_argument("--nr5-b-run", required=True, type=Path)
    parser.add_argument("--repository", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    corpus = require_existing_absolute(args.corpus, "--corpus")
    nr4_e_path = require_existing_absolute(args.nr4_e_acceptance, "--nr4-e-acceptance")
    nr5_b_root = require_existing_absolute(args.nr5_b_run, "--nr5-b-run")
    repository = require_existing_absolute(args.repository, "--repository")
    output = create_absent_absolute(args.output, "--output")
    try:
        inspected = inspect_corpus_metadata(corpus, verify_training_artifacts=True)
        nr4_e = load_json(nr4_e_path)
        if (
            nr4_e.get("status") != "accepted"
            or nr4_e.get("model_training_authorized") is not True
            or nr4_e.get("sealed_test_pixels_opened") is not False
            or nr4_e.get("corpus_manifest_sha256") != sha256_file(corpus / "corpus.json")
        ):
            raise ValueError("NR4-E acceptance does not authorize the exact sealed corpus")
        nr4_root = nr4_e_path.parent
        for pair in (
            ("coverage", "coverage_sha256"),
            ("coverage_markdown", "coverage_markdown_sha256"),
            ("environment", "environment_sha256"),
        ):
            verified_artifact(nr4_root, nr4_e, *pair)
        nr5_b_run = load_json(nr5_b_root / "run.json")
        nr5_b_conclusion = load_json(nr5_b_root / "conclusion.json")
        if (
            nr5_b_run.get("phase") != "NR5-B"
            or nr5_b_run.get("test_pixels_opened") is not False
            or nr5_b_conclusion.get("status") != "accepted"
            or nr5_b_conclusion.get("next_phase_authorized") != "NR5-C"
            or nr5_b_conclusion.get("run_sha256") != sha256_file(nr5_b_root / "run.json")
        ):
            raise ValueError("accepted NR5-B lineage does not authorize NR5-C")
        split_frames = Counter(str(record["split"]) for record in inspected["records"])
        if set(split_frames) != {"overfit", "train", "validation", "test", "stress"}:
            raise ValueError("held-out authorization requires every declared whole split")
        sources = [
            Path(__file__).resolve(),
            Path(__file__).with_name("__init__.py"),
            Path(__file__).with_name("contracts.py"),
            Path(__file__).with_name("io.py"),
        ]
        source_records = []
        for source in sources:
            relative = source.relative_to(repository)
            snapshot = output / "source" / relative
            snapshot.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, snapshot)
            source_records.append(
                {
                    "repository_path": str(relative),
                    "repository_sha256": sha256_file(source),
                    "snapshot_path": str(snapshot.relative_to(output)),
                    "snapshot_sha256": sha256_file(snapshot),
                    "bytes": snapshot.stat().st_size,
                }
            )
        environment_path = output / "environment.json"
        atomic_json(environment_path, environment_record())
        acceptance = {
            "schema": 1,
            "phase": "NR5-C-entry",
            "status": "accepted",
            "authorization_scope": SCOPE,
            "corpus_manifest_sha256": sha256_file(corpus / "corpus.json"),
            "split_frames": dict(sorted(split_frames.items())),
            "train_splits": ["overfit", "train"],
            "selection_split": "validation",
            "single_open_test_split": "test",
            "stress_split": "stress",
            "known_limit": "one procedural fixture; results are known-fixture held-out evidence, not title-wide generalization",
            "nr4_e_acceptance": str(nr4_e_path),
            "nr4_e_acceptance_sha256": sha256_file(nr4_e_path),
            "nr5_b_run": str(nr5_b_root),
            "nr5_b_run_sha256": sha256_file(nr5_b_root / "run.json"),
            "nr5_b_conclusion_sha256": sha256_file(nr5_b_root / "conclusion.json"),
            "repository": repository_record(repository),
            "environment": "environment.json",
            "environment_sha256": sha256_file(environment_path),
            "tool_sources": source_records,
            "test_pixels_opened": False,
            "promotion_authorized": False,
        }
        atomic_json(output / "acceptance.json", acceptance)
    except Exception as error:
        atomic_json(output / "failure.json", {"schema": 1, "phase": "NR5-C-entry", "error": str(error)})
        raise
    print(f"NR5_C_ENTRY_ACCEPTED scope={SCOPE} output={output}")


if __name__ == "__main__":
    main()
