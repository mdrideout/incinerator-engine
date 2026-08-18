---
name: incinerator-incident-diagnostics
description: Inspect and diagnose schema-5 Incinerator Engine human-test incident folders containing live manifests, deterministic render state, stable authored-population identity and activity transitions, navigation route lineage, anomaly lifecycle events, materialized NDJSON windows, product and human-visible trailing images, semantic-ID evidence, shortcut delivery records, and accepted-ingress replay captures. Use when a tester supplies an incident folder or LLM handoff, flags a visual/gameplay/render/population/navigation/input anomaly, asks what happened near a timestamp, or asks to reproduce and verify a repair.
---

# Incinerator Incident Diagnostics

Treat the bundle as indexed evidence, not as proof by itself. Keep semantic
authority replay, best-effort graphical re-execution, and human perceptual
confirmation as separate claims. Never mutate the supplied run folder.

## Start

1. Resolve the absolute run folder and read `manifest.json`,
   `anomalies.ndjson`, and `LLM_HANDOFF.md` when present. A
   `hardening_profile=writer_budget` bundle intentionally proves that the
   clipboard can succeed while the durable handoff file is absent.
2. Run `python3 scripts/summarize_incident.py <run-folder>` from this skill
   directory. A running/partial manifest, loss, writer failure, suspicious
   image, missing artifact, or missing replay limits the conclusion.
3. From the engine repository run:

   ```sh
   zig build inspect-incident -- <run-folder>
   zig build replay-incident -- <run-folder> <absolute-installed-content-root>
   ```

   When a visual transition is difficult to scan, generate read-only PNG
   contact sheets outside the original bundle:

   ```sh
   zig build incident-visual-report -- <run-folder> <new-output-folder>
   ```

4. Read [references/schema.md](references/schema.md) before interpreting
   fields and [references/reproduction.md](references/reproduction.md) before
   claiming a repair.

## Reduce lifecycle before diagnosis

Do not select the last anomaly row blindly. Reduce `event` in order:

- `flagged` creates a `capturing` anomaly;
- `note_updated` changes the note without changing lifecycle;
- `post_roll_finalized` changes lifecycle to `complete` or `partial`; and
- `handoff_refreshed` does not change lifecycle.

`marker.json` must agree with the reduced lifecycle. Use its
`flag_monotonic_ns`, window bounds, authority tick, presentation frame, and
selected identity. A human flag is a reaction time, not necessarily symptom
time; inspect the entire -5/+2 second visual window and -15/+5 second typed
window.

## Correlate the anomaly

Read all four materialized windows. Prefer recorder sequence for projection
order, authority tick for simulation order, presentation frame for draw order,
and monotonic time for same-process cross-stream correlation. Wall time is for
the human handoff only.

- `timeline-window.ndjson`: action disposition, lifecycle, district streaming,
  diagnostic code, immutable `runtime_fault`/`authority_cycle_fault` ownership,
  correlation, spawn/despawn, authored-population/activity transitions,
  navigation route transitions, and anomaly flag.
- `state-window.ndjson`: tri-state authority/replication/presentation/draw
  membership, tombstones, relevance reason/facts, transforms, vitals,
  encounter state, stable population member/role/activity, separation,
  deterministic render state, and compact current navigation state.
- `input-window.ndjson`: semantic held state and explicit pressed edges, UI
  capture/minimize state, plus reserved-shortcut `received`, `matched`,
  `queued`, and `applied` stages.
- `metrics-window.ndjson`: frame time, recorder pressure/loss, visual memory,
  cadence, and fence failures.
- `visual-index.ndjson`: use actual capture time—not filename or mtime—to order
  product trail, human-visible anchors, product flag, and semantic-ID frame.

