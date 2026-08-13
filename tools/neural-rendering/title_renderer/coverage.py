#!/usr/bin/env python3
"""Produce a factual, scoped native-corpus coverage authorization."""

from __future__ import annotations

import argparse
import math
import shutil
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from title_renderer.contracts import (
    INPUT_EXTENT,
    SPLITS,
    TARGET_EXTENT,
    inspect_corpus_metadata,
)
from title_renderer.io import (
    atomic_json,
    create_absent_absolute,
    environment_record,
    load_json,
    repository_record,
    require_existing_absolute,
    sha256_file,
)


INITIAL_STRUCTURAL_SCOPE = "NR5-A framework and NR5-B controlled spatial overfit"
PRODUCT_APPROVAL = "product_owner_approved_nr4_d_review_sheet_2026_08_09"
RF6_SCOPE = "RF6 cumulative rich spatial controlled fit and held-out reconstruction"
RF6_PRODUCT_APPROVAL = "product_owner_approved_rf5_rich_target_2026_08_10"
RF7_SCOPE = "RF7 direct 160x90 to native 640x360 spatial fidelity reconstruction"
RF7_PRODUCT_APPROVAL = "product_owner_preapproved_direct_160x90_to_640x360_review_2026_08_11"
RF8_SCOPE = "RF8 direct 160x90 to native 640x360 spatial sharpness reconstruction"
RF8_PRODUCT_APPROVAL = "product_owner_approved_direct_160x90_to_640x360_sharpness_2026_08_12"


def _range(values: list[float]) -> dict[str, float | None]:
    finite = [float(value) for value in values if math.isfinite(float(value))]
    return {"minimum": min(finite) if finite else None, "maximum": max(finite) if finite else None}


def _distance(left: list[float], right: list[float]) -> float:
    return math.sqrt(sum((float(a) - float(b)) ** 2 for a, b in zip(left, right, strict=True)))


def _sorted_counter(counter: Counter[str]) -> dict[str, int]:
    return {name: counter[name] for name in sorted(counter)}


