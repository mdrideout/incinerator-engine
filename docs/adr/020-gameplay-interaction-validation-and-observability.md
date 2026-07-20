# ADR-020: Gameplay Interaction Validation And Observability

**Status:** Accepted

**Date:** 2026-07-15

**Decision owners:** Engine architecture, sandbox product, validation tooling

**Implementation contract:**
[`../design/gameplay-interaction-validation-and-observability.md`](../design/gameplay-interaction-validation-and-observability.md)

**Evidence ledger:**
[`../validation/gameplay-interaction-validation-and-observability.md`](../validation/gameplay-interaction-validation-and-observability.md)

## Context

The post-S11 engine has broad unit, real-Jolt, headless, replay, fault,
multiplayer-process, and installed Metal coverage. The first playable hostile
NPC nevertheless exposed behavior that those gates did not explain or reject:

- player and NPC presentation could become visually ambiguous at close range;
- NPC combat could kill and despawn the local avatar without readable product
  feedback;
- a retained world-space marker could look like a fragment of the removed
  avatar;
- ordinary recoverable action rejections could be intentionally swallowed by
  the product loop without a causal developer record; and
- graphical smokes proved that expected states and draw calls occurred at
  least once, but did not prove continuous entity presence, non-penetration,
  camera safety, or visible pixel coverage.

The failure is not a lack of test quantity. It is a missing validation layer
between authoritative state correctness and a coherent player-visible
interaction. A test that proves the player eventually died can still accept a
death transition that looks like rendering corruption.

## Decision

Incinerator will treat a gameplay interaction as one causally traceable,
temporally validated journey from sampled input through authority, replication,
presentation, and optional GPU visibility.

### One typed scenario contract

Gameplay acceptance uses a small typed Zig scenario contract. A scenario owns:

- deterministic setup, seed, roles, and topology;
- fixed-tick press, hold, release, and direct authority stimuli;
- condition waits with tick deadlines rather than wall-clock sleeps;
- continuous invariants evaluated for every applicable tick or frame;
- ordered transition expectations;
- checkpoints and failure artifact policy; and
- declared execution adapters: simulation, session, presentation, Metal, and
  installed process placement.

Scenarios are compiled Zig values. JSON, Lua, Python, OS-level keyboard
synthesis, and a general gameplay scripting VM are not part of the initial
contract. An external process runner may orchestrate installed products, but
it does not decide gameplay correctness from log scraping.

### Temporal invariants are first-class

Tests must express both eventual expectations and continuous invariants.
Initial required invariants include:

- every alive local avatar remains in the authoritative projection and
  presentation plan;
- a living NPC remains continuously projected until an explicit lifecycle
  transition;
- replicated identity and incarnation changes require a matching lifecycle
  event;
- physical actors respect the selected contact/separation contract;
- camera placement does not enter protected actor or blocker volumes;
- every submitted discrete action reaches one terminal disposition by its
  deadline;
- death feedback becomes readable atomically with the transition to a retained
  visible death proxy; avatar removal is permitted only at explicit respawn or
  another traced lifecycle transition;
- a submitted visible entity retains a checkpoint-appropriate meaningful
  object-ID footprint when the scenario declares it observable; and
- presentation cadence, replication sparsity, deterministic transport faults,
  reconnect, and streaming do not create unexplained entity gaps.

### Gameplay trace is distinct from fault diagnostics

The existing diagnostic journal remains the bounded record of faults,
backpressure, and operational events. A new bounded gameplay interaction trace
records causal transitions and ordinary dispositions. It is not unrestricted
text logging.

The canonical stages are:

1. input sampled;
2. local preflight;
3. client action submitted;
4. authority admitted or rejected;
5. simulation intent/outcome;
6. reliable event or snapshot publication;
7. client application;
8. presentation planning;
9. draw submission; and
10. optional GPU visibility observation.

Records use typed stages, kinds, dispositions, correlation IDs, entity
identity/incarnation, tick/frame, and small domain payloads. Owners emit
transitions, not an unbounded record per entity per tick. Saturation and drops
are visible. An invariant failure freezes the relevant retained window.

### Developer evidence and player communication are separate

The developer Gameplay Inspector exposes selected-entity state, target,
encounter state, action timeline, deadlines, positions, separation,
replication/presentation age, and visibility evidence. It is read-only and
submits only typed debug requests such as pause, step, selection, and export.

Product UI separately communicates health, damage, hostility/windup, death,
respawn timing/instruction, and ordinary action rejection/cooldown. Developer
logs are not player UX, and player feedback does not replace causal evidence.

### 2026-07-15 human-acceptance amendment

The first post-IV play-through proved that "feedback before removal" was still
too weak: a correct authority teardown could make the avatar disappear while
the participant waited to respawn. Incinerator therefore retains a replicated,
noninteractive death proxy at the last authoritative avatar pose until that
participant respawns. The proxy has zero health, an explicit dead life state,
and unmistakable red presentation. Authority may destroy the physical
controller and release gameplay ownership, but presentation may not encode
death as unexplained absence.

The same acceptance pass established two additional diagnostic contracts:

- a carryable released by player death uses the ordinary interaction boundary
  and remains visibly released; manual drop tries deterministic placements in
  the current active district before using its last active world pose; and
- every rejection reason records its namespace as well as its numeric value.
  Gameplay trace JSON schema 2 distinguishes runtime errors, protocol
  dispositions, and validation codes, while the product HUD preserves the
  concrete action disposition (for example `too_far`).

