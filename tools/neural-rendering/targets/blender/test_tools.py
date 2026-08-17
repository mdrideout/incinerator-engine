#!/usr/bin/env python3
"""Focused contracts for the current native target package and evidence tools."""

from __future__ import annotations

import copy
import json
import struct
import tempfile
import unittest
from pathlib import Path

from analyze_target import compact_codes
from assemble_nr4_d_corpus import atomic_ndjson, claim_sequence_digest, digest_values, parse_sequence_arg
from inspect_nr4_d_corpus import verify_artifact
from report_nr4_d_corpus import build_report
from compare_runs import canonical_json_digest, float_difference, normalized_package
from nr4_common import atomic_json, create_absent, load_json, validate_frame_package
from verify_rf10_post_selection_stress import (
    assert_cross_corpus_digest_disjoint,
    assert_disjoint_stress_programs,
)
from sequence_contract import (
    EXPECTED_MATERIAL_CHANGES,
    EXPECTED_TRANSFORM_CHANGES,
    FRAME_COUNT,
    FRAMES,
    SEGMENTS,
    SAMPLES_PER_SEGMENT,
    audit_packages,
    expected_event,
)


CHANNELS = ("appearance", "linear-depth", "world-normal", "motion", "semantic", "instance")


def frame_package() -> dict:
    return {
        "schema": 8,
        "schema_name": "incinerator.nr4.blender-target-frame.v8",
        "status": "complete",
        "frame_id": "fixture-frame-00000001",
        "sequence": "fixture",
        "camera_path": "orbit-wide",
        "authority_tick": 1,
        "presentation_frame": 1,
        "interpolation_alpha": 0.0,
        "input_extent": [256, 144],
        "target_extent": [1280, 720],
        "sampling_map": {
            "x": {
                "scale_numerator": 5,
                "scale_denominator": 1,
                "target_center_to_source_index": "((target_x + 0.5) / 5) - 0.5",
            },
            "y": {
                "scale_numerator": 5,
                "scale_denominator": 1,
                "target_center_to_source_index": "((target_y + 0.5) / 5) - 0.5",
            },
            "border": "clamp",
        },
        "exposure": 1.0,
        "effect_seed": 0,
        "global_controls": {
            "schema_name": "incinerator.neural-frame-global.v2",
            "sun_strength": 1.0,
            "world_strength": 0.0,
            "local_light_strength": 20.0,
            "emissive_strength": 0.0,
            "material_palette": 0.0,
        },
        "sequence_event": {
            "segment": "still",
            "segment_index": 0,
            "sample_index": 0,
            "progress": 0.0,
            "reset": False,
            "controlled_change": "none",
        },
        "source": {
            "revision": "test",
            "dirty": True,
            "dirty_fingerprint": "test-dirty",
            "content_sha256": "test-content",
            "input_schema": "test-input",
            "shader_fingerprint": "test-shader",
        },
        "coordinate_system": {
            "world": "right-handed +Y up -Z forward",
            "matrix_storage": "zmath row-major row-vector",
            "image_origin": "top-left",
            "sample": "pixel-center",
        },
        "camera": {
            "position": [0.0, 1.0, 2.0],
            "forward": [0.0, 0.0, -1.0],
            "up": [0.0, 1.0, 0.0],
            "vertical_fov_radians": 1.0,
            "near": 0.1,
            "far": 100.0,
            "view": [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0],
            "view_projection": [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0],
        },
        "scene": {
            "id": "fixture",
            "fingerprint": "fixture-v1",
            "sun_direction": [0.0, -1.0, 0.0],
            "sun_color": [1.0, 1.0, 1.0],
            "sun_strength": 1.0,
            "sun_angle_radians": 0.1,
            "world_color": [0.0, 0.0, 0.0],
            "world_strength": 0.0,
            "local_light_position": [0.0, 2.0, 0.0],
            "local_light_color": [1.0, 0.8, 0.5],
            "local_light_strength": 20.0,
            "local_light_radius": 0.5,
        },
        "draws": [
            {
                "label": "road",
                "stable_key": "0123456789abcdef",
                "compact_rgb24": 0x030201,
                "semantic": "environment",
                "part": "whole",
                "ordinal": 0,
                "identity": {"kind": "fixture", "value": 1},
                "shape": "box",
                "material": "asphalt",
                "material_response": {
                    "roughness": 0.8,
                    "metallic": 0.0,
                    "transmission": 0.0,
                    "ior": 1.45,
                    "emission_strength": 0.0,
                    "sheen": 0.0,
                    "subsurface": 0.0,
                    "pattern": "noise",
                    "pattern_scale": 20.0,
                    "pattern_detail": 3.0,
                    "bump_strength": 0.2,
                    "bump_distance": 0.05,
                },
                "base_color": [0.1, 0.1, 0.1, 1.0],
                "transform": {
                    "scale": [4.0, 0.2, 8.0],
                    "rotation_xyz": [0.0, 0.0, 0.0],
                    "translation": [0.0, 0.0, 0.0],
                },
                "model_matrix": [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0],
            }
        ],
        "source_capture_frame": "/tmp/run-a/source/capture/frames/frame-00000001.json",
    }


