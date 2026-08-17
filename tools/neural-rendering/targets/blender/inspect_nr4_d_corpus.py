#!/usr/bin/env python3
"""Fail-closed read-only inspector for a complete NR4-D paired corpus."""

from __future__ import annotations

import argparse
from pathlib import Path

from inspect_sequence import inspect as inspect_sequence
from nr4_common import load_json, read_ndjson, sha256_file, verify_artifacts

from assemble_nr4_d_corpus import (
    CORPUS_SCHEMA,
    FRAME_SCHEMA,
    SPLITS,
    claim_sequence_digest,
    digest_values,
)


def verify_artifact(root: Path, record: dict) -> None:
    path = root / record["path"]
    if not path.is_file() or path.stat().st_size != record["bytes"]:
        raise ValueError(f"NR4-D corpus artifact is missing or has wrong size: {path}")
    if sha256_file(path) != record["sha256"]:
        raise ValueError(f"NR4-D corpus artifact digest changed: {path}")


def inspect(root: Path) -> dict:
    root = root.resolve()
    manifest = load_json(root / "corpus.json")
    if manifest.get("schema") != CORPUS_SCHEMA or manifest.get("status") != "complete":
        raise ValueError("NR4-D corpus is incomplete or unexpected")
    if manifest.get("phase") != "NR4-D" or set(manifest.get("splits", {})) != SPLITS:
        raise ValueError("NR4-D corpus split contract drifted")
    if manifest["splits"]["test"]["policy"] != "sealed_until_final_evaluation":
        raise ValueError("NR4-D test split is not sealed")
    if not manifest.get("assembly_tools"):
        raise ValueError("NR4-D corpus has no immutable assembly-tool snapshot")
    for tool in manifest["assembly_tools"]:
        verify_artifact(root, tool)

    records = read_ndjson(root / manifest["frame_index"])
    if len(records) != manifest["frame_count"]:
        raise ValueError("NR4-D corpus frame count drifted")
    sequence_splits = {record["sequence"]: record["split"] for record in manifest["sequences"]}
    if len(sequence_splits) != manifest["sequence_count"]:
        raise ValueError("NR4-D sequence identity is duplicated")
    role = manifest.get("corpus_role", "primary")
    expected_splits = {"stress"} if role == "post_selection_stress" else SPLITS
    if set(sequence_splits.values()) != expected_splits:
        raise ValueError("NR4-D corpus does not own the splits required by its role")

    frame_ids: set[str] = set()
    conditioning_digests: dict[str, tuple[str, str]] = {}
    pair_digests: dict[str, tuple[str, str]] = {}
    for record in records:
        if record.get("schema") != FRAME_SCHEMA:
            raise ValueError("NR4-D corpus frame schema drifted")
        if record["sequence"] not in sequence_splits or sequence_splits[record["sequence"]] != record["split"]:
            raise ValueError("NR4-D frame escaped its whole-sequence split")
        if record["frame_id"] in frame_ids:
            raise ValueError("NR4-D frame identity leaked")
        frame_ids.add(record["frame_id"])
        for name in ("capture_frame", "target_frame_package", "target_run"):
            verify_artifact(root, record[name])
        hashes = []
        for channel in record["conditioning"]["channels"]:
            verify_artifact(root, channel)
            hashes.append(channel["sha256"])
        controls = record["conditioning"]["global_controls"]
        verify_artifact(root, controls)
        hashes.append(controls["sha256"])
        conditioning = digest_values(hashes)
        if conditioning != record["conditioning"]["sha256"]:
            raise ValueError("NR4-D conditioning digest drifted")
        claim_sequence_digest(
            conditioning_digests,
            conditioning,
            record["sequence"],
            record["frame_id"],
            "conditioning",
        )
        target = record["target"]["linear_hdr"]
        verify_artifact(root, target)
        for auxiliary in record["target"]["auxiliary"]:
            verify_artifact(root, auxiliary)
        pair = digest_values([conditioning, target["sha256"]])
        if pair != record["pair_sha256"]:
            raise ValueError("NR4-D pair digest drifted")
        claim_sequence_digest(
            pair_digests,
            pair,
            record["sequence"],
            record["frame_id"],
            "pair",
        )
        if record["review"]["training_eligible"]:
            raise ValueError("NR4-D review derivative became training eligible")
        for path_text in (record["review"]["appearance_debug"], record["review"]["target_display"]):
            if not (root / path_text).is_file():
                raise ValueError("NR4-D review derivative is missing")

    for sequence in manifest["sequences"]:
        sequence_root = root / sequence["root"]
        inspected = inspect_sequence(sequence_root, "NR4-D")
        if inspected["sequence"] != sequence["sequence"] or inspected["cohort"] != sequence["split"]:
            raise ValueError("NR4-D copied sequence identity drifted")
        if sha256_file(sequence_root / "run.json") != sequence["run_manifest_sha256"]:
            raise ValueError("NR4-D copied sequence manifest drifted")

    report_path = root / manifest["review"]["manifest"]
    if sha256_file(report_path) != manifest["review"]["manifest_sha256"]:
        raise ValueError("NR4-D review manifest digest changed")
    report = load_json(report_path)
    if report.get("test_frames_included") is not False:
        raise ValueError("NR4-D sealed test frames entered the review report")
    verify_artifacts(report_path.parent, report["artifacts"])
    return {
        "root": str(root),
        "sequences": len(sequence_splits),
        "frames": len(records),
        "splits": sorted(SPLITS),
        "review": str(report_path.parent / report["artifacts"][0]["path"]),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    result = inspect(args.root)
    print(
        f"NR4_D_CORPUS_INSPECT_PASS sequences={result['sequences']} "
        f"frames={result['frames']} splits={','.join(result['splits'])} "
        f"review={result['review']}"
    )


if __name__ == "__main__":
    main()
