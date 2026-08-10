"""NR4-C deterministic sequence schedule and causal-state audit."""

from __future__ import annotations

import copy
from typing import Any


START_FRAME = 240
FRAME_STRIDE = 8
SAMPLES_PER_SEGMENT = 3
SEGMENTS = (
    "camera_motion",
    "object_motion",
    "near_edge",
    "wheel_articulation",
    "occlusion_disocclusion",
    "lighting_effect",
)
FRAME_COUNT = len(SEGMENTS) * SAMPLES_PER_SEGMENT
FRAMES = tuple(START_FRAME + index * FRAME_STRIDE for index in range(FRAME_COUNT))

EXPECTED_TRANSFORM_CHANGES = {
    "camera_motion": set(),
    "object_motion": {
        "vehicle-chassis",
        "vehicle-cabin",
        "wheel-front-left",
        "wheel-front-right",
        "wheel-rear-left",
        "wheel-rear-right",
    },
    "near_edge": set(),
    "wheel_articulation": {
        "wheel-front-left",
        "wheel-front-right",
        "wheel-rear-left",
        "wheel-rear-right",
    },
    "occlusion_disocclusion": {"npc"},
    "lighting_effect": set(),
}
EXPECTED_MATERIAL_CHANGES = {
    "camera_motion": set(),
    "object_motion": set(),
    "near_edge": set(),
    "wheel_articulation": set(),
    "occlusion_disocclusion": set(),
    "lighting_effect": {"emissive-sign", "lamp-head"},
}
CAMERA_SEGMENTS = {"camera_motion", "near_edge"}
EXPECTED_GLOBAL_CONTROL_CHANGES = {
    "camera_motion": set(),
    "object_motion": set(),
    "near_edge": set(),
    "wheel_articulation": set(),
    "occlusion_disocclusion": set(),
    "lighting_effect": {
        "sun_strength",
        "world_strength",
        "local_light_strength",
        "emissive_strength",
    },
}


def expected_event(index: int) -> dict[str, Any]:
    segment_index, sample_index = divmod(index, SAMPLES_PER_SEGMENT)
    return {
        "segment": SEGMENTS[segment_index],
        "segment_index": segment_index,
        "sample_index": sample_index,
        "progress": sample_index / (SAMPLES_PER_SEGMENT - 1),
        "reset": sample_index == 0,
    }


def _draws_by_label(package: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {draw["label"]: draw for draw in package["draws"]}


def _identity_state(draw: dict[str, Any]) -> dict[str, Any]:
    return {
        name: copy.deepcopy(draw[name])
        for name in (
            "label",
            "stable_key",
            "compact_rgb24",
            "semantic",
            "part",
            "ordinal",
            "identity",
            "shape",
            "material",
            "base_color",
        )
    }


def audit_packages(packages: list[dict[str, Any]]) -> dict[str, Any]:
    if len(packages) != FRAME_COUNT:
        raise ValueError(f"NR4-C requires {FRAME_COUNT} packages, got {len(packages)}")
    baseline_identity = [_identity_state(draw) for draw in packages[0]["draws"]]
    segments: list[dict[str, Any]] = []
    for index, package in enumerate(packages):
        expected = expected_event(index)
        event = package["sequence_event"]
        for name, value in expected.items():
            observed = event[name]
            if name == "progress":
                if abs(float(observed) - float(value)) > 1e-6:
                    raise ValueError(f"NR4-C frame {index} progress drifted: {observed} != {value}")
            elif observed != value:
                raise ValueError(f"NR4-C frame {index} event {name} drifted: {observed} != {value}")
        if package["presentation_frame"] != FRAMES[index]:
            raise ValueError("NR4-C presentation-frame schedule drifted")
        if [_identity_state(draw) for draw in package["draws"]] != baseline_identity:
            raise ValueError("NR4-C stable draw identity or authored membership drifted")

    for segment_index, segment in enumerate(SEGMENTS):
        offset = segment_index * SAMPLES_PER_SEGMENT
        reference = packages[offset]
        reference_draws = _draws_by_label(reference)
        comparisons = []
        for sample_index in range(1, SAMPLES_PER_SEGMENT):
            candidate = packages[offset + sample_index]
            candidate_draws = _draws_by_label(candidate)
            transform_changes = {
                label
                for label, draw in reference_draws.items()
                if draw["transform"] != candidate_draws[label]["transform"]
                or draw["model_matrix"] != candidate_draws[label]["model_matrix"]
            }
            material_changes = {
                label
                for label, draw in reference_draws.items()
                if draw["material_response"] != candidate_draws[label]["material_response"]
            }
            camera_changed = reference["camera"] != candidate["camera"]
            scene_changed = reference["scene"] != candidate["scene"]
            global_control_changes = {
                name
                for name in (
                    "sun_strength",
                    "world_strength",
                    "local_light_strength",
                    "emissive_strength",
                )
                if reference["global_controls"][name]
                != candidate["global_controls"][name]
            }
            if transform_changes != EXPECTED_TRANSFORM_CHANGES[segment]:
                raise ValueError(
                    f"NR4-C {segment} transform causes drifted: {sorted(transform_changes)}"
                )
            if material_changes != EXPECTED_MATERIAL_CHANGES[segment]:
                raise ValueError(
                    f"NR4-C {segment} material causes drifted: {sorted(material_changes)}"
                )
            if camera_changed != (segment in CAMERA_SEGMENTS):
                raise ValueError(f"NR4-C {segment} camera-change ownership drifted")
            if scene_changed != (segment == "lighting_effect"):
                raise ValueError(f"NR4-C {segment} lighting-change ownership drifted")
            if global_control_changes != EXPECTED_GLOBAL_CONTROL_CHANGES[segment]:
                raise ValueError(
                    f"NR4-C {segment} global-control ownership drifted: "
                    f"{sorted(global_control_changes)}"
                )
            comparisons.append(
                {
                    "sample_index": sample_index,
                    "camera_changed": camera_changed,
                    "scene_changed": scene_changed,
                    "transform_changes": sorted(transform_changes),
                    "material_response_changes": sorted(material_changes),
                    "global_control_changes": sorted(global_control_changes),
                }
            )
        segments.append(
            {
                "segment": segment,
                "controlled_change": reference["sequence_event"]["controlled_change"],
                "comparisons_to_sample_zero": comparisons,
            }
        )
    return {
        "schema": 1,
        "status": "complete",
        "purpose": "prove each NR4-C moving segment changes only its declared presentation owner",
        "frame_schedule": list(FRAMES),
        "segments": segments,
    }