def sequence_packages() -> list[dict]:
    labels = sorted(
        {"road"}
        | set().union(*EXPECTED_TRANSFORM_CHANGES.values())
        | set().union(*EXPECTED_MATERIAL_CHANGES.values())
    )
    template = frame_package()
    template["draws"] = []
    for index, label in enumerate(labels, 1):
        draw = copy.deepcopy(frame_package()["draws"][0])
        draw["label"] = label
        draw["stable_key"] = f"{index:016x}"
        draw["compact_rgb24"] = index
        draw["identity"] = {"kind": "fixture", "value": index}
        if label in EXPECTED_MATERIAL_CHANGES["lighting_effect"]:
            draw["material"] = "emissive"
            draw["material_response"]["emission_strength"] = 0.0
        template["draws"].append(draw)
    result = []
    for index in range(FRAME_COUNT):
        package = copy.deepcopy(template)
        event = expected_event(index)
        package["sequence_event"].update(event)
        package["presentation_frame"] = FRAMES[index]
        segment = event["segment"]
        progress = event["progress"]
        if segment in {"camera_motion", "near_edge"}:
            package["camera"]["position"][0] += progress
        for draw in package["draws"]:
            if draw["label"] in EXPECTED_TRANSFORM_CHANGES[segment]:
                draw["transform"]["translation"][0] += progress
                draw["model_matrix"][12] += progress
            if draw["label"] in EXPECTED_MATERIAL_CHANGES[segment]:
                draw["material_response"]["emission_strength"] += progress
        if segment == "lighting_effect":
            package["scene"]["sun_strength"] += progress
            package["scene"]["world_strength"] += progress
            package["scene"]["local_light_strength"] += progress
            package["global_controls"]["sun_strength"] += progress
            package["global_controls"]["world_strength"] += progress
            package["global_controls"]["local_light_strength"] += progress
            package["global_controls"]["emissive_strength"] += progress
        result.append(package)
    return result