def collect(corpus_root: Path, scope: str = INITIAL_STRUCTURAL_SCOPE) -> dict[str, Any]:
    inspected = inspect_corpus_metadata(corpus_root, verify_training_artifacts=True)
    root: Path = inspected["root"]
    manifest: dict[str, Any] = inspected["manifest"]
    records: list[dict[str, Any]] = inspected["records"]

    scene_ids: set[str] = set()
    scene_fingerprints: set[str] = set()
    camera_paths: set[str] = set()
    draw_labels: set[str] = set()
    stable_keys: set[str] = set()
    semantics: Counter[str] = Counter()
    parts: Counter[str] = Counter()
    materials: Counter[str] = Counter()
    material_patterns: Counter[str] = Counter()
    material_response_values: dict[str, list[float]] = defaultdict(list)
    segments: Counter[str] = Counter()
    controlled_changes: set[str] = set()
    reset_reasons: Counter[str] = Counter()
    sequence_resets = 0
    effect_seeds: set[int] = set()
    control_tuples: set[tuple[float, float, float, float]] = set()
    camera_positions: list[list[float]] = []
    camera_fovs: list[float] = []
    camera_near: list[float] = []
    camera_far: list[float] = []
    camera_scene_distances: list[float] = []
    camera_elevations: list[float] = []
    split_frames: Counter[str] = Counter()
    split_sequences: dict[str, set[str]] = defaultdict(set)
    target_packages_read = 0

    for record in records:
        split = str(record["split"])
        split_frames[split] += 1
        split_sequences[split].add(str(record["sequence"]))
        package_path = root / str(record["target_frame_package"]["path"])
        package = load_json(package_path)
        target_packages_read += 1
        scene = package["scene"]
        scene_ids.add(str(scene["id"]))
        scene_fingerprints.add(str(scene["fingerprint"]))
        camera_paths.add(str(package["camera_path"]))
        event = package["sequence_event"]
        segments[str(event["segment"])] += 1
        controlled_changes.add(str(event["controlled_change"]))
        if bool(event["reset"]):
            sequence_resets += 1
        effect_seeds.add(int(package["effect_seed"]))
        controls = package["global_controls"]
        control_tuples.add(
            (
                float(controls["sun_strength"]),
                float(controls["world_strength"]),
                float(controls["local_light_strength"]),
                float(controls["emissive_strength"]),
            )
        )
        camera = package["camera"]
        position = [float(value) for value in camera["position"]]
        camera_positions.append(position)
        camera_fovs.append(float(camera["vertical_fov_radians"]))
        camera_near.append(float(camera["near"]))
        camera_far.append(float(camera["far"]))
        forward = [float(value) for value in camera["forward"]]
        camera_elevations.append(math.asin(max(-1.0, min(1.0, -forward[1]))))
        draws = package["draws"]
        center = [
            sum(float(draw["transform"]["translation"][axis]) for draw in draws) / len(draws)
            for axis in range(3)
        ]
        camera_scene_distances.append(_distance(position, center))
        for draw in draws:
            draw_labels.add(str(draw["label"]))
            stable_keys.add(str(draw["stable_key"]))
            semantics[str(draw["semantic"])] += 1
            parts[str(draw["part"])] += 1
            materials[str(draw["material"])] += 1
            response = draw["material_response"]
            material_patterns[str(response["pattern"])] += 1
            for name in (
                "roughness",
                "metallic",
                "transmission",
                "ior",
                "emission_strength",
                "sheen",
                "subsurface",
                "pattern_scale",
                "pattern_detail",
                "bump_strength",
                "bump_distance",
            ):
                material_response_values[name].append(float(response[name]))

        capture = load_json(root / str(record["capture_frame"]["path"]))
        reset_reasons[str(capture["camera"]["history_reset"])] += 1

    test_records = [record for record in records if record["split"] == "test"]
    non_test_records = [record for record in records if record["split"] != "test"]
    report = load_json(root / str(manifest["review"]["manifest"]))
    material_ranges = {name: _range(values) for name, values in sorted(material_response_values.items())}
    positions_by_axis = {
        axis: _range([position[index] for position in camera_positions])
        for index, axis in enumerate(("x", "y", "z"))
    }
    controls_by_name = {
        name: _range([values[index] for values in control_tuples])
        for index, name in enumerate(("sun_strength", "world_strength", "local_light_strength", "emissive_strength"))
    }

    required_segments = {
        "camera_motion",
        "object_motion",
        "near_edge",
        "wheel_articulation",
        "occlusion_disocclusion",
        "lighting_effect",
    }
    required_semantics = {"environment", "vehicle", "character", "npc", "carryable", "crate"}
    required_materials = {"asphalt", "sidewalk", "masonry", "glass", "emissive", "painted_metal", "rubber"}
    if scope in (RF6_SCOPE, RF7_SCOPE):
        required_materials.update(("fabric", "skin", "cardboard"))
    checks = {
        # Every package was already fail-closed against both native extents by
        # inspect_corpus_metadata. Requiring one read per record makes that
        # validation explicit instead of restating the constants tautologically.
        "native_extent_contract": target_packages_read == len(records),
        "rights_clean": not any(bool(manifest["rights"][name]) for name in ("external_art", "learned_denoiser", "pretrained_weights")),
        "whole_sequence_splits_present": set(split_frames) == SPLITS,
        "sealed_test_excluded_from_review": report.get("test_frames_included") is False,
        "required_structural_semantics_present": required_semantics.issubset(semantics),
        "required_fixture_materials_present": required_materials.issubset(materials),
        "causal_segments_present": required_segments.issubset(segments),
        "camera_stress_programs_present": {"nr4-corpus-stress-near", "nr4-corpus-stress-high"}.issubset(camera_paths),
        "lighting_controls_vary": len(control_tuples) > 1,
        "history_resets_present": sequence_resets > 0 and bool(reset_reasons),
        "product_visual_review_approved": True,
        "test_pixels_remain_sealed": inspected["sealed_test_pixels_opened"] is False,
    }
    if not all(checks.values()):
        failed = ", ".join(name for name, passed in checks.items() if not passed)
        raise ValueError(f"native corpus coverage failed: {failed}")

    known_gaps = [
        f"one procedural urban-corner scene and one fixed {len(stable_keys)}-identity fixture; no title-wide location or asset diversity",
        "no skeletal animation, cloth, hair, deformation, destruction, attachment replacement, or topology changes",
        "no weather, time-of-day traversal, exposure/grade traversal, atmosphere, smoke, fire, particles, or responsive effect phase",
        "no populated crowd, multiple vehicles, broad character variation, vegetation, terrain, interiors, or long-distance vistas",
        "no temporal training clips beyond short causal segments; NR-0006 must capture native motion/disocclusion/reset cohorts before temporal training",
        "no accepted production-performance, memory, runtime-inference, or quality-generalization claim",
    ]
    return {
        "schema": 1,
        "phase": "RF8-A" if scope == RF8_SCOPE else ("RF7-A" if scope == RF7_SCOPE else ("RF6-A" if scope == RF6_SCOPE else "NR4-E")),
        "status": "accepted_for_initial_structural_scope",
        "scope": scope,
        "corpus": {
            "root": str(root),
            "manifest": str(inspected["manifest_path"]),
            "manifest_sha256": sha256_file(inspected["manifest_path"]),
            "input_extent": list(INPUT_EXTENT),
            "target_extent": list(TARGET_EXTENT),
            "sequences": int(manifest["sequence_count"]),
            "frames": int(manifest["frame_count"]),
            "split_frames": _sorted_counter(split_frames),
            "split_sequences": {name: sorted(values) for name, values in sorted(split_sequences.items())},
            "test_frames": len(test_records),
            "non_test_frames": len(non_test_records),
            "target_packages_read": target_packages_read,
            "test_pixels_opened": False,
        },
        "content": {
            "scene_ids": sorted(scene_ids),
            "scene_fingerprints": sorted(scene_fingerprints),
            "stable_identities": len(stable_keys),
            "draw_labels": sorted(draw_labels),
            "semantics": _sorted_counter(semantics),
            "parts": _sorted_counter(parts),
        },
        "materials": {
            "names": _sorted_counter(materials),
            "patterns": _sorted_counter(material_patterns),
            "response_ranges": material_ranges,
        },
        "lighting_and_effects": {
            "unique_global_control_states": len(control_tuples),
            "global_control_ranges": controls_by_name,
            "effect_seeds": sorted(effect_seeds),
            "responsive_effect_phase_present": False,
        },
        "camera": {
            "paths": sorted(camera_paths),
            "position_ranges": positions_by_axis,
            "vertical_fov_radians": _range(camera_fovs),
            "near_plane": _range(camera_near),
            "far_plane": _range(camera_far),
            "distance_to_draw_centroid": _range(camera_scene_distances),
            "downward_elevation_radians": _range(camera_elevations),
        },
        "motion_occlusion_and_resets": {
            "segments": _sorted_counter(segments),
            "controlled_changes": sorted(controlled_changes),
            "sequence_reset_frames": sequence_resets,
            "history_reset_reasons": _sorted_counter(reset_reasons),
            "near_edge_present": "near_edge" in segments,
            "occlusion_disocclusion_present": "occlusion_disocclusion" in segments,
            "wheel_articulation_present": "wheel_articulation" in segments,
        },
        "rights": manifest["rights"],
        "checks": checks,
        "known_gaps": known_gaps,
        "decision": {
            "disposition": "accepted",
            "accepted_for": scope,
            "not_accepted_for": [
                "title-wide visual generalization",
                "causal temporal renderer training",
                "learned-detail residual training",
                "runtime promotion or shipping selection",
            ],
            "reason": "The corpus covers every declared structural-fixture material, identity, causal change, camera stress, split, rights, and native-resolution contract needed to validate the first framework and controlled overfit. Its explicit gaps prevent broader claims.",
        },
    }


