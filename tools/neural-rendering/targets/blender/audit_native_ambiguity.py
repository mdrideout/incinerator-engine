#!/usr/bin/env python3
"""Ablate frame-global controls against exact native NR4-C ambiguity."""

from __future__ import annotations

import argparse
from pathlib import Path

from compare_runs import image_difference
from inspect_sequence import inspect
from nr4_common import GLOBAL_CONTROL_ORDER, atomic_json, create_absent, load_json
from sequence_contract import SEGMENTS, SAMPLES_PER_SEGMENT


def channel_hashes(frame: dict) -> dict[str, str]:
    return {channel["name"]: channel["raw_sha256"] for channel in frame["channels"]}


def changed_components(
    reference_path: Path,
    reference: dict,
    candidate_path: Path,
    candidate: dict,
) -> dict[str, list[str]]:
    names = ("r", "g", "b", "a")
    reference_root = reference_path.parent.parent
    candidate_root = candidate_path.parent.parent
    reference_channels = {channel["name"]: channel for channel in reference["channels"]}
    candidate_channels = {channel["name"]: channel for channel in candidate["channels"]}
    result = {}
    for name, channel in reference_channels.items():
        left = (reference_root / channel["raw_path"]).read_bytes()
        right = (candidate_root / candidate_channels[name]["raw_path"]).read_bytes()
        if len(left) != len(right):
            raise ValueError("native ambiguity audit found a channel byte-count mismatch")
        components = [
            component
            for index, component in enumerate(names)
            if any(left[offset] != right[offset] for offset in range(index, len(left), 4))
        ]
        if components:
            result[name] = components
    return result


def target_state_changes(reference: dict, candidate: dict) -> list[str]:
    changes = []
    for name in ("camera", "scene", "exposure", "effect_seed"):
        if reference[name] != candidate[name]:
            changes.append(name)
    reference_draws = {draw["stable_key"]: draw for draw in reference["draws"]}
    candidate_draws = {draw["stable_key"]: draw for draw in candidate["draws"]}
    if reference_draws.keys() != candidate_draws.keys():
        changes.append("draw_membership")
        return changes
    if any(
        reference_draws[key]["transform"] != candidate_draws[key]["transform"]
        or reference_draws[key]["model_matrix"] != candidate_draws[key]["model_matrix"]
        for key in reference_draws
    ):
        changes.append("draw_transform")
    if any(
        reference_draws[key]["material_response"]
        != candidate_draws[key]["material_response"]
        for key in reference_draws
    ):
        changes.append("material_response")
    return changes


def changed_global_controls(reference: dict, candidate: dict) -> list[str]:
    return [
        name
        for name in GLOBAL_CONTROL_ORDER
        if reference["global_controls"][name] != candidate["global_controls"][name]
    ]


def audit(root: Path) -> dict:
    inspect(root)
    run = load_json(root / "run.json")
    sequence = load_json(root / run["sequence"]["manifest"])
    frames = sequence["frames"]
    records = []
    baseline_ambiguous_segments = set()
    candidate_ambiguous_segments = set()
    resolved_segments = set()
    for segment_index, segment in enumerate(SEGMENTS):
        offset = segment_index * SAMPLES_PER_SEGMENT
        reference_record = frames[offset]
        reference_capture_path = root / reference_record["capture_frame"]
        reference_capture = load_json(reference_capture_path)
        reference_package = load_json(root / reference_record["frame_package"])
        reference_target = root / reference_record["target_root"] / "target-display.png"
        comparisons = []
        for sample_index in range(1, SAMPLES_PER_SEGMENT):
            candidate_record = frames[offset + sample_index]
            candidate_capture_path = root / candidate_record["capture_frame"]
            candidate_capture = load_json(candidate_capture_path)
            candidate_package = load_json(root / candidate_record["frame_package"])
            candidate_target = root / candidate_record["target_root"] / "target-display.png"
            reference_hashes = channel_hashes(reference_capture)
            candidate_hashes = channel_hashes(candidate_capture)
            changed_channels = [
                name for name in reference_hashes if reference_hashes[name] != candidate_hashes[name]
            ]
            state_changes = target_state_changes(reference_package, candidate_package)
            component_changes = changed_components(
                reference_capture_path,
                reference_capture,
                candidate_capture_path,
                candidate_capture,
            )
            control_changes = changed_global_controls(reference_package, candidate_package)
            exact_input_equivalence = not changed_channels
            lighting_or_material_changed = bool(
                {"scene", "material_response"}.intersection(state_changes)
            )
            appearance_unchanged = "appearance" not in changed_channels
            only_temporal_side_effect_changed = set(changed_channels).issubset({"motion"})
            baseline_conditioning_ambiguity = bool(state_changes) and (
                exact_input_equivalence
                or (
                    lighting_or_material_changed
                    and appearance_unchanged
                    and only_temporal_side_effect_changed
                )
            )
            conditioning_ambiguity = baseline_conditioning_ambiguity and not control_changes
            if baseline_conditioning_ambiguity:
                baseline_ambiguous_segments.add(segment)
            if conditioning_ambiguity:
                candidate_ambiguous_segments.add(segment)
            if baseline_conditioning_ambiguity and control_changes:
                resolved_segments.add(segment)
            comparisons.append(
                {
                    "sample_index": sample_index,
                    "exact_input_equivalence": exact_input_equivalence,
                    "changed_input_channels": changed_channels,
                    "changed_input_components": component_changes,
                    "changed_global_controls": control_changes,
                    "declared_target_state_changes": state_changes,
                    "only_temporal_side_effect_changed": only_temporal_side_effect_changed,
                    "baseline_conditioning_ambiguity": baseline_conditioning_ambiguity,
                    "conditioning_ambiguity": conditioning_ambiguity,
                    "target_display_difference": image_difference(
                        reference_target, candidate_target
                    ),
                }
            )
        records.append({"segment": segment, "comparisons_to_sample_zero": comparisons})
    return {
        "schema": 2,
        "status": "complete",
        "phase": "NR4-C",
        "source_run": str(root),
        "input_extent": [160, 90],
        "target_extent": [640, 360],
        "method": "ablate the four presentation-owned frame-global float32 controls against exact native raw-channel/component hashes and declared target-package owners; a motion-only history side effect does not represent lighting/material conditioning; display differences are observations, not thresholds",
        "baseline_ambiguous_segments": sorted(baseline_ambiguous_segments),
        "ambiguous_segments": sorted(candidate_ambiguous_segments),
        "resolved_segments": sorted(resolved_segments),
        "global_controls_resolve_all_observed_ambiguity": not candidate_ambiguous_segments,
        "cost": {
            "scope": "four frame-global float32 values",
            "training_bytes_per_frame": 16,
            "additional_gpu_raster_targets": 0,
            "additional_gpu_raster_pixels": 0,
            "spatial_control_added": False,
        },
        "segments": records,
        "recommendation": {
            "disposition": "accept frame-global controls for this cohort when the candidate ambiguity set is empty",
            "next": "assemble the native corpus without a spatial illumination channel; revisit spatial visibility only after controlled-fit evidence demonstrates a remaining failure",
            "do_not_add_yet": "native or target-extent spatial lighting controls, material-ID channels, or a generic candidate-channel bundle without a separately observed failure",
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    output = create_absent(args.output.resolve(), "NR4-C global-control ablation root")
    result = audit(args.run.resolve())
    atomic_json(output / "control-ablation.json", result)
    print(output / "control-ablation.json")


if __name__ == "__main__":
    main()
