# Incident bundle schema 6

All paths are relative to the run folder. Every NDJSON line is one complete
schema-6 JSON object. The inspector rejects earlier schemas; there is no
fallback.

## Manifest and health

`manifest.json` is an atomic current snapshot refreshed while running, at
flags/finalization/handoffs, and shutdown. `running` means valid
partial-in-time evidence—not a stale startup zero. Check:

- source revision, dirty fingerprint, Zig/SDL/Jolt and protocol/replay/snapshot
  cohorts;
- `last_durable_sequence <= last_admitted_sequence`;
- queue/current/high-water/capacity, drops, writer failure, screenshot misses;
- `hardening_profile`, its optional exact writer cutoff, and screenshot fence
  failures for current bundles;
- total bytes equal `bytes_by_class` and stay under `run_budget_bytes`;
- `visual_budget_bytes + non_visual_reserve_bytes == run_budget_bytes`, visual
  reservations never exceed their lane, and rejection/exhaustion agree; and
- `replay_status` agrees with `replay/accepted-ingress.icrp`.

Visual admission pressure is intentionally distinct from writer failure. Once
the visual lane is full, new images are rejected and counted while typed
streams, markers, notes, replay, and handoff persistence retain a 128 MiB
reserve. `handoff_persisted=false` means clipboard text may still be available
in the running process but `LLM_HANDOFF.md` is not yet durable.
These fields are required in schema 6; a partial field set is invalid.

`hardening_profile=none` is an ordinary run. The five developer-only IC5-G
profiles deliberately finalize the run as `partial`:

- `queue_pressure`: queue reaches capacity, at least one probe is rejected,
  then replay and handoff persist after recovery;
- `visual_budget`: visual admission exhausts its configured lane while typed
  evidence, replay, and handoff retain their reserve;
- `writer_budget`: the writer cutoff is armed after all markers/windows and
  replay, so only the durable handoff and later records fail while clipboard
  publication remains available;
- `screenshot_submission`: capture submission is rejected before a fence; and
- `screenshot_fence`: submitted captures manufacture post-submission fence
  failure.

The strict inspector validates these exact combinations. They are acceptance
fixtures, not gameplay incidents. A real host volume is never filled merely to
manufacture ENOSPC.

Read `evidence_capabilities` before assigning a boundary. Current bundles
declare `full_boundary` separately for characters, NPCs, vehicles, and
carryables, plus semantic vehicle-part, atomic note/handoff, exact
navigation-lineage, authored-population, and deterministic-render-state
support. S14 bundles also declare `ranged_combat=true`. A
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

- `product_trail`: 15 FPS 480x270 product-only circular lane, approximately
  five seconds before through two seconds after the flag; overlapping flags
  reference the same run-level `visual/frame-*.ppm`.
- `human_visible`: anchors requested every whole second from -5000 through
  +2000 ms, including developer UI. Retina sources are stored aspect-fit within
  1280x720; `source_width`/`source_height` preserve the drawable size while
  `width`/`height` describe the PPM artifact.
- `product_flag`: product-only flag-adjacent frame.
- `semantic_id`: object-ID frame paired with `semantic-id-map.json`.

Filenames express requested anchors. Only index timestamps express actual
capture. `suspicious=true` means evidence needs comparison; it is not itself a
gameplay render diagnosis. The current producer marks large zero-filled
regions or a single quantized color occupying at least 75 percent of the frame;
the latter catches cameras embedded in bright world surfaces.

## Typed streams

`timeline`: gameplay/action traces, diagnostics, retained faults, anomaly
flags, and district lifecycle. `runtime_fault` records the immutable runtime
phase, authority tick, system/error name with explicit truncation, error code,
and linked diagnostic sequence. `authority_cycle_fault` records the immutable
cycle stage, target/completed ticks, and error name/code. Each appears at most
once per run and is materialized into every overlapping anomaly window.
District diagnostic code family `0x00090001..0x00090025` covers
content request/cancel/ready/failure, logical submit/admit/activate/cancel/
unload/failure, and GPU reserve/stage/submit/resident/release/drain.

Navigation gameplay traces use `action="navigation"` and retain semantic
destination ID, route/topology revision, route digest/cost/length, active
prefix, cursor index, and the complete bounded route nodes on transition
records. Interpret `reason` through the current navigation transition enum and
correlate the record with the same NPC stable identity and authority tick.
Fast route invalidation/replan cycles belong here, not in sampled state.