Normal graphical composition also records semantic presentation membership,
health, life, and disappearance transitions. It deliberately does not record
per-frame transforms; high-rate analog movement is coalesced so the bounded
causal trace retains the discrete events a human is trying to explain.

The corrective rendered pass also established that a presentation-plan color
and an offscreen color preview do not prove the product swapchain honored the
same material input. The primitive renderer had ignored `base_color` while the
validation-only fragment shader used it. Primitive material tint is now an
explicit shader/reflection contract, and human-critical lifecycle colors retain
an installed real-window acceptance checkpoint. Presentation separation
continues against the retained dead avatar so a hostile cannot depth-occlude
the corpse into apparent disappearance.

### Rendering validation uses semantic IDs

Installed Metal validation adds a small offscreen object-ID target and SDL GPU
readback for selected scenarios. Semantic pixel presence and bounds are the
primary oracle. Color screenshots are retained as failure artifacts and may
have targeted comparisons, but broad golden-image testing is not the core
contract.

The object-ID adapter proves occupancy and depth under selected product
transforms. It does not replace shader interface tests or direct swapchain
acceptance for required human-facing color. A checkpoint may require more than
one pixel when a barely visible sliver would still be unusable evidence.

### Contact behavior is explicit gameplay policy

Player/NPC contact must have one documented authoritative policy. AI steering
or stand-off behavior may reduce contact, but it cannot be the only safety
boundary. The accepted corrective phase must evaluate Jolt virtual-character
collision, an inner body, or the cheaper rigid `Character` controller for
simple NPCs, then select and measure one policy rather than applying an
isolated distance clamp.

## Test Layers And Cadence

| Layer | Owner | Default cadence |
|---|---|---|
| Pure contracts | Feature/kernel | Every test build |
| Deterministic real-Jolt scenario | Scenario runner + simulation | Every change |
| Solo/listen/dedicated session scenario | Session adapters | Every relevant change |
| Presentation-plan continuity | Presentation adapter | Every relevant change |
| Metal object-ID visibility | SDL GPU validation adapter | macOS acceptance |
| Installed process journey | Process orchestrator | phase and readiness gate |
| Seeded faults/fuzz/soak | Scenario matrix | routine/nightly or explicit long gate |

## Failure Artifact Contract

The first invariant failure produces one self-identifying bundle containing:

- scenario name, seed, build/replay cohort, topology, and world fixture;
- failing tick/frame, invariant, and typed observation;
- retained gameplay trace and compact diagnostic snapshot;
- accepted-ingress replay or deterministic scenario input stream;
- recent presentation plans;
- color screenshot and object-ID mask when a GPU adapter is active; and
- process logs and crash disposition for installed journeys.

Artifact creation is best effort after the first retained cause. Failure to
write secondary evidence must not overwrite the gameplay failure.

## Documentation Strategy

This ADR is the durable reason and architectural decision. It changes only
when the decision changes and records amendments rather than silently
rewriting history.

The linked design document is the living implementation contract. It owns the
scenario API, trace schema, invariants, phase sequence, budgets, and explicitly
deferred scope.

The linked validation document is the evidence ledger. Each phase records its
source state, commands, counts, measurements, manual observations, remaining
risks, and review disposition. A phase is not complete because the design
checklist changed.

`OVERHAUL_PLAN.md`, `ARCHITECTURE_REVIEW.md`, and `README.md` link to these
owners and summarize status only. They must not duplicate detailed evidence.

## Consequences

- Gameplay defects become reproducible at the authority/presentation boundary
  before a human must infer them from a rendered window.
- Headless and graphical tests share scenario intent instead of accumulating
  unrelated hard-coded scripts.
- Continuous invariants add explicit cost, so suites require fast, macOS, and
  long-running labels rather than running every matrix entry on every edit.
- GPU readback is intentionally limited to selected semantic checks.
- Some subjective feel and visual quality still require human playtesting;
  disappearance, overlap, missing transitions, and silent actions do not.

## Rejected Alternatives

- More eventual-state flags in the existing S11 smoke: it preserves the gap.
- Screenshot comparison as the only visual oracle: it is brittle and weak at
  explaining identity or causality.
- Unbounded text logs: they are difficult to correlate, test, and budget.
- A new scripting language before typed scenarios have a second external
  authoring consumer: speculative complexity.
- AI avoidance without a physical safety contract: it cannot guarantee
  non-penetration under faults, spawn, or opposing motion.

## References

- [Jolt `CharacterVirtual`](https://jrouwe.github.io/JoltPhysics/class_character_virtual.html)
- [Jolt character controller guidance](https://jrouwe.github.io/JoltPhysicsDocs/5.0.0/index.html)
- [Unreal Automation Test Framework](https://dev.epicgames.com/documentation/en-us/unreal-engine/automation-test-framework-in-unreal-engine)
- [Unreal Gauntlet](https://dev.epicgames.com/documentation/unreal-engine/gauntlet-automation-framework-overview-in-unreal-engine?lang=en-US)
- [O3DE LyTestTools](https://www.docs.o3de.org/docs/user-guide/testing/lytesttools/)
- [O3DE parallel testing and condition waits](https://docs.o3de.org/docs/user-guide/testing/parallel-pattern/)
- [SDL GPU texture readback](https://wiki.libsdl.org/SDL3/SDL_DownloadFromGPUTexture)
- [Perfetto track events](https://perfetto.dev/docs/instrumentation/track-events)
