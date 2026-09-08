#!/usr/bin/env python3
"""Summarize full vehicle motion experiments or per-frame incident evidence.

Usage: python3 tools/vehicle_motion_report.py INPUT OUTPUT.json
INPUT is a --motion-audit JSON report, native NDJSON, or incident run folder.
The input is read-only. Full traces remain the source of truth.
"""
import json
import math
import pathlib
import sys


def frame_summary(rows):
    previous = None
    previous_identity = None
    frames = moving_subtick = frozen_draw = frozen_predictor = 0
    max_draw_step = max_authority_to_draw = 0.0
    modes = {}
    signed_min = signed_max = 0.0
    for row in rows:
        incident = row.get("kind") == "vehicle_motion"
        if "kind" in row and not incident:
            continue
        identity = row.get("entity")
        if identity != previous_identity:
            previous = None
        previous_identity = identity
        tick = row["authority_tick" if incident else "tick"]
        pose = row["presented_pose" if incident else "presented"]
        position = pose["position"]
        authority = row["authority"]["pose"]["position"]
        speed = row["forward_mps"]
        modes[row["camera_mode"]] = modes.get(row["camera_mode"], 0) + 1
        signed_min, signed_max = min(signed_min, speed), max(signed_max, speed)
        max_authority_to_draw = max(max_authority_to_draw, math.dist(authority, position))
        if previous is not None:
            prior_tick, prior_position, prior_prediction = previous
            max_draw_step = max(max_draw_step, math.dist(prior_position, position))
            if prior_tick == tick and abs(speed) > 1:
                moving_subtick += 1
                frozen_draw += position == prior_position
                if incident and row.get("predicted_pose") and prior_prediction:
                    frozen_predictor += row["predicted_pose"]["position"] == prior_prediction["position"]
        previous = tick, position, row.get("predicted_pose")
        frames += 1
    return dict(evidence_available=frames > 0, frames=frames, camera_modes=modes, minimum_forward_mps=signed_min,
                maximum_forward_mps=signed_max, moving_subtick_frames=moving_subtick,
                frozen_presented_subtick_frames=frozen_draw,
                frozen_shadow_predictor_subtick_frames=frozen_predictor,
                maximum_draw_step_m=max_draw_step,
                maximum_authority_to_draw_distance_m=max_authority_to_draw,
                interpretation=("Authority-to-draw distance includes intentional snapshot interpolation delay. Shadow prediction is observed but does not drive solo rendering. Native elapsed time is an injected cadence, not a performance benchmark." if frames else "No per-frame vehicle evidence. Zero counters do not establish smooth motion."))


def ndjson(paths):
    for path in paths:
        with path.open() as stream:
            for line in stream:
                yield json.loads(line)


def axle_phases(row, dt, wheelbase):
    """Contact-valid solver evidence, separated by the authored input segments."""
    phases = []
    offset = 0
    for segment in row["specification"]["segments"]:
        samples = row["samples"][offset:offset + segment["ticks"]]
        offset += segment["ticks"]
        phase = dict(input=segment["input"], samples=len(samples))
        if samples:
            phase["entry_mps"] = samples[0]["forward_mps"]
            phase["exit_mps"] = samples[-1]["forward_mps"]
            phase["peak_sideslip_deg"] = max(abs(s["sideslip_deg"] or 0) for s in samples)
            phase["final_sideslip_deg"] = samples[-1]["sideslip_deg"]
            moving = [s for s in samples if abs(s["forward_mps"]) > 1]
            if moving:
                phase["mean_abs_conditioned_steering"] = sum(abs(s["conditioned_steering"]) for s in moving) / len(moving)
                phase["mean_abs_front_steer_radians"] = sum(abs(s["authority"]["wheels"][i]["steer_angle"]) for s in moving for i in (0, 1)) / (2 * len(moving))
                phase["mean_abs_yaw_rate_rad_s"] = sum(abs(s["authority"]["chassis"]["velocity"]["angular"][1]) for s in moving) / len(moving)
                phase["mean_abs_path_curvature_per_m"] = sum(abs(s["authority"]["chassis"]["velocity"]["angular"][1]) / math.hypot(s["forward_mps"], s["lateral_mps"]) for s in moving) / len(moving)
                phase["mean_abs_kinematic_curvature_per_m"] = sum(abs(math.tan(sum(s["authority"]["wheels"][i]["steer_angle"] for i in (0, 1)) / 2)) / wheelbase for s in moving) / len(moving)
                # Steady-turn approximation; transient sideslip changes are retained in raw samples.
                phase["mean_abs_yaw_lateral_acceleration_mps2"] = sum(abs(s["forward_mps"] * s["authority"]["chassis"]["velocity"]["angular"][1]) for s in moving) / len(moving)

        for name, indices in (("front", (0, 1)), ("rear", (2, 3))):
            contacts = [(s, s["authority"]["wheels"][i]) for s in samples for i in indices
                        if s["authority"]["wheels"][i]["has_contact"]]
            moving = [(s, w) for s, w in contacts if abs(s["forward_mps"]) > 1]
            phase[name] = dict(contact_samples=len(contacts), moving_contact_samples=len(moving),
                locked_moving_samples=sum(abs(w["angular_velocity"]) < 0.001 for _, w in moving))
            if contacts:
                for field, label, scale in (("longitudinal_slip", "mean_longitudinal_slip", 1),
                    ("lateral_slip_radians", "mean_lateral_slip_deg", 180 / math.pi),
                    ("suspension_impulse_ns", "mean_estimated_load_n", 1 / dt),
                    ("longitudinal_impulse_ns", "mean_abs_longitudinal_force_n", 1 / dt),
                    ("lateral_impulse_ns", "mean_abs_lateral_force_n", 1 / dt)):
                    phase[name][label] = sum(abs(w[field]) * scale for _, w in contacts) / len(contacts)
                phase[name]["mean_signed_longitudinal_force_n"] = sum(w["longitudinal_impulse_ns"] / dt for _, w in contacts) / len(contacts)
                phase[name]["mean_abs_wheel_angular_speed_rad_s"] = sum(abs(w["angular_velocity"]) for _, w in contacts) / len(contacts)
        phases.append(phase)
    return phases


def summarize(path):
    if path.is_dir():
        return frame_summary(ndjson(sorted((path / "streams").glob("state-*.ndjson"))))
    if path.suffix == ".ndjson":
        return frame_summary(ndjson([path]))
    with path.open() as stream:
        report = json.load(stream)
    result = {key: value for key, value in report.items() if key != "results"}
    result["results"] = [{key: value for key, value in row.items() if key != "samples"}
                         for row in report["results"]]
    for source, summary in zip(report["results"], result["results"]):
        if "axle_phases" in source:
            continue
        summary["axle_phases"] = axle_phases(source, report["timestep_s"], abs(report["definition"]["tuning"]["wheel_attachment_positions"][0][2] - report["definition"]["tuning"]["wheel_attachment_positions"][2][2]))
    result["sample_count"] = sum(row.get("sample_count", len(row.get("samples", []))) for row in report["results"])
    return result


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    source, output = map(pathlib.Path, sys.argv[1:])
    if source.resolve() == output.resolve() or (source.is_dir() and output.resolve().is_relative_to(source.resolve())):
        raise SystemExit("Write the summary outside the source evidence.")
    with output.open("w") as stream:
        json.dump(summarize(source), stream, indent=2, allow_nan=False)
        stream.write("\n")
