#!/usr/bin/env python3
"""Validate and summarize an Incinerator schema-4 incident bundle."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

SCHEMA = 4
TERMINAL = {"complete", "partial"}
HUMAN_ANCHORS = {
    -5000: "human_m5000ms",
    -4000: "human_m4000ms",
    -3000: "human_m3000ms",
    -2000: "human_m2000ms",
    -1000: "human_m1000ms",
    0: "human_flag",
    1000: "human_p1000ms",
    2000: "human_p2000ms",
}


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"invalid JSON {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path}")
    return value


def read_ndjson(path: Path) -> list[dict]:
    records: list[dict] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise ValueError(f"cannot read {path}: {exc}") from exc
    for number, line in enumerate(lines, 1):
        if not line:
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValueError(f"invalid NDJSON {path}:{number}: {exc}") from exc
        if not isinstance(value, dict) or value.get("schema") != SCHEMA or not value.get("kind"):
            raise ValueError(f"invalid schema-{SCHEMA} record {path}:{number}")
        records.append(value)
    return records


def reduce_anomalies(records: list[dict]) -> dict[int, dict]:
    current: dict[int, dict] = {}
    for record in records:
        anomaly_id = int(record["anomaly_id"])
        event = record.get("event")
        lifecycle = record.get("lifecycle_status")
        previous = current.get(anomaly_id)
        if event == "flagged":
            if previous is not None or lifecycle != "capturing":
                raise ValueError(f"invalid flagged lifecycle for anomaly {anomaly_id}")
            current[anomaly_id] = dict(record)
        elif event == "note_updated":
            if previous is None or lifecycle != previous["lifecycle_status"]:
                raise ValueError(f"note changed lifecycle for anomaly {anomaly_id}")
            previous["note"] = record.get("note", "")
        elif event == "post_roll_finalized":
            if previous is None or previous["lifecycle_status"] != "capturing" or lifecycle not in TERMINAL:
                raise ValueError(f"invalid finalization for anomaly {anomaly_id}")
            previous["lifecycle_status"] = lifecycle
        elif event == "handoff_refreshed":
            if previous is None or lifecycle != previous["lifecycle_status"]:
                raise ValueError(f"invalid handoff lifecycle for anomaly {anomaly_id}")
        else:
            raise ValueError(f"unknown anomaly event {event!r}")
        current[anomaly_id]["updates"] = current[anomaly_id].get("updates", 0) + 1
    return current


def signed_delta_ms(value: int, origin: int) -> int:
    sign = 1 if value >= origin else -1
    return sign * (abs(value - origin) // 1_000_000)


def validate_hardening(
    manifest: dict,
    anomaly_count: int,
    replay_present: bool,
    handoff_present: bool,
) -> None:
    profile = manifest.get("hardening_profile")
    if not isinstance(profile, str):
        raise ValueError(f"schema-{SCHEMA} manifest lacks a hardening profile")
    if "screenshot_fence_failures" not in manifest:
        raise ValueError("hardening manifest lacks screenshot fence health")
    fence_failures = int(manifest["screenshot_fence_failures"])
    if profile == "none":
        if manifest.get("hardening_write_failure_after_bytes") is not None:
            raise ValueError("ordinary run declares a hardening writer cutoff")
        return
    if manifest.get("status") != "partial" or anomaly_count != 4:
        raise ValueError(f"invalid {profile} hardening lifecycle")
    writer_failed = bool(manifest.get("writer_failed"))
    handoff_persisted = bool(manifest.get("handoff_persisted"))
    if profile == "queue_pressure":
        valid = (
            int(manifest["queue_high_water"]) == int(manifest["writer_queue_capacity"])
            and int(manifest["dropped_records"]) > 0
            and not writer_failed
            and replay_present
            and handoff_present
            and handoff_persisted
            and fence_failures == 0
        )
    elif profile == "visual_budget":
        valid = (
            bool(manifest.get("visual_budget_exhausted"))
            and int(manifest.get("visual_budget_rejections", 0)) > 0
            and not writer_failed
            and replay_present
            and handoff_present
            and handoff_persisted
            and fence_failures == 0
        )
    elif profile == "writer_budget":
        valid = (
            manifest.get("hardening_write_failure_after_bytes") == manifest.get("bytes_written")
            and writer_failed
            and int(manifest["last_durable_sequence"]) < int(manifest["last_admitted_sequence"])
            and replay_present
            and not handoff_present
            and not handoff_persisted
            and fence_failures == 0
        )
    elif profile == "screenshot_submission":
        valid = (
            int(manifest["screenshot_misses"]) > 0
            and fence_failures == 0
            and not writer_failed
            and replay_present
            and handoff_present
            and handoff_persisted
        )
    elif profile == "screenshot_fence":
        valid = (
            int(manifest["screenshot_misses"]) > 0
            and fence_failures > 0
            and not writer_failed
            and replay_present
            and handoff_present
            and handoff_persisted
        )
    else:
        raise ValueError(f"unknown hardening profile: {profile!r}")
    if not valid:
        raise ValueError(f"invalid evidence contract for hardening profile {profile}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_folder", type=Path)
    args = parser.parse_args()
    root = args.run_folder.expanduser().resolve()
    if not root.is_dir():
        raise ValueError(f"run folder does not exist: {root}")

    manifest = read_json(root / "manifest.json")
    if manifest.get("schema") != SCHEMA or manifest.get("kind") != "incinerator_incident_run":
        raise ValueError(f"unsupported incident manifest; schema {SCHEMA} is required")
    classes = manifest.get("bytes_by_class", {})
    if sum(int(classes.get(key, 0)) for key in ("streams", "visual", "replay", "metadata")) != int(manifest["bytes_written"]):
        raise ValueError("manifest byte classes do not equal bytes_written")
    partition_keys = (
        "visual_budget_bytes",
        "non_visual_reserve_bytes",
        "visual_bytes_reserved",
        "visual_budget_rejections",
        "visual_budget_exhausted",
        "handoff_persisted",
    )
    partition_fields = sum(key in manifest for key in partition_keys)
    if partition_fields != len(partition_keys):
        raise ValueError("incomplete visual/non-visual budget partition")
    visual_budget = int(manifest.get("visual_budget_bytes", 0))
    non_visual_reserve = int(manifest.get("non_visual_reserve_bytes", 0))
    visual_reserved = int(manifest.get("visual_bytes_reserved", classes.get("visual", 0)))
    visual_rejections = int(manifest.get("visual_budget_rejections", 0))
    visual_exhausted = bool(manifest.get("visual_budget_exhausted", False))
    if visual_budget + non_visual_reserve != int(manifest["run_budget_bytes"]):
        raise ValueError("visual budget and non-visual reserve do not partition the run budget")
    if visual_reserved > visual_budget or int(classes.get("visual", 0)) > visual_reserved:
        raise ValueError("visual byte accounting exceeds its reserved budget")
    if visual_exhausted != (visual_rejections != 0):
        raise ValueError("visual budget exhaustion and rejection count disagree")
    if int(manifest["last_durable_sequence"]) > int(manifest["last_admitted_sequence"]):
        raise ValueError("durable sequence exceeds admitted sequence")

    live_bundle = manifest.get("status") == "running"
    anomaly_index = root / "anomalies.ndjson"
    if anomaly_index.exists():
        anomalies = reduce_anomalies(read_ndjson(anomaly_index))
    elif live_bundle and int(manifest.get("anomaly_count", 0)) == 0:
        anomalies = {}
    else:
        raise ValueError(f"missing anomaly index: {anomaly_index}")
    replay = root / "replay" / "accepted-ingress.icrp"
    handoff = root / "LLM_HANDOFF.md"
    validate_hardening(manifest, len(anomalies), replay.is_file(), handoff.is_file())
    stream_counts: dict[str, int] = {}
    kinds: dict[str, int] = {}
    for path in sorted((root / "streams").glob("*.ndjson")):
        records = read_ndjson(path)
        stream_counts[path.name] = len(records)
        for record in records:
            kind = str(record["kind"])
            kinds[kind] = kinds.get(kind, 0) + 1

    print(f"run: {root}")
    print(
        "health: "
        f"status={manifest.get('status')} hardening={manifest.get('hardening_profile')} "
        f"source={manifest.get('source_revision')} "
        f"dirty={manifest.get('source_dirty')} bytes={manifest.get('bytes_written')}/{manifest.get('run_budget_bytes')} "
        f"queue={manifest.get('writer_queue')} high={manifest.get('queue_high_water')}/{manifest.get('writer_queue_capacity')} "
        f"durable={manifest.get('last_durable_sequence')}/{manifest.get('last_admitted_sequence')} "
        f"dropped={manifest.get('dropped_records')} writer_failed={manifest.get('writer_failed')} "
        f"screenshot_misses={manifest.get('screenshot_misses')} "
        f"fence_failures={manifest.get('screenshot_fence_failures')} "
        f"visual_reserved={visual_reserved}/{visual_budget} "
        f"visual_rejected={visual_rejections} "
        f"handoff_persisted={manifest.get('handoff_persisted')}"
    )
    capabilities = manifest.get("evidence_capabilities")
    if not isinstance(capabilities, dict):
        raise ValueError("invalid evidence capability matrix")
    if capabilities.get("navigation_lineage") is not True:
        raise ValueError("schema-4 evidence lacks exact navigation lineage")
    print("capabilities: " + json.dumps(capabilities, sort_keys=True))
    print("streams: " + ", ".join(f"{name}={count}" for name, count in stream_counts.items()))
    print("record kinds: " + ", ".join(f"{name}={count}" for name, count in sorted(kinds.items())))
    print("anomalies:")
    for anomaly_id, reduced in sorted(anomalies.items()):
        folder = root / "anomalies" / f"anomaly-{anomaly_id:04d}"
        marker_path = folder / "marker.json"
        if not marker_path.exists():
            if live_bundle and reduced.get("lifecycle_status") == "capturing":
                print(
                    f"  #{anomaly_id} lifecycle=capturing tick={reduced.get('authority_tick')} "
                    f"frame={reduced.get('presentation_frame')} updates={reduced.get('updates')} "
                    "marker=pending (live partial-in-time)"
                )
                continue
            raise ValueError(f"missing anomaly marker: {marker_path}")
        marker = read_json(marker_path)
        if marker.get("schema") != SCHEMA or marker.get("kind") != "incident_marker":
            raise ValueError(f"invalid schema-{SCHEMA} marker for anomaly {anomaly_id}")
        if marker.get("lifecycle_status") != reduced.get("lifecycle_status"):
            raise ValueError(f"marker lifecycle mismatch for anomaly {anomaly_id}")
        windows = {}
        removals: dict[str, int] = {}
        removals_by_kind: dict[str, int] = {}
        relevance: dict[str, int] = {}
        entity_kinds: dict[str, int] = {}
        retained_faults: list[str] = []
        navigation_statuses: dict[str, int] = {}
        navigation_reasons: dict[str, int] = {}
        navigation_triggers: dict[str, int] = {}
        navigation_results: dict[str, int] = {}
        navigation_destinations: set[int] = set()
        navigation_route_revisions: set[int] = set()
        navigation_topology_revisions: set[int] = set()
        navigation_transition_count = 0
        navigation_max_replans = 0
        navigation_max_exclusions = 0
        for stream in ("timeline", "state", "input", "metrics"):
            records = read_ndjson(folder / f"{stream}-window.ndjson")
            windows[stream] = len(records)
            for record in records:
                if record.get("kind") == "runtime_fault":
                    retained_faults.append(
                        "runtime:"
                        f"{record.get('phase')}/"
                        f"{record.get('system')}/"
                        f"{record.get('error')}@{record.get('authority_tick')}"
                    )
                elif record.get("kind") == "authority_cycle_fault":
                    retained_faults.append(
                        "authority:"
                        f"{record.get('stage')}/"
                        f"{record.get('error')}@{record.get('target_tick')}"
                    )
                reason = record.get("removal_reason")
                if reason and reason != "none":
                    removals[str(reason)] = removals.get(str(reason), 0) + 1
                    entity_kind = str(record.get("entity_kind", "unknown"))
                    removal_key = f"{entity_kind}:{reason}"
                    removals_by_kind[removal_key] = removals_by_kind.get(removal_key, 0) + 1
                relevance_reason = record.get("relevance_reason")
                if relevance_reason and relevance_reason != "unavailable":
                    relevance[str(relevance_reason)] = relevance.get(str(relevance_reason), 0) + 1
                entity_kind = record.get("entity_kind")
                if entity_kind:
                    entity_kinds[str(entity_kind)] = entity_kinds.get(str(entity_kind), 0) + 1
                if record.get("action") == "navigation":
                    navigation_transition_count += 1
                    navigation = record.get("navigation")
                    if isinstance(navigation, dict):
                        destination = navigation.get("destination_id")
                        if destination is not None:
                            navigation_destinations.add(int(destination))
                        navigation_route_revisions.add(
                            int(navigation.get("route_revision", 0))
                        )
                        navigation_topology_revisions.add(
                            int(navigation.get("topology_revision", 0))
                        )
                if entity_kind == "npc":
                    status = str(record.get("navigation_status", "unavailable"))
                    reason = str(record.get("navigation_reason", "unavailable"))
                    trigger = str(record.get("navigation_trigger", "unavailable"))
                    result = str(record.get("navigation_result", "unavailable"))
                    if status != "unavailable":
                        navigation_statuses[status] = navigation_statuses.get(status, 0) + 1
                    if reason != "unavailable":
                        navigation_reasons[reason] = navigation_reasons.get(reason, 0) + 1
                    if trigger != "unavailable":
                        navigation_triggers[trigger] = navigation_triggers.get(trigger, 0) + 1
                    if result != "unavailable":
                        navigation_results[result] = navigation_results.get(result, 0) + 1
                    destination = record.get("navigation_destination")
                    if destination is not None:
                        navigation_destinations.add(int(destination))
                    navigation_route_revisions.add(
                        int(record.get("navigation_route_revision", 0))
                    )
                    navigation_topology_revisions.add(
                        int(record.get("navigation_topology_revision", 0))
                    )
                    navigation_max_replans = max(
                        navigation_max_replans,
                        int(record.get("navigation_replan_count", 0)),
                    )
                    navigation_max_exclusions = max(
                        navigation_max_exclusions,
                        int(record.get("navigation_physical_exclusion_count", 0)),
                    )
        visuals = read_ndjson(folder / "visual-index.ndjson") if (folder / "visual-index.ndjson").exists() else []
        suspicious = 0
        offsets: list[int] = []
        sources: dict[str, int] = {}
        human_requested: set[int] = set()
        for visual in visuals:
            actual = signed_delta_ms(int(visual["captured_monotonic_ns"]), int(marker["flag_monotonic_ns"]))
            if actual != int(visual["actual_offset_ms"]):
                raise ValueError(f"visual delta mismatch for anomaly {anomaly_id}")
            artifact = root / str(visual["path"])
            if not artifact.is_file():
                raise ValueError(f"missing visual artifact: {artifact}")
            offsets.append(actual)
            source = str(visual["source"])
            sources[source] = sources.get(source, 0) + 1
            if source == "human_visible":
                requested = int(visual["requested_offset_ms"])
                if requested not in HUMAN_ANCHORS or requested in human_requested:
                    raise ValueError(f"invalid human anchor offset for anomaly {anomaly_id}: {requested}")
                human_requested.add(requested)
            suspicious += int(bool(visual.get("suspicious")))
        artifacts = marker.get("artifacts", {})
        if len(visuals) != int(artifacts.get("count", 0)):
            raise ValueError(f"artifact count mismatch for anomaly {anomaly_id}")
        marker_human = {offset for offset, field in HUMAN_ANCHORS.items() if artifacts.get(field) is True}
        if human_requested != marker_human:
            raise ValueError(f"human anchor marker mismatch for anomaly {anomaly_id}")
        print(
            f"  #{anomaly_id} lifecycle={reduced.get('lifecycle_status')} tick={reduced.get('authority_tick')} "
            f"frame={reduced.get('presentation_frame')} updates={reduced.get('updates')} note={reduced.get('note')!r} "
            f"windows={windows} visuals={len(visuals)} sources={sources} "
            f"actual_span_ms={min(offsets) if offsets else None}..{max(offsets) if offsets else None} "
            f"suspicious={suspicious} failures={artifacts.get('failures')} "
            f"entity_kinds={entity_kinds} removals={removals} "
            f"removals_by_kind={removals_by_kind} relevance={relevance} "
            f"retained_faults={retained_faults} "
            f"navigation={{'transitions': {navigation_transition_count}, "
            f"'destinations': {sorted(navigation_destinations)}, "
            f"'route_revisions': {sorted(navigation_route_revisions)}, "
            f"'topology_revisions': {sorted(navigation_topology_revisions)}, "
            f"'statuses': {navigation_statuses}, 'reasons': {navigation_reasons}, "
            f"'triggers': {navigation_triggers}, 'results': {navigation_results}, "
            f"'max_replans': {navigation_max_replans}, "
            f"'max_exclusions': {navigation_max_exclusions}}}"
        )
    print(f"replay: {'present' if replay.is_file() else 'missing'}")
    print(f"handoff: {'present' if handoff.is_file() else 'missing'}")
    print("next:")
    print(f"  rg '\"removal_reason\":\"(relevance|replication_removed|authority_removed|presentation_removed)\"|\"relevance_reason\"' '{root}'")
    print(f"  rg '\"kind\":\"developer_shortcut\"' '{root / 'streams'}'")
    print(f"  zig build inspect-incident -- '{root}'")
    print(f"  zig build incident-visual-report -- '{root}' <new-output-folder>")
    print(f"  zig build replay-incident -- '{root}' <absolute-installed-content-root>")
    print(f"  zig build run -- --replay-incident='{root}'")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as exc:
        print(f"incident summary failed: {exc}", file=sys.stderr)
        raise SystemExit(2)
