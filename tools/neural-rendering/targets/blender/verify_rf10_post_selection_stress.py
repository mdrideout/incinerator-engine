#!/usr/bin/env python3
"""Manufacture RF10 stress pixels only after validation selection is immutable."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from inspect_sequence import inspect as inspect_sequence
from nr4_common import atomic_json, create_absent, load_json, read_ndjson, sha256_file


STRESS_SEQUENCES = (
    ("rf10-postselect-stress-copper-orbit-0001", "rf10-postselect-orbit", "copper-evening"),
    ("rf10-postselect-stress-urban-near-0001", "nr4-corpus-stress-near", "urban-day"),
    ("rf10-postselect-stress-wet-high-0001", "nr4-corpus-stress-high", "wet-night"),
)


def assert_disjoint_stress_programs(base_manifest: dict) -> None:
    retained_camera_paths = {
        record["camera_path"]
        for record in base_manifest["sequences"]
        if record["split"] != "stress"
    }
    stress_camera_paths = [camera_path for _, camera_path, _ in STRESS_SEQUENCES]
    if len(stress_camera_paths) != len(set(stress_camera_paths)):
        raise ValueError("RF10 post-selection stress camera programs must be pairwise distinct")
    overlap = sorted(set(stress_camera_paths) & retained_camera_paths)
    if overlap:
        raise ValueError(f"RF10 post-selection stress reuses retained camera conditioning: {overlap}")


def assert_cross_corpus_digest_disjoint(base_corpus: Path, stress_corpus: Path) -> None:
    base_manifest = load_json(base_corpus / "corpus.json")
    stress_manifest = load_json(stress_corpus / "corpus.json")
    base_records = read_ndjson(base_corpus / base_manifest["frame_index"])
    stress_records = read_ndjson(stress_corpus / stress_manifest["frame_index"])
    retained_conditioning = {
        record["conditioning"]["sha256"]: record["frame_id"]
        for record in base_records
        if record["split"] != "stress"
    }
    retained_pairs = {
        record["pair_sha256"]: record["frame_id"]
        for record in base_records
        if record["split"] != "stress"
    }
    for record in stress_records:
        previous = retained_conditioning.get(record["conditioning"]["sha256"])
        if previous is not None:
            raise ValueError(
                f"RF10 post-selection conditioning leakage between {previous} and {record['frame_id']}"
            )
        previous = retained_pairs.get(record["pair_sha256"])
        if previous is not None:
            raise ValueError(f"RF10 post-selection pair leakage between {previous} and {record['frame_id']}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-corpus", required=True, type=Path)
    parser.add_argument("--selection", required=True, type=Path)
    parser.add_argument("--validation", required=True, type=Path)
    parser.add_argument("--content-root", required=True, type=Path)
    parser.add_argument("--repository", required=True, type=Path)
    parser.add_argument("--blender", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    repository = args.repository.resolve()
    base_corpus = args.base_corpus.resolve()
    selection_path = args.selection.resolve()
    selection = load_json(selection_path)
    if selection.get("status") != "selected_for_single_test_open" or selection.get("test_pixels_opened") is not False:
        raise ValueError("RF10 post-selection stress requires an immutable validation selection")
    output = args.output.resolve()
    selection_sha256 = sha256_file(selection_path)
    base_corpus_sha256 = sha256_file(base_corpus / "corpus.json")
    if output.exists():
        acceptance = load_json(output / "acceptance.json")
        if (
            acceptance.get("status") != "partial"
            or acceptance.get("selection_sha256") != selection_sha256
            or acceptance.get("base_corpus_sha256") != base_corpus_sha256
            or acceptance.get("stress_pixels_existed_before_selection") is not False
        ):
            raise ValueError("RF10 post-selection stress resume root is not the exact partial attempt")
    else:
        output = create_absent(output, "RF10 post-selection stress root")
        atomic_json(output / "acceptance.json", {
            "schema": 1,
            "phase": "RF10-F",
            "status": "partial",
            "selection": str(selection_path),
            "selection_sha256": selection_sha256,
            "base_corpus_sha256": base_corpus_sha256,
            "stress_pixels_existed_before_selection": False,
        })
    tools = repository / "tools/neural-rendering/targets/blender"
    run_root = output / "runs"
    run_root.mkdir(exist_ok=True)
    sequence_arguments: list[str] = []
    base_manifest = load_json(base_corpus / "corpus.json")
    assert_disjoint_stress_programs(base_manifest)
    stress_records = []
    for sequence, camera_path, fixture_variant in STRESS_SEQUENCES:
        destination = run_root / sequence
        if destination.exists():
            inspected = inspect_sequence(destination, "NR4-D")
            run = load_json(destination / "run.json")
            if (
                inspected["cohort"] != "stress"
                or inspected["sequence"] != sequence
                or run.get("camera_path") != camera_path
            ):
                raise ValueError("RF10 post-selection stress resume run has the wrong identity")
        else:
            subprocess.run([
                sys.executable,
                str(tools / "run_nr4_c.py"),
                "--validation", str(args.validation.resolve()),
                "--content-root", str(args.content_root.resolve()),
                "--repo", str(repository),
                "--blender", str(args.blender.resolve()),
                "--output", str(destination),
                "--phase", "NR4-D",
                "--cohort", "stress",
                "--sequence", sequence,
                "--camera-path", camera_path,
                "--fixture-variant", fixture_variant,
            ], cwd=repository, check=True)
        sequence_arguments.extend(["--sequence", f"stress={destination}"])
        stress_records.append({
            "sequence": sequence,
            "camera_path": camera_path,
            "fixture_variant": fixture_variant,
            "run": str(destination.relative_to(output)),
            "run_sha256": sha256_file(destination / "run.json"),
        })
    corpus = output / "corpus"
    subprocess.run([
        sys.executable,
        str(tools / "assemble_nr4_d_corpus.py"),
        *sequence_arguments,
        "--stress-only",
        "--output", str(corpus),
    ], cwd=repository, check=True)
    subprocess.run([
        sys.executable,
        str(tools / "inspect_nr4_d_corpus.py"),
        str(corpus),
    ], cwd=repository, check=True)
    assert_cross_corpus_digest_disjoint(base_corpus, corpus)
    manifest = load_json(corpus / "corpus.json")
    atomic_json(output / "acceptance.json", {
        "schema": 1,
        "phase": "RF10-F",
        "status": "complete",
        "selection": str(selection_path),
        "selection_sha256": selection_sha256,
        "base_corpus_sha256": base_corpus_sha256,
        "corpus": "corpus/corpus.json",
        "corpus_sha256": sha256_file(corpus / "corpus.json"),
        "stress_sequences": stress_records,
        "stress_frames": manifest["splits"]["stress"]["frames"],
        "stress_pixels_existed_before_selection": False,
        "test_pixels_in_review": False,
        "promotion_authorized": False,
    })
    print(f"RF10_POST_SELECTION_STRESS_COMPLETE root={output} corpus={corpus}")


if __name__ == "__main__":
    main()
