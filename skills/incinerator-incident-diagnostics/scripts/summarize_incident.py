#!/usr/bin/env python3
"""Validate and summarize an Incinerator schema-2 incident bundle."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

SCHEMA = 2
TERMINAL = {"complete", "partial"}


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
            raise ValueError(f"invalid schema-2 record {path}:{number}")
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_folder", type=Path)
    args = parser.parse_args()
    root = args.run_folder.expanduser().resolve()
    if not root.is_dir():
        raise ValueError(f"run folder does not exist: {root}")

    manifest = read_json(root / "manifest.json")
    if manifest.get("schema") != SCHEMA or manifest.get("kind") != "incinerator_incident_run":
        raise ValueError("unsupported incident manifest; schema 2 is required")
    classes = manifest.get("bytes_by_class", {})
    if sum(int(classes.get(key, 0)) for key in ("streams", "visual", "replay", "metadata")) != int(manifest["bytes_written"]):
        raise ValueError("manifest byte classes do not equal bytes_written")
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
        f"status={manifest.get('status')} source={manifest.get('source_revision')} "
        f"dirty={manifest.get('source_dirty')} bytes={manifest.get('bytes_written')}/{manifest.get('run_budget_bytes')} "
        f"queue={manifest.get('writer_queue')} high={manifest.get('queue_high_water')}/{manifest.get('writer_queue_capacity')} "
        f"durable={manifest.get('last_durable_sequence')}/{manifest.get('last_admitted_sequence')} "
        f"dropped={manifest.get('dropped_records')} writer_failed={manifest.get('writer_failed')} "
        f"screenshot_misses={manifest.get('screenshot_misses')}"
    )
    capabilities = manifest.get("evidence_capabilities")
    if capabilities is None:
        print("capabilities: missing (bundle predates explicit per-entity coverage)")
    elif not isinstance(capabilities, dict):
        raise ValueError("invalid evidence capability matrix")
    else:
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
        if marker.get("lifecycle_status") != reduced.get("lifecycle_status"):
            raise ValueError(f"marker lifecycle mismatch for anomaly {anomaly_id}")
        windows = {}
        removals: dict[str, int] = {}
        removals_by_kind: dict[str, int] = {}
        relevance: dict[str, int] = {}
        entity_kinds: dict[str, int] = {}
        for stream in ("timeline", "state", "input", "metrics"):
            records = read_ndjson(folder / f"{stream}-window.ndjson")
            windows[stream] = len(records)
            for record in records:
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
        visuals = read_ndjson(folder / "visual-index.ndjson") if (folder / "visual-index.ndjson").exists() else []
        suspicious = 0
        offsets: list[int] = []
        sources: dict[str, int] = {}
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
            suspicious += int(bool(visual.get("suspicious")))
        artifacts = marker.get("artifacts", {})
        if len(visuals) != int(artifacts.get("count", 0)):
            raise ValueError(f"artifact count mismatch for anomaly {anomaly_id}")
        print(
            f"  #{anomaly_id} lifecycle={reduced.get('lifecycle_status')} tick={reduced.get('authority_tick')} "
            f"frame={reduced.get('presentation_frame')} updates={reduced.get('updates')} note={reduced.get('note')!r} "
            f"windows={windows} visuals={len(visuals)} sources={sources} "
            f"actual_span_ms={min(offsets) if offsets else None}..{max(offsets) if offsets else None} "
            f"suspicious={suspicious} failures={artifacts.get('failures')} "
            f"entity_kinds={entity_kinds} removals={removals} "
            f"removals_by_kind={removals_by_kind} relevance={relevance}"
        )
    replay = root / "replay" / "accepted-ingress.icrp"
    print(f"replay: {'present' if replay.is_file() else 'missing'}")
    print(f"handoff: {'present' if (root / 'LLM_HANDOFF.md').is_file() else 'missing'}")
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