Authored-population gameplay traces use `action="population"` and are emitted
only on lifecycle or activity transitions. Their `population` object records
stable member ID, current actor generation, role and combat disposition,
program/cursor, activity kind/sequence, previous/current activity state,
site/slot, deadline, and spawn retry reason. The actor may be null while a
member is vacant or replacement-pending. Correlate replacement generations by
member ID rather than assuming one persistent actor exists forever.

Ranged-combat gameplay traces use `kind="firearm"`. Correlate one action by
actor namespace/local/incarnation and `correlation_id` (the weapon action
sequence). The record `reason` is the protocol disposition. The optional
`weapon` object retains action/mode enum values, magazine and reserve counts,
fire/reload deadlines, ray origin, impact position, applied damage, and killed
state. The target carries replicated identity plus incarnation when the
authority hit; health carries the resulting remaining health. A result record
and the room-wide shot event may share the same action sequence; later draw
records prove presentation submission rather than a second shot.

`state`: camera and entity samples. Presence values are `present`, `absent`, or
`unavailable`; never treat unavailable authority inspection as absent. Removed
entities remain five-second tombstones. Records include stable replicated and
durable `persistent_id` identity. `replication_removed` means the entity still
exists in authority but is absent from the local client projection; inspect
the typed relevance evidence before deciding whether this was intentional.
NPC relevance includes included flag,
reason (`full_world`, `same_district`, `encounter`, `proximity_enter`,
`proximity_retained`, `grace`, `excluded`), evaluation/grace tick, observer and
owner districts, observer position, distance squared, and encounter fact.
`full_world` is the deliberate current sandbox policy: every NPC in the
bounded evaluation cohort is published regardless of distance. The bounded
reasons remain available for a future explicitly selected scale policy.
Schema-6 NPC records also retain destination ID/name, navigation status and
reason, last plan trigger/result, route/topology revision, route digest,
cost/length/active prefix/index, replan count, optional arrival tick, temporary
physical-exclusion count, and retry tick. `waiting_for_content` means durable
intent is waiting on residency; `blocked` is a recoverable gate or confirmed
physical exclusion; `unreachable` is reserved for complete structural
disconnection. `arrived` is a semantic status, not disappearance permission.
Authored NPC records additionally retain `population_member`, role, combat
disposition, activity kind, and activity state. `unavailable` identifies a
synthetic/non-product NPC or a boundary without population projection; it is
not equivalent to a vacant authored member.
Vehicles and currently presentable carryables use a bounded cohort with reasons
`bounded_world`, `controlled`, or `held`; a carryable intentionally omitted
with its owning district is `district_dormant`. Their records also include the
authority evaluation tick, baseline ID, snapshot sequence, observer/object
position, districts, and distance squared.

`input`: semantic controls and explicit action edges plus only reserved
developer shortcut candidates. Shortcut stages are `received`, `matched`,
`queued`, and `applied`; records include SDL/window/focus/key/modifier/repeat
facts but no arbitrary text input. Weapon edges are
`weapon_toggle_pressed`, `fire_pressed`, and `reload_pressed`; the last retains
the ordinary alive-reload/dead-respawn input policy.

`metrics`: frame and recorder health plus screenshot cadence, memory, fence,
and one-second navigation aggregates for following/waiting/blocked/arrived/
structurally-unreachable NPCs, replans, exclusions, and route maxima.

`render_state` records in the state stream identify the conventional render
mode and visual schema, exact scene-light values, lit/unlit product and debug
draw counts, normal-bearing versus color-geometry counts, and the last stable
semantic class/part/ordinal/surface selected by presentation. These are sampled
contract facts, not authority state and not a substitute for the indexed
product/human/semantic images.

The semantic map has one object ID per draw. A vehicle chassis and its four
wheels deliberately have distinct object IDs mapped to the same stable vehicle
identity, so diagnose the vehicle as a group rather than expecting one entry.

## Replay and time vocabulary

`replay/accepted-ingress.icrp` contains cohort-bound accepted authority ingress,
district completion inputs, vitals commands including the firearm cause, and
per-tick category digests. Use the replay tool. Network weapon action identity
is also retained in the authority ingress journal and its stable fingerprint.

