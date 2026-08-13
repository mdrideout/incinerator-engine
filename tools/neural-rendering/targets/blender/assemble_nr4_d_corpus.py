#!/usr/bin/env python3
"""Assemble immutable whole NR4-D sequences into one self-contained corpus."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import tempfile
from pathlib import Path

from inspect_sequence import inspect as inspect_sequence
from nr4_common import atomic_json, create_absent, load_json, read_ndjson, sha256_file
from report_nr4_d_corpus import build_report


CORPUS_SCHEMA = 1
FRAME_SCHEMA = 1
SPLITS = {"overfit", "train", "validation", "test", "stress"}


def parse_sequence_arg(value: str) -> tuple[str, Path]:
    split, separator, path_text = value.partition("=")
    if not separator or split not in SPLITS or not path_text:
        raise ValueError("sequence must be SPLIT=/absolute/run with a declared NR4-D split")
    path = Path(path_text)
    if not path.is_absolute():
        raise ValueError("NR4-D source sequence path must be absolute")
    return split, path.resolve()


def digest_values(values: list[str]) -> str:
    digest = hashlib.sha256()
    for value in values:
        digest.update(value.encode("ascii"))
        digest.update(b"\0")
    return digest.hexdigest()


def claim_sequence_digest(
    index: dict[str, tuple[str, str]],
    digest: str,
    sequence: str,
    frame_id: str,
    label: str,
) -> None:
    previous = index.get(digest)
    if previous is not None and previous[0] != sequence:
        raise ValueError(f"NR4-D {label} leakage between {previous[1]} and {frame_id}")
    index.setdefault(digest, (sequence, frame_id))


def atomic_ndjson(path: Path, records: list[dict]) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            for record in records:
                output.write(json.dumps(record, sort_keys=True, allow_nan=False))
                output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def referenced_artifact(root: Path, path: Path, corpus_root: Path) -> dict:
    if not path.is_file() or not path.is_relative_to(root):
        raise ValueError(f"artifact escapes its sequence root: {path}")
    return {
        "path": str(path.relative_to(corpus_root)),
        "bytes": path.stat().st_size,
        "sha256": sha256_file(path),
    }


def assemble(entries: list[tuple[str, Path]], output: Path) -> dict:
    if {split for split, _ in entries} != SPLITS:
        raise ValueError("NR4-D requires separate overfit, train, validation, test, and stress sequences")
    if len({str(path) for _, path in entries}) != len(entries):
        raise ValueError("one source sequence cannot be assigned more than once")

    output = create_absent(output.resolve(), "NR4-D corpus root")
    sequences_root = output / "sequences"
    sequences_root.mkdir()
    assembly_tools_root = output / "assembly-tools"
    assembly_tools_root.mkdir()
    assembly_tools = []
    tools_root = Path(__file__).resolve().parent
    for name in (
        "assemble_nr4_d_corpus.py",
        "inspect_nr4_d_corpus.py",
        "inspect_sequence.py",
        "nr4_common.py",
        "report_nr4_d_corpus.py",
    ):
        source_tool = tools_root / name
        destination_tool = assembly_tools_root / name
        shutil.copy2(source_tool, destination_tool)
        assembly_tools.append(
            {
                "path": str(destination_tool.relative_to(output)),
                "bytes": destination_tool.stat().st_size,
                "sha256": sha256_file(destination_tool),
            }
        )
    atomic_json(
        output / "corpus.json",
        {"schema": CORPUS_SCHEMA, "status": "partial", "phase": "NR4-D"},
    )

    frame_records: list[dict] = []
    sequence_records: list[dict] = []
    frame_ids: set[str] = set()
    conditioning_digests: dict[str, tuple[str, str]] = {}
    pair_digests: dict[str, tuple[str, str]] = {}
    cohort_provenance: dict | None = None

    for split, source in entries:
        inspected = inspect_sequence(source, "NR4-D")
        run = load_json(source / "run.json")
        if run.get("cohort") != split or inspected["cohort"] != split:
            raise ValueError("NR4-D source run cohort disagrees with its assigned split")
        sequence = inspected["sequence"]
        if any(record["sequence"] == sequence for record in sequence_records):
            raise ValueError("NR4-D sequence identity appears in more than one split")

        destination = sequences_root / sequence
        shutil.copytree(source, destination, copy_function=shutil.copy2)
        inspect_sequence(destination, "NR4-D")
        copied_run = load_json(destination / "run.json")
        capture_root = destination / copied_run["source"]["capture_root"]
        capture = load_json(capture_root / "capture.json")
        frame_root = destination / copied_run["source"]["target_frame_root"]
        sequence_manifest_path = destination / copied_run["sequence"]["manifest"]
        sequence_manifest = load_json(sequence_manifest_path)
        capture_records = read_ndjson(capture_root / capture["frame_index"])
        capture_by_frame = {record["frame_id"]: record for record in capture_records}

        first_frame = sequence_manifest["frames"][0]
        first_package = load_json(destination / first_frame["frame_package"])
        first_target_root = destination / first_frame["target_root"]
        first_target = load_json(first_target_root / "target-run.json")
        provenance = {
            "engine_source": first_package["source"],
            "input_schema": capture["input_schema"],
            "content_digest": capture["content_digest"],
            "shader_fingerprint": capture["shader_fingerprint"],
            "shader_sha256": capture["shader_sha256"],
            "target_configuration_sha256": copied_run["environment"]["configuration_sha256"],
            "target_adapter_sources": first_target["adapter"]["sources"],
        }
        if cohort_provenance is None:
            cohort_provenance = provenance
        elif provenance != cohort_provenance:
            raise ValueError("NR4-D sequence provenance drifted within the corpus cohort")

        sequence_record = {
            "split": split,
            "sequence": sequence,
            "camera_path": copied_run["camera_path"],
            "frame_count": inspected["frame_count"],
            "root": str(destination.relative_to(output)),
            "run_manifest_sha256": sha256_file(destination / "run.json"),
            "sequence_manifest_sha256": sha256_file(sequence_manifest_path),
            "source_run": str(source),
            "source_repository": copied_run["repository"],
        }
        sequence_records.append(sequence_record)

        for frame in sequence_manifest["frames"]:
            frame_id = frame["frame_id"]
            if frame_id in frame_ids:
                raise ValueError("NR4-D frame identity leaked between sequences")
            frame_ids.add(frame_id)
            capture_frame_path = destination / frame["capture_frame"]
            package_path = destination / frame["frame_package"]
            target_root = destination / frame["target_root"]
            capture_frame = load_json(capture_frame_path)
            package = load_json(package_path)
            target = load_json(target_root / "target-run.json")
            if frame_id not in capture_by_frame or package["sequence"] != sequence:
                raise ValueError("NR4-D frame join is incomplete")

            channels = []
            conditioning_hashes = []
            for channel in capture_frame["channels"]:
                raw = referenced_artifact(
                    destination,
                    capture_root / channel["raw_path"],
                    output,
                )
                raw["name"] = channel["name"]
                raw["format"] = channel["format"]
                channels.append(raw)
                conditioning_hashes.append(raw["sha256"])
            controls = referenced_artifact(
                destination,
                capture_root / capture_frame["global_controls"]["raw_path"],
                output,
            )
            controls["schema_name"] = capture_frame["global_controls"]["schema_name"]
            conditioning_hashes.append(controls["sha256"])

            target_artifacts = {record["path"]: record for record in target["artifacts"]}
            target_hdr = referenced_artifact(destination, target_root / "target.exr", output)
            auxiliary = []
            for name in ("identity.u32", "depth.f32", "normal.f32"):
                artifact_record = referenced_artifact(destination, target_root / name, output)
                if artifact_record["sha256"] != target_artifacts[name]["sha256"]:
                    raise ValueError("NR4-D copied target artifact digest drifted")
                artifact_record["kind"] = name
                auxiliary.append(artifact_record)
            conditioning_digest = digest_values(conditioning_hashes)
            pair_digest = digest_values([conditioning_digest, target_hdr["sha256"]])
            claim_sequence_digest(
                conditioning_digests,
                conditioning_digest,
                sequence,
                frame_id,
                "conditioning",
            )
            claim_sequence_digest(pair_digests, pair_digest, sequence, frame_id, "pair")

            frame_records.append(
                {
                    "schema": FRAME_SCHEMA,
                    "frame_id": frame_id,
                    "split": split,
                    "sequence": sequence,
                    "presentation_frame": frame["presentation_frame"],
                    "capture_frame": referenced_artifact(destination, capture_frame_path, output),
                    "target_frame_package": referenced_artifact(destination, package_path, output),
                    "target_run": referenced_artifact(destination, target_root / "target-run.json", output),
                    "conditioning": {
                        "channels": channels,
                        "global_controls": controls,
                        "sha256": conditioning_digest,
                    },
                    "target": {"linear_hdr": target_hdr, "auxiliary": auxiliary},
                    "pair_sha256": pair_digest,
                    "rights": target["rights"],
                    "review": {
                        "training_eligible": False,
                        "appearance_debug": str(
                            (capture_root / capture_frame["channels"][0]["debug_path"]).relative_to(output)
                        ),
                        "target_display": str((target_root / "target-display.png").relative_to(output)),
                    },
                }
            )

    atomic_ndjson(output / "frames.ndjson", frame_records)
    report = build_report(output, output / "review")
    split_summary = {
        split: {
            "sequences": sum(record["split"] == split for record in sequence_records),
            "frames": sum(record["split"] == split for record in frame_records),
            "policy": "sealed_until_final_evaluation" if split == "test" else "declared_whole_sequence",
        }
        for split in sorted(SPLITS)
    }
    manifest = {
        "schema": CORPUS_SCHEMA,
        "status": "complete",
        "phase": "NR4-D",
        "purpose": "self-contained native 160x90 to direct 640x360 paired corpus",
        "working_resolution": {"input_extent": [160, 90], "target_extent": [640, 360]},
        "frame_index": "frames.ndjson",
        "frame_count": len(frame_records),
        "sequence_count": len(sequence_records),
        "sequences": sequence_records,
        "splits": split_summary,
        "cohort_provenance": cohort_provenance,
        "assembly_tools": assembly_tools,
        "leakage_policy": "whole-sequence split; unique frame, conditioning, and pair digests",
        "rights": {
            "source": "repository-owned procedural fixture and adapter",
            "external_art": False,
            "pretrained_weights": False,
            "learned_denoiser": False,
        },
        "review": {
            "training_eligible": False,
            "manifest": "review/report.json",
            "manifest_sha256": sha256_file(output / "review/report.json"),
            "artifacts": report["artifacts"],
        },
    }
    atomic_json(output / "corpus.json", manifest)
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--sequence",
        action="append",
        required=True,
        help="SPLIT=/absolute/complete-nr4-d-run; repeat for each whole sequence",
    )
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    manifest = assemble([parse_sequence_arg(value) for value in args.sequence], args.output)
    print(
        f"NR4_D_CORPUS_ASSEMBLED sequences={manifest['sequence_count']} "
        f"frames={manifest['frame_count']} root={args.output.resolve()}"
    )


if __name__ == "__main__":
    main()
