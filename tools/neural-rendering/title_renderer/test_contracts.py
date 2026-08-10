#!/usr/bin/env python3
"""Cold, standard-library contracts for NR4-E corpus acceptance."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from title_renderer.contracts import CHANNELS, inspect_corpus_metadata
from title_renderer.coverage import collect
from title_renderer.io import sha256_file


SEMANTICS_AND_MATERIALS = (
    ("environment", "asphalt"),
    ("environment", "sidewalk"),
    ("environment", "masonry"),
    ("environment", "glass"),
    ("environment", "emissive"),
    ("environment", "painted_metal"),
    ("vehicle", "rubber"),
    ("character", "painted_metal"),
    ("npc", "painted_metal"),
    ("carryable", "painted_metal"),
    ("crate", "painted_metal"),
)
SEGMENTS = (
    "camera_motion",
    "object_motion",
    "near_edge",
    "wheel_articulation",
    "occlusion_disocclusion",
    "lighting_effect",
)
SEQUENCES = (
    ("overfit", "nr4-sequence"),
    ("train", "nr4-corpus-train"),
    ("validation", "nr4-corpus-validation"),
    ("test", "camera-cut"),
    ("stress", "nr4-corpus-stress-near"),
    ("stress", "nr4-corpus-stress-high"),
)


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")


def artifact(root: Path, relative: str, data: bytes) -> dict:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return {"path": relative, "bytes": len(data), "sha256": sha256_file(path)}


def target_package(sequence: str, camera_path: str, segment: str, index: int) -> dict:
    draws = []
    for draw_index, (semantic, material) in enumerate(SEMANTICS_AND_MATERIALS):
        draws.append(
            {
                "label": f"draw-{draw_index}",
                "stable_key": f"stable-{draw_index}",
                "semantic": semantic,
                "part": "vehicle_wheel_front_left" if semantic == "vehicle" else "whole",
                "material": material,
                "material_response": {
                    "roughness": 0.5,
                    "metallic": 0.2,
                    "transmission": 0.1 if material == "glass" else 0.0,
                    "ior": 1.45,
                    "emission_strength": 2.0 if material == "emissive" else 0.0,
                    "sheen": 0.0,
                    "subsurface": 0.0,
                    "pattern": "noise",
                    "pattern_scale": 1.0,
                    "pattern_detail": 1.0,
                    "bump_strength": 0.1,
                    "bump_distance": 0.01,
                },
                "transform": {"translation": [float(draw_index), 0.0, 0.0]},
            }
        )
    return {
        "schema_name": "incinerator.nr4.blender-target-frame.v4",
        "input_extent": [160, 90],
        "target_extent": [400, 225],
        "sequence": sequence,
        "camera_path": camera_path,
        "effect_seed": 0,
        "global_controls": {
            "sun_strength": 4.0 + index,
            "world_strength": 0.32,
            "local_light_strength": 550.0,
            "emissive_strength": 8.0,
        },
        "sequence_event": {
            "segment": segment,
            "controlled_change": f"{segment} only",
            "reset": True,
        },
        "camera": {
            "position": [9.0 + index, 9.1 + index, 15.0],
            "forward": [0.7, -0.3, -0.6],
            "vertical_fov_radians": 0.7853982,
            "near": 0.1,
            "far": 250.0,
        },
        "scene": {"id": "fixture", "fingerprint": "fixture-v1"},
        "draws": draws,
    }


def build_fixture(root: Path, *, test_in_review: bool = False) -> Path:
    corpus = root / "corpus"
    records = []
    sequences = []
    splits: dict[str, dict] = {}
    for index, ((split, camera_path), segment) in enumerate(zip(SEQUENCES, SEGMENTS, strict=True)):
        sequence = f"sequence-{index}"
        sequence_root = corpus / "sequences" / sequence
        run = {"schema": 1, "status": "complete", "sequence": sequence}
        write_json(sequence_root / "run.json", run)
        run_record = {
            "sequence": sequence,
            "split": split,
            "root": f"sequences/{sequence}",
            "run_manifest_sha256": sha256_file(sequence_root / "run.json"),
        }
        sequences.append(run_record)
        splits.setdefault(split, {"policy": "declared_whole_sequence"})
        if split == "test":
            splits[split]["policy"] = "sealed_until_final_evaluation"
        package_record = artifact(
            corpus,
            f"sequences/{sequence}/package.json",
            (json.dumps(target_package(sequence, camera_path, segment, index), sort_keys=True) + "\n").encode(),
        )
        capture_record = artifact(
            corpus,
            f"sequences/{sequence}/capture.json",
            (json.dumps({"camera": {"history_reset": "camera_cut"}}, sort_keys=True) + "\n").encode(),
        )
        channel_records = [
            artifact(corpus, f"sequences/{sequence}/{name}.rgba8", bytes((index,)) * 4)
            | {"name": name, "format": "rgba8"}
            for name in CHANNELS
        ]
        controls = artifact(corpus, f"sequences/{sequence}/controls.f32le", bytes(16)) | {
            "schema_name": "incinerator.neural-frame-global.v1"
        }
        target = artifact(corpus, f"sequences/{sequence}/target.exr", b"not-opened-by-contract")
        records.append(
            {
                "schema": 1,
                "frame_id": f"frame-{index}",
                "sequence": sequence,
                "split": split,
                "capture_frame": capture_record,
                "target_frame_package": package_record,
                "conditioning": {"channels": channel_records, "global_controls": controls},
                "target": {"linear_hdr": target},
            }
        )
    frame_index = corpus / "frames.ndjson"
    frame_index.parent.mkdir(parents=True, exist_ok=True)
    frame_index.write_text("".join(json.dumps(record, sort_keys=True) + "\n" for record in records), encoding="utf-8")
    review = {"test_frames_included": test_in_review}
    write_json(corpus / "review" / "report.json", review)
    manifest = {
        "schema": 1,
        "status": "complete",
        "purpose": "self-contained native 160x90 to direct 400x225 paired corpus",
        "rights": {"external_art": False, "learned_denoiser": False, "pretrained_weights": False},
        "sequence_count": len(sequences),
        "frame_count": len(records),
        "frame_index": "frames.ndjson",
        "sequences": sequences,
        "splits": splits,
        "review": {"manifest": "review/report.json", "training_eligible": False},
    }
    write_json(corpus / "corpus.json", manifest)
    return corpus


class CoverageContracts(unittest.TestCase):
    def test_coverage_accepts_scoped_fixture_without_opening_test_pixels(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            corpus = build_fixture(Path(temporary))
            result = collect(corpus)
            self.assertEqual(result["status"], "accepted_for_initial_structural_scope")
            self.assertFalse(result["corpus"]["test_pixels_opened"])
            test_record = next(record for record in result["corpus"]["split_sequences"]["test"])
            self.assertEqual(test_record, "sequence-3")

    def test_test_pixels_in_review_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            corpus = build_fixture(Path(temporary), test_in_review=True)
            with self.assertRaisesRegex(ValueError, "sealed test pixels"):
                inspect_corpus_metadata(corpus, verify_training_artifacts=False)

    def test_foreign_target_extent_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            corpus = build_fixture(Path(temporary))
            package = corpus / "sequences/sequence-0/package.json"
            value = json.loads(package.read_text())
            value["target_extent"] = [1600, 900]
            write_json(package, value)
            with self.assertRaisesRegex(ValueError, "target frame package .*drifted"):
                inspect_corpus_metadata(corpus, verify_training_artifacts=False)


if __name__ == "__main__":
    unittest.main()