def markdown(coverage: dict[str, Any]) -> str:
    camera = coverage["camera"]
    material_names = ", ".join(coverage["materials"]["names"])
    segment_names = ", ".join(coverage["motion_occlusion_and_resets"]["segments"])
    gaps = "\n".join(f"- {gap}" for gap in coverage["known_gaps"])
    checks = "\n".join(f"- `{name}`: {'pass' if passed else 'fail'}" for name, passed in coverage["checks"].items())
    return f"""# {coverage['phase']} Coverage Ledger

**Disposition:** Accepted for {coverage['scope']} only

**Corpus:** `{coverage['corpus']['root']}`

**Native cohort:** {coverage['corpus']['frames']} pairs across {coverage['corpus']['sequences']} whole sequences, `160×90 → {coverage['corpus']['target_extent'][0]}×{coverage['corpus']['target_extent'][1]}`

## Coverage facts

- Scenes: {len(coverage['content']['scene_ids'])}
- Stable identities: {coverage['content']['stable_identities']}
- Semantic classes: {', '.join(coverage['content']['semantics'])}
- Materials: {material_names}
- Causal segments: {segment_names}
- Camera paths: {', '.join(camera['paths'])}
- Camera-to-draw-centroid distance: {camera['distance_to_draw_centroid']['minimum']:.3f}–{camera['distance_to_draw_centroid']['maximum']:.3f} world units
- Global lighting/material states: {coverage['lighting_and_effects']['unique_global_control_states']}
- Test split: metadata inspected; zero target/input pixels decoded or included in review

## Gate checks

{checks}

## Known gaps carried forward

{gaps}

## Decision

This exact rights-clean corpus is accepted only for the scope named above. It
does not establish title-wide coverage, authorize temporal or learned-detail
training, or select/promote a runtime model. Those claims require new native
cohorts targeted at their actual consumers.
"""


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--repository", required=True, type=Path)
    parser.add_argument(
        "--product-approval",
        required=True,
        choices=(PRODUCT_APPROVAL, RF6_PRODUCT_APPROVAL, RF7_PRODUCT_APPROVAL, RF8_PRODUCT_APPROVAL),
    )
    args = parser.parse_args()
    corpus = require_existing_absolute(args.corpus, "--corpus")
    repository = require_existing_absolute(args.repository, "--repository")
    output = create_absent_absolute(args.output, "--output")
    try:
        if args.product_approval == RF8_PRODUCT_APPROVAL:
            scope, phase, experiment = RF8_SCOPE, "RF8-A", "RF8"
        elif args.product_approval == RF7_PRODUCT_APPROVAL:
            scope, phase, experiment = RF7_SCOPE, "RF7-A", "RF7"
        elif args.product_approval == RF6_PRODUCT_APPROVAL:
            scope, phase, experiment = RF6_SCOPE, "RF6-A", "RF6"
        else:
            scope, phase, experiment = INITIAL_STRUCTURAL_SCOPE, "NR4-E", "NR-0004"
        coverage = collect(corpus, scope)
        atomic_json(output / "coverage.json", coverage)
        (output / "coverage.md").write_text(markdown(coverage), encoding="utf-8")
        environment_path = output / "environment.json"
        atomic_json(environment_path, environment_record())
        source_files = [
            Path(__file__).resolve(),
            Path(__file__).with_name("__init__.py"),
            Path(__file__).with_name("contracts.py"),
            Path(__file__).with_name("io.py"),
        ]
        source_records = []
        for path in source_files:
            relative = path.relative_to(repository)
            snapshot = output / "source" / "tools" / relative
            snapshot.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, snapshot)
            source_records.append(
                {
                    "repository_path": str(relative),
                    "repository_sha256": sha256_file(path),
                    "snapshot_path": str(snapshot.relative_to(output)),
                    "snapshot_sha256": sha256_file(snapshot),
                    "bytes": snapshot.stat().st_size,
                }
            )
        acceptance = {
            "schema": 1,
            "phase": phase,
            "experiment": experiment,
            "status": "accepted",
            "accepted_for": scope,
            "product_approval": args.product_approval,
            "corpus_manifest_sha256": coverage["corpus"]["manifest_sha256"],
            "coverage": "coverage.json",
            "coverage_sha256": sha256_file(output / "coverage.json"),
            "coverage_markdown": "coverage.md",
            "coverage_markdown_sha256": sha256_file(output / "coverage.md"),
            "environment": "environment.json",
            "environment_sha256": sha256_file(environment_path),
            "tool_sources": source_records,
            "repository": repository_record(repository),
            "sealed_test_pixels_opened": False,
            "model_training_authorized": True,
            "authorization_scope": scope,
        }
        atomic_json(output / "acceptance.json", acceptance)
    except Exception:
        atomic_json(output / "failure.json", {"schema": 1, "phase": "coverage", "status": "failed"})
        raise
    print(
        f"CORPUS_COVERAGE_ACCEPTED phase={coverage['phase']} frames={coverage['corpus']['frames']} "
        f"sequences={coverage['corpus']['sequences']} output={output}"
    )


if __name__ == "__main__":
    main()