- `recorder_sequence`: projection order.
- `monotonic_ns`: same-process cross-stream time.
- `wall_unix_ms`: human correlation only.
- `authority_tick`: deterministic simulation order.
- `presentation_frame`: rendered submission order.
- source correlation/sequence: causal order within that owner.

## Vehicle frame motion (additive schema-6 capability)

When `evidence_capabilities.vehicle_frame_motion=true`, `vehicle_motion` and
`vehicle_wheel_motion` in state streams/window derivatives capture every
successfully submitted controlled-car frame. Correlate `entity` (the same
semantic namespace/local/incarnation used by entity-state and semantic IDs),
`persistent_id`, `authority_tick` and `presentation_frame`. Selection in an
anomaly marker need not identify the car being driven.

`raw_input` is the current held frame sample; `applied_input` is the actual last
physics-tick input after pedal resolution and steering conditioning. Multiple
physics ticks or no physics tick may occur in a frame. `authority`,
`replicated_pose`, `predicted_pose`, `presented_pose`, signed `forward_mps` /
`lateral_mps`, gear/RPM, camera pose/mode and prediction correction counters
localize the motion discrepancy. `presentation_source` identifies the active
path; solo records prediction as shadow evidence only. The interpolation pair
is `previous_snapshot_tick` / `snapshot_tick`; `latest_snapshot_tick` identifies
the independently recorded latest replication pose. `fixed_alpha` and
`snapshot_alpha` use those different clocks.

Four wheel records include actual Jolt-adapter pose, canonical spin/steer,
contact, suspension and slip, compact replicated values, and presented pose.
Compare timestamps before comparing positions: a normal 50 ms presentation
delay is not an alignment defect. Absence of this capability in older bundles
is a coverage limit, not evidence that motion was smooth. See
`docs/validation/vehicle-motion-audit.md` and `tools/vehicle_motion_report.py`.

## Vehicle control mapping 2 (EA2-H)

Current manifests and `semantic_input` records carry `input_mapping_version: 2`.
`space_down` is physical held Space; `driving` records occupancy context.
`jump_pressed`, `service_brake` (W+S) and `hand_brake` identify mapped actions.
Space holds the rear handbrake in a vehicle and remains a jump edge on foot.
S brakes forward motion before reverse; W brakes reverse motion before forward.
Opposite demand uses signed speed, horizontal speed and current gear so a
sideways skid cannot count as standstill. Resolved brake/throttle also appear in
`vehicle_motion.applied_input`; opposite-pedal service braking is resolved at
the authoritative tick, not inferred from a raw keyboard flag.

Graphical re-execution rejects missing/old mapping versions. Do not reinterpret
old Space/service-brake recordings. Current vehicle definitions use ICVEHDEF 2,
network protocol 21, snapshot 17, replay schema 21 and developer protocol 6.
`powertrain.center_limited_slip_ratio` is explicit; finite f32 maximum means
open center coupling. EA3 advances incident evidence to schema 6.

## EA3 authored lighting (incident 6, lighting 1)

The capability matrix declares `authored_lighting`, `lighting_schema=1` and
`lighting_asset_reconstruction`. `lighting_library` timeline events reference
SHA-256-addressed `lighting-assets/*.iclight` snapshots. Each file has the
ICLIGHTS v1 header, payload length and independent SHA-256 payload checksum.
`lighting_change` retains typed before/request/outcome/after state, source,
transaction and revisions. Full lighting edits use owned variable-length
records when they exceed the historical 4 KiB inline slot; they are not
truncated to that telemetry slot size. `lighting_frame` retains the active environment,
manual exposure, `reinhard_srgb` tone operator, `preexposed_once` convention,
shadow view count and caster submissions. `light_instance.resolved` retains
asset/member identity, revision, parent incarnation and exact presented pose,
emitter, mounted visual and emission binding. Inclusion is explicit:
`visual_content_absent`, `disabled` or `contributing_visual_frame`.

Replay loads the recorded lighting library at the recorded tick/frame; it
never substitutes the current library for missing lighting evidence. This
reconstructs lighting state, not arbitrary historical meshes/materials or GPU
timing. Keep the original matching installed content and source cohort.
