# Gameplay Interaction Validation And Observability

**Status:** Complete

**Date:** 2026-07-15

**Platform:** Apple Silicon macOS; secondary platforms remain deferred

**Decision:**
[`../adr/020-gameplay-interaction-validation-and-observability.md`](../adr/020-gameplay-interaction-validation-and-observability.md)

**Evidence:**
[`../validation/gameplay-interaction-validation-and-observability.md`](../validation/gameplay-interaction-validation-and-observability.md)

## Outcome

Make complete gameplay journeys deterministic, scriptable, causally
inspectable, continuously validated, and selectively visible at the GPU. The
first proof is the normal-product hostile NPC approach, contact, attack, death,
and respawn journey that exposed the gap.

This program does not add a generic automation service, remote telemetry
platform, scripting VM, cross-platform abstraction, or new gameplay feature.

## Baseline Findings

- The repository has hundreds of Zig tests and broad headless/process/Metal
  gates, but the graphical scenario enum contains only hard-coded phase
  scripts.
- S11 proves eventual combat and draw-plan observations; it does not enforce
  continuous visibility, identity, separation, camera safety, or pixel
  occupancy.
- The normal product deliberately despawns the physical avatar after death and
  retains a world-space HUD anchor. Geometric-only markers make this look like
  a partial rendering failure.
- Player and NPC controllers are Jolt `CharacterVirtual` instances without a
  registered character-vs-character collision owner or inner body. Encounter
  pursuit targets the player position, so close-range overlap is possible.
- Renderer extraction submits every projected character and NPC; no proximity
  culling policy explains the symptom.
- Existing developer diagnostics expose aggregates and faults, not an ordered
  selected-entity action/state/presentation timeline.
- Ordinary recoverable input submission failures may be consumed without a
  player-facing result or gameplay-trace record.

These are the preserved pre-correction findings. The accepted implementation
now separates physical-controller lifetime from visible death lifetime: a
replicated, noninteractive death proxy remains at the last authoritative pose
until respawn. A later human trace also exposed ambiguous drop rejection data;
the current schema and product feedback contract below supersede the original
unnamespaced numeric reason.

## Shared Scenario Model

The first implementation remains concrete and fixed-capacity.

```zig
pub const Scenario = struct {
    name: []const u8,
    seed: u64,
    fixture: Fixture,
    steps: []const Step,
    invariants: []const Invariant,
    deadline_ticks: u64,
};

pub const Step = union(enum) {
    await: Predicate,
    press: Action,
    hold: Hold,
    release: Action,
    checkpoint: Checkpoint,
};
```

The runner advances a fixed tick, samples immutable observations, evaluates
continuous invariants, then advances scenario state. Adapters translate the
same semantic action and observation contracts to the local simulation,
embedded session, graphical presentation, or installed process.

The initial scenario set is intentionally small:

- `character_blocker_and_facing`;
- `vehicle_drive_wheel_and_exit`;
- `carry_collect_drop`; and
- `hostile_npc_approach_contact_death_respawn`.

Fault, reconnect, topology, fuzz, and soak adapters execute that same hostile
scenario contract. They are execution profiles, not duplicate scenario names.

## Gameplay Trace Contract

The trace is a fixed-capacity transition journal. Required record fields:

- monotonic trace sequence;
- authority tick and optional presentation frame;
- topology/session and scenario correlation;
- actor and optional target identities/incarnations;
- action correlation/sequence;
- stage, kind, disposition/reason;
- optional position, health/life, encounter state, cooldown, and visibility
  sample; and
- owner/source role.

The trace exposes occupancy, high-water, overwritten, frozen, and dropped
counters. It freezes on the first scenario invariant failure and can be
exported without giving the editor mutable authority access.

JSON schema 2 includes `reason_domain` on every record. Numeric reasons are not
self-describing without this namespace: `.error_code` is a Zig error value,
`.protocol_disposition` is the action-specific wire enum, and
`.validation_code` belongs to scenario validation. Analog movement samples are
coalesced by semantic thresholds; presentation emits membership, health, life,
and disappearance transitions rather than transform noise every frame.

## IV0 Contact Decision

The authoritative safety boundary is one Physics-owned Jolt
`CharacterVsCharacterCollisionSimple` registry shared by every
`CharacterVirtual` in that world. Creation registers a controller only after
native construction succeeds; destruction removes it before releasing the
native controller; world teardown requires an empty registry.

This preserves the existing player and NPC controller capability, stable
handles, save/replay reconstruction, and zero proxy-body budget. It also makes
contact filtering one adapter responsibility rather than duplicated player/NPC
policy. Jolt's simple registry is owner-thread-only and brute-force. The
accepted current cohort is at most 65 controllers (one player plus 64 NPCs);
IV2 must measure this exact worst case before a spatial registry can be
justified.

AI pursuit still owns pleasant approach/stand-off behavior. The collision
registry is the non-penetration safety net under opposing input, spawn,
reconnect, or AI failure; it is not the steering system.

## Required Invariants