class Nr4TargetToolTests(unittest.TestCase):
    def test_frame_package_requires_unique_identity(self) -> None:
        package = frame_package()
        validate_frame_package(package)
        package["draws"].append(copy.deepcopy(package["draws"][0]))
        package["draws"][1]["label"] = "sidewalk"
        with self.assertRaisesRegex(ValueError, "stable keys"):
            validate_frame_package(package)

    def test_frame_package_rejects_every_foreign_working_extent(self) -> None:
        package = frame_package()
        for field, foreign in (
            ("input_extent", [400, 225]),
            ("target_extent", [1600, 900]),
        ):
            candidate = copy.deepcopy(package)
            candidate[field] = foreign
            with self.assertRaisesRegex(ValueError, "not native"):
                validate_frame_package(candidate)

    def test_frame_package_requires_exact_rational_pixel_center_mapping(self) -> None:
        package = frame_package()
        validate_frame_package(package)
        package["sampling_map"]["x"]["scale_numerator"] = 2
        with self.assertRaisesRegex(ValueError, "exact axis-specific"):
            validate_frame_package(package)

    def test_instance_rgba_decodes_little_endian_and_coverage(self) -> None:
        self.assertEqual(compact_codes(bytes((1, 2, 3, 255, 9, 8, 7, 0))), [0x030201, 0])

    def test_normalized_package_removes_only_run_local_capture_path(self) -> None:
        left = frame_package()
        right = copy.deepcopy(left)
        right["source_capture_frame"] = "/tmp/run-b/source/capture/frames/frame-00000001.json"
        self.assertEqual(
            canonical_json_digest(normalized_package(left)),
            canonical_json_digest(normalized_package(right)),
        )
        right["draws"][0]["material"] = "sidewalk"
        self.assertNotEqual(
            canonical_json_digest(normalized_package(left)),
            canonical_json_digest(normalized_package(right)),
        )

    def test_outputs_are_absolute_absent_roots(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "new"
            self.assertEqual(create_absent(root, "test root"), root)
            with self.assertRaises(FileExistsError):
                create_absent(root, "test root")
            with self.assertRaises(ValueError):
                create_absent(Path("relative"), "test root")

    def test_nr4_d_sequence_assignment_is_explicit_and_absolute(self) -> None:
        split, path = parse_sequence_arg("validation=/tmp/nr4-d-validation")
        self.assertEqual(split, "validation")
        self.assertEqual(path, Path("/tmp/nr4-d-validation").resolve())
        with self.assertRaisesRegex(ValueError, "declared NR4-D split"):
            parse_sequence_arg("random=/tmp/run")
        with self.assertRaisesRegex(ValueError, "must be absolute"):
            parse_sequence_arg("train=relative/run")

    def test_nr4_d_pair_digest_is_ordered_and_domain_separated(self) -> None:
        self.assertEqual(digest_values(["aa", "bb"]), digest_values(["aa", "bb"]))
        self.assertNotEqual(digest_values(["aa", "bb"]), digest_values(["bb", "aa"]))
        self.assertNotEqual(digest_values(["a", "abb"]), digest_values(["aa", "bb"]))

    def test_nr4_d_leakage_is_sequence_scoped(self) -> None:
        index: dict[str, tuple[str, str]] = {}
        claim_sequence_digest(index, "digest", "train-a", "frame-a", "pair")
        claim_sequence_digest(index, "digest", "train-a", "frame-b", "pair")
        with self.assertRaisesRegex(ValueError, "pair leakage"):
            claim_sequence_digest(index, "digest", "validation-a", "frame-c", "pair")

    def test_rf10_post_selection_stress_rejects_retained_conditioning(self) -> None:
        manifest = {
            "sequences": [
                {
                    "split": "test",
                    "camera_path": "rf10-postselect-orbit",
                }
            ]
        }
        with self.assertRaisesRegex(ValueError, "reuses retained camera conditioning"):
            assert_disjoint_stress_programs(manifest)

        manifest["sequences"][0]["camera_path"] = "fast-orbit"
        assert_disjoint_stress_programs(manifest)

    def test_rf10_cross_corpus_stress_digest_check_is_exact(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base = root / "base"
            stress = root / "stress"
            base.mkdir()
            stress.mkdir()
            atomic_json(base / "corpus.json", {"frame_index": "frames.ndjson"})
            atomic_json(stress / "corpus.json", {"frame_index": "frames.ndjson"})
            base_record = {
                "split": "test",
                "frame_id": "sealed-frame",
                "conditioning": {"sha256": "conditioning-a"},
                "pair_sha256": "pair-a",
            }
            stress_record = {
                "split": "stress",
                "frame_id": "stress-frame",
                "conditioning": {"sha256": "conditioning-b"},
                "pair_sha256": "pair-b",
            }
            atomic_ndjson(base / "frames.ndjson", [base_record])
            atomic_ndjson(stress / "frames.ndjson", [stress_record])
            assert_cross_corpus_digest_disjoint(base, stress)
            stress_record["conditioning"]["sha256"] = "conditioning-a"
            atomic_ndjson(stress / "frames.ndjson", [stress_record])
            with self.assertRaisesRegex(ValueError, "conditioning leakage"):
                assert_cross_corpus_digest_disjoint(base, stress)

    def test_nr4_d_artifact_corruption_and_removal_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "artifact.bin"
            path.write_bytes(b"accepted")
            record = {
                "path": "artifact.bin",
                "bytes": len(b"accepted"),
                "sha256": "070c160a6299c5438070b1aa737b14fc2992ed49579c14264884886a5876f971",
            }
            verify_artifact(root, record)
            path.write_bytes(b"corrupt!")
            with self.assertRaisesRegex(ValueError, "digest changed"):
                verify_artifact(root, record)
            path.unlink()
            with self.assertRaisesRegex(ValueError, "missing or has wrong size"):
                verify_artifact(root, record)

    def test_nr4_d_review_never_opens_the_test_split(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            records = []
            for index, split in enumerate(("train", "test")):
                sequence = f"{split}-sequence"
                source = root / f"{sequence}-source.ppm"
                target = root / f"{sequence}-target.png"
                source.write_bytes(b"P6\n1 1\n255\n\x00\x00\x00")
                from PIL import Image

                Image.new("RGB", (1280, 720), (index * 32, 0, 0)).save(target)
                records.append(
                    {
                        "split": split,
                        "sequence": sequence,
                        "presentation_frame": 1,
                        "review": {
                            "appearance_debug": source.name,
                            "target_display": target.name,
                        },
                    }
                )
            (root / "frames.ndjson").write_text(
                "".join(json.dumps(record) + "\n" for record in records),
                encoding="utf-8",
            )
            report = build_report(root, root / "report")
            self.assertFalse(report["test_frames_included"])
            self.assertEqual(report["reviewed_sequences"], 1)

    def test_environment_pins_rights_clean_cycles_without_denoising(self) -> None:
        environment = load_json(Path(__file__).with_name("environment.json"))
        self.assertEqual(environment["blender"]["version"], "4.5.12")
        self.assertEqual(environment["cycles"]["device"], "METAL")
        self.assertFalse(environment["cycles"]["use_denoising"])
        self.assertFalse(environment["rights"]["external_art"])
        self.assertFalse(environment["rights"]["pretrained_weights"])

    def test_float_comparison_records_numeric_renderer_variation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            left = root / "left.f32"
            right = root / "right.f32"
            left.write_bytes(struct.pack("<3f", 0.0, 0.5, 1.0))
            right.write_bytes(struct.pack("<3f", 0.0, 0.5000001, 1.0))
            result = float_difference(left, right)
            self.assertEqual(result["value_count"], 3)
            self.assertEqual(result["changed_value_count"], 1)
            self.assertFalse(result["byte_identical"])
            self.assertGreater(result["max_absolute_error"], 0.0)

    def test_material_response_domains_fail_closed(self) -> None:
        package = frame_package()
        package["draws"][0]["material_response"]["roughness"] = 1.1
        with self.assertRaisesRegex(ValueError, "outside its declared domain"):
            validate_frame_package(package)

    def test_frame_global_controls_fail_closed_and_match_target_intent(self) -> None:
        package = frame_package()
        validate_frame_package(package)
        package["global_controls"]["sun_strength"] = -1.0
        with self.assertRaisesRegex(ValueError, "sun_strength is invalid"):
            validate_frame_package(package)
        package = frame_package()
        package["global_controls"]["local_light_strength"] = 21.0
        with self.assertRaisesRegex(ValueError, "disagrees with scene intent"):
            validate_frame_package(package)

    def test_rf10_material_ambiguity_verifier_requires_one_explicit_cause(self) -> None:
        from verify_rf10_corpus import verify_material_ambiguity

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reference = root / "reference"
            candidate = root / "candidate"
            for owner, palette, target_bytes in (
                (reference, 0.0, b"reference-target"),
                (candidate, 1.0, b"candidate-target"),
            ):
                frame_root = owner / "source/capture/frames"
                target_root = owner / "targets/frame-00000240"
                frame_root.mkdir(parents=True)
                target_root.mkdir(parents=True)
                atomic_json(
                    frame_root / "frame-00000240.json",
                    {
                        "input_size": [256, 144],
                        "paired_target_size": [1280, 720],
                        "camera": {"position": [1, 2, 3]},
                        "effects": {"seed": 0, "exposure": 1},
                        "global_controls": {"values": {
                            "sun_strength": 4.0,
                            "world_strength": 0.32,
                            "local_light_strength": 550.0,
                            "emissive_strength": 8.0,
                            "material_palette": palette,
                        }},
                        "channels": [
                            {"name": name, "raw_sha256": f"same-{name}"}
                            for name in CHANNELS
                        ],
                    },
                )
                (target_root / "target.exr").write_bytes(target_bytes)
            result = verify_material_ambiguity(reference, candidate)
            self.assertTrue(result["cheap_rasters_identical"])
            self.assertEqual(result["rich_targets_changed"], 1)

            frame = load_json(candidate / "source/capture/frames/frame-00000240.json")
            frame["global_controls"]["values"]["emissive_strength"] = 9.0
            atomic_json(candidate / "source/capture/frames/frame-00000240.json", frame)
            with self.assertRaisesRegex(ValueError, "changed emissive_strength"):
                verify_material_ambiguity(reference, candidate)

    def test_nr4_c_sequence_has_one_declared_cause_and_control_owner_per_segment(self) -> None:
        packages = sequence_packages()
        result = audit_packages(packages)
        self.assertEqual([record["segment"] for record in result["segments"]], list(SEGMENTS))
        self.assertEqual(len(packages), len(SEGMENTS) * SAMPLES_PER_SEGMENT)
        packages[1]["scene"]["world_strength"] += 0.1
        with self.assertRaisesRegex(ValueError, "lighting-change ownership"):
            audit_packages(packages)


if __name__ == "__main__":
    unittest.main()