Search stable identity as namespace/local/incarnation. Search typed removal and
relevance reasons rather than inferring absence from a missing current draw.
For navigation, retain the semantic destination as intent and treat the route
as derived evidence. Correlate `route_revision`, `topology_revision`,
`trigger`, `result`, route digest/nodes, status/reason, owner district, and
temporary physical exclusions. Distinguish `waiting_for_content`, recoverable
runtime `blocked`, and structural `unreachable`; never infer one from lack of
motion alone.
For authored NPCs, use `population_member` as the stable logical identity and
correlate it with the current `persistent_id` plus actor generation. Search
`action="population"` for transition-only evidence. Interpret its reason
through the population transition enum and retain exact program, cursor,
activity kind/sequence, site/slot, deadline, and spawn retry reason. A
replacement may change actor identity while preserving the population member;
do not report that expected rebind as a duplicated or unrelated NPC.
For deterministic visual anomalies, search `kind="render_state"` and correlate
`render_mode`, `visual_schema`, scene light, draw-path counts, and
`last_visual` semantic/part/ordinal/surface with the actual visual-index frame.
`color_geometry=0` is expected for ordinary product solids; debug geometry may
use the exact unlit color path. Render state explains the selected contract,
not whether the resulting image is perceptually correct.
Read `manifest.json.evidence_capabilities` before assuming an entity kind has
full boundary or semantic-part coverage. For vehicles and carryables, follow
`persistent_id`, bounded-world interest, baseline/snapshot sequence, observer
and owner districts, and `replication_removed` tombstones. Multiple semantic
object IDs may intentionally map chassis/wheels to one stable vehicle identity.
Use the summarizer's `removals_by_kind` cross-tab; a room-wide removal total
without its entity kind can misattribute a hidden driver or dead NPC to the
vehicle being investigated.

## Assign the boundary

- Authority absent: authority/lifecycle ownership.
- Authority present and replication absent: interest/publication/client receipt.
- Replication present and presentation absent: presentation planning.
- Presentation present and draw absent: draw submission.
- Draw present but semantic ID absent: camera/frustum/depth/visibility.
- Semantic and product-only present but human-visible corrupt: final pass or
  capture adapter/UI composition.
- Reserved key `received` absent: macOS-to-SDL delivery; received but not
  matched/queued/applied: route stage named by the record.
- Loss, writer failure, suspicious/truncated image, or missing window: evidence
  failure; do not assign gameplay root cause from that gap. When
  `hardening_profile` is not `none`, first confirm the strict inspector accepts
  that exact manufactured loss; do not mistake an acceptance fixture for a
  user incident.
- A generic fatal diagnostic followed by a retained fault record: use the
  retained phase/system/error or authority stage as the owning failure
  boundary. If the retained record is absent, report the exact diagnostic
  limitation and request terminal evidence instead of guessing.
- An NPC navigation anomaly: assign destination intent to the NPC owner,
  immutable graph/residency to district content, authored gate state to the
  traversal owner, and confirmed segment obstruction to physical recovery.
  A transition without a matching route revision, or a revision without a
  transition record, is evidence failure.
- An authored activity anomaly: assign member lifecycle and exclusive slot
  claims to the population owner, destination execution to the NPC owner, and
  combat interruption/resume to the encounter boundary. Do not infer activity
  intent from the NPC's current position or route alone.
- A deterministic visual anomaly: assign semantic state/part extraction to
  presentation, material/light selection to sandbox composition, GPU path and
  submission to the renderer, and final UI composition to the developer host.

State observed facts, boundary inference, and remaining uncertainty separately.

## Reproduce and verify

Run semantic replay first. A match proves accepted authority ingress reproduces
logical digests for the recorded cohort. It does not prove GPU, OS, or public
network timing. Then run:

```sh
zig build run -- --replay-incident=<absolute-run-folder>
```

After a repair, add the smallest deterministic scenario/invariant, run focused
and inherited tests, rerun semantic replay, perform graphical re-execution,
capture a new Metal bundle, inspect actual visual timing and semantic mapping,
and request human confirmation when readability or visual continuity was the
complaint.

Maintainers can re-run the complete installed failure matrix with:

```sh
zig build verify-incident-hardening -Deditor=true --summary all
```

It runs queue, visual-budget, writer-budget, screenshot-submission, and
screenshot-fence profiles through the same full Metal gameplay journey.