### Authority and lifecycle

- alive player and NPC identities are unique and stable;
- death and respawn transitions are exactly correlated;
- absence of a physical avatar requires a dead/spawning participant state;
- damage, death, despawn, respawn cooldown, spawn, and new incarnation occur in
  the declared order.

### Contact and movement

- player/NPC penetration remains below the accepted tolerance;
- collision/avoidance cannot push actors through blockers;
- NPC pursuit stops at an authored combat stand-off rather than the target
  center;
- facing remains finite and points toward the declared semantic target within
  tolerance.

### Replication and presentation

- a living relevant NPC has zero unexplained projection gaps;
- a living local avatar has zero unexplained presentation gaps;
- interpolation never crosses a non-finite or unbounded pose;
- life and encounter transitions appear within a declared bounded latency.

### Camera and GPU

- camera near plane and position remain outside protected actor volumes;
- declared observable entities have a checkpoint-specific meaningful
  object-ID footprint, not merely one surviving edge pixel;
- selected entities remain within expected screen bounds during checkpoints;
- a dead participant remains visibly represented by a noninteractive death
  proxy until explicit respawn replaces it;
- presentation absence is a semantic trace transition and must match a known
  despawn, relevance, or replacement cause.

### Actions

- every discrete action has one terminal disposition;
- ignored or recoverable outcomes are trace-visible;
- action cooldown and rejection state is player-visible when it affects the
  requested action.

## Developer Gameplay Inspector

The editor adds one read-only tool with:

- entity selection by local player, replicated ID, or persistent ID;
- current authority, replication, presentation, and visibility observations;
- target and encounter state with deadlines;
- health, life, action cooldowns, and last disposition;
- position, velocity, controller dimensions, and nearest actor separation;
- chronological trace filtering by entity/correlation;
- freeze, resume, clear, and export requests through the existing developer
  control boundary; and
- optional scenario pause/step/checkpoint controls in validation products.

## Product Feedback Contract

The normal product uses readable screen-space text/geometry for:

- local health;
- received damage and death;
- hostile attack windup;
- respawn countdown and explicit input instruction;
- action cooldown; and
- ordinary action rejection when the user can reasonably act on it.

Authority rejections retain their action-specific protocol disposition through
the product projection. The always-visible HUD therefore reports concrete text
such as `destination_unavailable`, rather than collapsing a rejected action to
`none`.

Debug details remain in the inspector. The product HUD consumes immutable
presentation state and never reads authority implementation.

## Metal Visibility Oracle

Selected validation scenarios render a small offscreen integer/normalized ID
target using the same transforms and depth behavior as the color pass. The
validation adapter downloads it through an SDL GPU transfer buffer after a
fence. It derives per-ID pixel count and bounds.

The ID pass is validation-only and serial on macOS. It does not expand the
runtime renderer API into a general render graph. Color screenshot and ID mask
are written only on a checkpoint request or first failure.

The ID oracle proves semantic occupancy and depth, not that the product color
pipeline honored its material input. Primitive and model shader reflection
therefore remain separate renderer contracts, and human-facing lifecycle
colors require an installed swapchain acceptance checkpoint. The player-death
checkpoint currently requires at least 64 depth-tested local-corpse pixels at
320x180 in addition to the exact dead draw plan and red material color.

## Phase Sequence

### IV0 — Interaction contracts and failing reproduction

- [x] Define lifecycle, contact, camera, visibility, and action-disposition
  observations.
- [x] Add a deterministic normal-product-equivalent NPC contact reproduction.
- [x] Prove at least one current-tree invariant fails for the reported defect.
- [x] Record the selected physical contact policy and initial measurements.
- [x] Validate focused and complete inherited gates for the IV0 boundary.

### IV1 — Scenario kernel and causal trace

- [x] Implement the fixed-capacity typed scenario runner.
- [x] Implement the bounded gameplay interaction trace and export.
- [x] Convert S1, S2, S7, and S11 intent to shared scenarios without duplicating
  product policy.
- [x] Add deadline, ordered sequence, continuous invariant, and deterministic
  artifact tests.
- [x] Validate the phase and update the evidence ledger.

The shared catalog is condition-driven. Existing graphical S1/S2 timing is now
isolated in named legacy adapter functions rather than embedded in `main.zig`;
renderer-free and new graphical validation consume the same semantic scenario
definitions. Session protocol-to-trace projection is one shared session module,
so embedded and networked placements cannot invent different causal meanings.

### IV2 — NPC-contact corrective slice

- [x] Select and implement the Jolt contact safety policy.
- [x] Add NPC combat stand-off/approach behavior owned by the encounter and NPC
  locomotion contracts.
- [x] Preserve authoritative solo/listen/dedicated semantics and replay.
- [x] Make the IV0 reproduction pass without weakening its invariants.
- [x] Re-run inherited S11, physics, replay, and macOS gates.

