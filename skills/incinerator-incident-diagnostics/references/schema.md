# Incident bundle schema 2

All paths are relative to the run folder. Every NDJSON line is one complete
schema-2 JSON object. The inspector rejects schema 1; there is no fallback.

## Manifest and health

`manifest.json` is an atomic current snapshot refreshed while running, at
flags/finalization/handoffs, and shutdown. `running` means valid
partial-in-time evidence—not a stale startup zero. Check:

- source revision, dirty fingerprint, Zig/SDL/Jolt and protocol/replay/snapshot
  cohorts;
- `last_durable_sequence <= last_admitted_sequence`;
- queue/current/high-water/capacity, drops, writer failure, screenshot misses;
- total bytes equal `bytes_by_class` and stay under `run_budget_bytes`; and
- `replay_status` agrees with `replay/accepted-ingress.icrp`.

Read `evidence_capabilities` before assigning a boundary. Current bundles
declare `full_boundary` separately for characters, NPCs, vehicles, and
carryables, plus semantic vehicle-part and atomic note/handoff support. A
missing matrix means the bundle predates explicit coverage; report that limit.

## Anomaly lifecycle and marker

`anomalies.ndjson` is an event log. Reduce `flagged`, `note_updated`,
`post_roll_finalized`, and `handoff_refreshed`; `lifecycle_status` is separate
from event type. `marker.json` is the canonical reduced view. It declares
`capturing`, `complete`, or `partial`, -15/+5 second typed bounds, explicit
artifact booleans/count/failures, selected identity, semantic status, and note.

Each anomaly directory contains materialized `timeline`, `state`, `input`, and
`metrics` windows. They are bounded derivatives; original streams remain the
append-only evidence.

## Visual evidence

`visual-index.ndjson` is authoritative for image timing and source. It records
capture sequence, requested anchor, target/captured/submitted/completed/writer
times, actual flag offset, tick/frame, drawable generation, dimensions,
format, fence latency, digest, suspicious flag, and relative path.

Sources:

- `product_trail`: 30 FPS 480x270 product-only circular lane, approximately
  four seconds before through three seconds after the flag; overlapping flags
  reference the same run-level `visual/frame-*.ppm`.
- `human_visible`: full-resolution anchors requested at -2000, -1000, 0,
  +1000, and +3000 ms, including developer UI.
- `product_flag`: product-only flag-adjacent frame.
- `semantic_id`: object-ID frame paired with `semantic-id-map.json`.

Filenames express requested anchors. Only index timestamps express actual
capture. `suspicious=true` means evidence needs comparison; it is not itself a
gameplay render diagnosis.

## Typed streams

`timeline`: gameplay/action traces, diagnostics, anomaly flags, district
lifecycle. District diagnostic code family `0x00090001..0x00090025` covers
content request/cancel/ready/failure, logical submit/admit/activate/cancel/
unload/failure, and GPU reserve/stage/submit/resident/release/drain.

`state`: camera and entity samples. Presence values are `present`, `absent`, or
`unavailable`; never treat unavailable authority inspection as absent. Removed
entities remain five-second tombstones. Records include stable replicated and
durable `persistent_id` identity. `replication_removed` means the entity still
exists in authority but is absent from the local client projection; inspect
the typed relevance evidence before deciding whether this was intentional.
NPC relevance includes included flag,
reason (`same_district`, `encounter`, `proximity_enter`,
`proximity_retained`, `grace`, `excluded`), evaluation/grace tick, observer and
owner districts, observer position, distance squared, and encounter fact.
Vehicles and currently presentable carryables use a bounded cohort with reasons
`bounded_world`, `controlled`, or `held`; a carryable intentionally omitted
with its owning district is `district_dormant`. Their records also include the
authority evaluation tick, baseline ID, snapshot sequence, observer/object
position, districts, and distance squared.

`input`: semantic controls and explicit action edges plus only reserved
developer shortcut candidates. Shortcut stages are `received`, `matched`,
`queued`, and `applied`; records include SDL/window/focus/key/modifier/repeat
facts but no arbitrary text input.

`metrics`: frame and recorder health plus screenshot cadence, memory, and fence
metrics.

The semantic map has one object ID per draw. A vehicle chassis and its four
wheels deliberately have distinct object IDs mapped to the same stable vehicle
identity, so diagnose the vehicle as a group rather than expecting one entry.

## Replay and time vocabulary

`replay/accepted-ingress.icrp` contains cohort-bound accepted authority ingress,
district completion inputs, and per-tick category digests. Use the replay tool.

- `recorder_sequence`: projection order.
- `monotonic_ns`: same-process cross-stream time.
- `wall_unix_ms`: human correlation only.
- `authority_tick`: deterministic simulation order.
- `presentation_frame`: rendered submission order.
- source correlation/sequence: causal order within that owner.