The accepted contact policy has two independent layers: authority uses the
Physics-owned Jolt character registry as the non-penetration safety boundary,
while encounter pursuit targets an authored combat stand-off and still admits
melee at its larger range. Sparse client presentation applies a deterministic
NPC-only separation correction against the local avatar, including its
retained dead projection. That last correction never feeds authority or
replication; it prevents two independently sampled presentation lanes from
visually interpenetrating between snapshots or consuming the visible corpse.

The exact 65-controller declared ceiling was exercised for 1,950 real-Jolt
controller updates. It remains comfortably inside the routine test watchdog,
so the simple owner-thread registry is retained. A spatial character registry
is deferred until a measured product cohort, rather than theoretical scale,
requires it.

### IV3 — Gameplay Inspector and readable product feedback

- [x] Add selected-entity trace/state inspection.
- [x] Surface silent ordinary action dispositions.
- [x] Add readable local health, damage, death, windup, respawn, and actionable
  rejection feedback.
- [x] Remove ambiguous geometric-only feedback where it represents required
  product state.
- [x] Validate normal product and editor-enabled acceptance.

The eighth editor tool consumes a fixed immutable entity projection and a
type-erased chronological trace borrow. Selection cycles stable replicated
identity and displays its durable identity when the privileged host lookup is
available. Authority/presentation pose, velocity, controller dimensions,
health/life, encounter deadline, nearest separation, last action, and filtered
trace stay read-only. Trace controls use a saturated fixed request mailbox and
are applied by the developer owner after the frame borrow ends.

Required product state is no longer encoded only as world-space colored
blocks. The editor-enabled product renders a compact always-on screen-space
panel even when F1 hides developer windows. It names health, received damage,
death, attack windup, melee cooldown, respawn countdown/instruction, and local
action rejection. The same immutable values are projected into the macOS
window title in the editor-disabled cohort. Existing health bars and spatial
markers remain useful world context, but they are no longer the only meaning.

### IV4 — Metal object-ID visibility oracle

- [x] Add validation-only ID target, pipeline, transfer buffer, fence, and
  readback owner.
- [x] Add visible pixel count/bounds observations and invariants.
- [x] Capture bounded color/ID artifacts on first failure.
- [x] Run contact/death scenarios above and below the authority tick rate.
- [x] Validate installed Metal lifecycle and resource teardown.

The accepted adapter is intentionally serial and validation-only. It renders
selected `pos_color` gameplay capsules at 320x180 through the same MVP,
clockwise cull, less-depth-test, and depth-write policy as the product pass.
Normalized RGBA8 attachment zero carries a stable 24-bit object ID; attachment
one carries the selected entity's product presentation color. One persistent
download transfer buffer receives both attachments, and CPU inspection begins
only after the submission fence completes.

Visibility is declared per semantic checkpoint, not for every live world
entity. Contact declares player and NPC, player death declares the retained
dead player and surviving NPC, respawn declares the newly respawned player,
and NPC death declares both the living player and dead NPC reaction. This
distinction was forced by the
first real failure artifact: the surviving NPC was legitimately off-camera at
player respawn and therefore was not a valid zero-pixel failure. A declared
entity still fails on a single zero-pixel checkpoint observation, while a
human-critical checkpoint may impose a larger minimum meaningful footprint.

### IV5 — Process, topology, fault, and soak matrix

- [x] Run shared scenarios in solo, listen, and dedicated placements.
- [x] Apply deterministic latency, jitter, loss, duplication, reorder,
  blackout, reconnect, and streaming transitions.
- [x] Add seeded action fuzzing with replayable failures.
- [x] Add routine and explicit long interaction soaks.
- [x] Publish the aggregate gate and close with a fresh implementation and
  documentation audit.

## Phase Review Protocol

After each phase:

1. compare implementation to this design and ADR-020;
2. run the phase-specific focused gate;
3. run the inherited gate proportional to the changed boundary;
4. inspect failure artifacts and diagnostic/trace saturation counters;
5. perform a source/dependency/ownership review;
6. update the validation ledger with exact evidence and remaining risks; and
7. mark the phase complete here only after the evidence ledger accepts it.

## Definition Of Complete

- The original contact/death journey is a deterministic automated scenario.
- The scenario would fail on the pre-IV implementation for the reported
  overlap/continuity/communication defect.
- Solo, listen, and dedicated placements share scenario semantics.
- Every tested action has a causal terminal disposition.
- An unexplained single-tick projection gap or insufficient single-frame
  semantic footprint fails its declared invariant.
- The Gameplay Inspector explains the selected player/NPC journey.
- The normal product communicates death and respawn without requiring the
  inspector.
- Failure artifacts reproduce through the same-build scenario/replay tool.
- Focused, full Debug/ReleaseFast, cold headless, extracted-source, installed
  Metal, and macOS readiness gates pass.

## Deferred

- General UI automation and editor widget golden tests.
- Cross-platform GPU oracle work.
- Remote telemetry storage or hosted dashboards.
- Lua/Python scenario authoring.
- Firearms, lag compensation, public services, MMO scale, and generic crowd
  avoidance.
