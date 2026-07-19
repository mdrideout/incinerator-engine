# Playable Boundary And Vehicle–NPC Collision Correction

**Status:** Implemented; aggregate and physical Metal acceptance pending

**Date:** 2026-07-19

**Platform:** Apple Silicon macOS product; renderer-free authority coverage is
required where the defect does not depend on Metal

**Related decisions:**

- [ADR-012](../adr/012-canonical-district-catalog-and-fixed-two-slot-streaming.md)
- [ADR-019](../adr/019-authoritative-npc-encounter-and-replacement.md)
- [ADR-021](../adr/021-local-human-test-incident-bundles.md)
- [Incident evidence reliability plan](incident-evidence-reliability-and-boundary-corrections.md)

## Purpose

Correct two issues exposed by the physical macOS checkpoint without hiding
either one behind restricted traversal or presentation behavior:

1. remove the recipe-4 perimeter walls that prevented a tester from reaching
   unsupported-distance and district-boundary conditions; and
2. make physical vehicle displacement of an NPC across a district seam a
   normal authority transition rather than a fatal route invariant.

The existing valid corrections remain: both currently authored districts stay
resident in the ordinary sandbox, bounded vehicle/carryable replication stays
continuous, NPC relevance remains proximity/encounter aware, and the camera
continues to resolve ordinary world obstruction.

## Triggering evidence

### Perimeter correction

Recipe 4 added collision-backed boxes around the two-district route after a
tester reported distant content disappearing. That change made the finite
content envelope visible, but it did not repair distance behavior. It prevented
the tester from reaching the condition that exposed the defect. This is an
invalid acceptance strategy for an expanding sandbox.

The infinite checkerboard remains diagnostic presentation, not completed game
content. A sparse area may reject content-owned actions with explicit feedback,
but movement and vehicle traversal must not be blocked merely because only two
districts are currently authored.

### Vehicle–NPC collision correction

Reference bundle:
`2026-07-19T17-40-08.000Z_solo_9b38ce58`.

The source bundle remains read-only and outside the repository. Its durable
findings are:

| Evidence | Observation |
|---|---|
| Bundle health | Schema 3, complete run, ordinary hardening profile, zero recorder loss, writer failures, screenshot misses, or suspicious visuals |
| Fault boundary | Fatal `runtime_system_fault` at attempted authority tick 2382; committed authority tick remains 2381 while presentation continues in fault inspection |
| Last pre-fault state | Tick 2376: vehicle at `x=5.36`, moving east at about `3.69 m/s`; NPC at `x=7.73`, alive and moving west; separation about `2.05` |
| Ownership seam | West/east district ownership changes at the half-open `x=8` boundary |
| Code boundary | `npc.publish_and_transfer` rejects a changed positional owner unless the NPC's next planned route node is in that same owner district |
| Presentation | Cornflower blue is the deliberate retained-fault frame, not GPU corruption |
| Evidence limitation | The generic diagnostic record retained code `0x00010001` but omitted runtime phase, system, and error name; replay was not attached, so the anomaly correctly finalized partial |

The causal defect is an invalid model: physical position determines spatial
ownership, while a route is only movement intent. A vehicle, moving body, or
future explosion may displace an NPC in a direction that is not its next route
edge. That must rebase navigation intent or produce a local recoverable policy;
it must never fault the whole authority.

## Decisions

### Traversal remains open

- Remove the perimeter boxes from logical collision and proxy presentation.
- Advance the exact district recipe cohort; do not retain compatibility code.
- Keep the two existing obstacle boxes and shared visual/collision catalog.
- Keep ordinary-product two-district residency. Residency prevents current
  authored content from popping; it does not define a movement barrier.
- Add traversal regressions through every former perimeter plane. A test must
  prove the absence of blockers, not merely the absence of their draw calls.
- Sparse diagnostic terrain outside the authored districts is acceptable for
  now. Future slices should expand real content/streaming rather than restore a
  hard perimeter.

### Position owns district transfer; route intent rebases

When a live NPC's post-physics position changes district:

1. resolve the nearest active navigation node in the positional owner;
2. bind the existing CharacterVirtual controller to that owner's current load
   ticket without reconstructing it;
3. rebuild the semantic goal from the owner-aligned node while preserving the
   current patrol leg;
4. rebuild or defer encounter pursuit from the same owner-aligned position;
5. emit one typed owner-transfer event; and
6. continue the authority tick.

If external displacement reaches an inactive district, the feature must apply
an explicit local recovery policy instead of retaining mismatched ownership or
faulting the runtime. The initial correction restores the last committed,
owner-valid controller pose with neutral velocity until destination content is
active. This affects NPC authority only; it is not a player/world perimeter.

### Fault evidence must name the owner

Incident timeline output must materialize retained faults separately from the
generic diagnostic journal entry:

- runtime phase, tick, system name, error name/code, and journal sequence;
- authority-cycle stage, target/completed ticks, and error name/code; and
- exactly one admitted record per immutable first fault, retrying after queue
  pressure rather than marking missing evidence as recorded.

The inspector, summarizer, schema reference, and diagnostic skill must surface
these records. A future collision incident should identify
`npc.publish_and_transfer/NpcUnexpectedOwnerTransfer` directly without access
to terminal output.

Fault inspection must remain visibly identified as a retained engine fault.
Changing the background alone is not a repair; healthy gameplay must never
enter the inspection loop for ordinary collision.

## Implementation sequence

1. [x] Add deterministic failing NPC displacement coverage at the feature
   boundary and a real-Jolt vehicle-contact regression at the composed
   simulation boundary.
2. [x] Remove perimeter collision/proxy boxes, advance the recipe cohort, and
   update catalog/configuration/documentation contracts.
3. [x] Implement positional owner adoption plus semantic route/encounter
   rebasing, including inactive-destination recovery.
4. [x] Record immutable structured runtime and authority-cycle fault evidence
   in incident timeline files and teach diagnostic consumers to report it.
5. [x] Run focused NPC, physics, district, session, replay, incident, source
   package, and aggregate macOS tests.
6. [ ] Run an installed Metal journey and request a physical pass: cross every
   former perimeter, drive into the NPC at the seam, continue driving, and
   verify no cornflower fault frame or entity discontinuity.

## Implementation evidence

The original NPC feature test was first run against the old implementation and
failed with `NpcUnexpectedOwnerTransfer` at the publish boundary. The corrected
feature now passes deterministic cases for owner adoption, inactive/unavailable
destination recovery, and the blocked-relocation suspend/reconstruct path.

The composed real-Jolt test enters a real four-wheel vehicle, maintains a
bounded heading toward the NPC, sustains physical contact through the `x=8`
district seam, observes exactly the east owner, retains the same controller,
and continues for another 120 ticks without a runtime fault. A separate real
Jolt regression walks beyond the former north wall and drives beyond the former
east wall. The pure recipe test checks all four removed perimeter planes and
both remaining obstacle proxies.

Focused gates completed during implementation:

| Gate | Result |
|---|---|
| NPC feature | 26/26 tests passed, including disconnected active-content recovery |
| Composed simulation/Jolt | 43/43 tests passed |
| Developer host and incident capture | 47/47 tests passed |
| Accepted-ingress replay | 20/20 tests passed with recipe 5 fingerprint |
| Sandbox navigation | 1/1 test passed |
| District contract | 3/3 tests passed |
| Session contracts | 151/151 tests passed |
| Full editor-disabled repository | 255/255 steps and 942/942 tests passed |
| Extracted source package | 182/182 broad steps with 414/414 tests; 32/32 cold steps with 62/62 tests |
| Installed S4 retained-fault Metal smoke | 59/59 steps passed; exact runtime and authority-cycle fault retained |

The supplied schema-3 bundle remains an honest historical partial anomaly: it
predates structured retained-fault records and lacks accepted-ingress replay.
The current inspector still accepts it and reports the generic fatal runtime
diagnostic at tick 2381. New captures additionally record searchable runtime
system/error and authority-cycle stage/error ownership.

The installed product incident journey completed 2,209 authority ticks and all
four scripted anomaly lifecycles under recipe 5. Strict inspection accepted the
bundle, and semantic replay matched all 2,149 attached ticks. Its automated
visual heuristic reported 207 dominant-green frames while scripted close-range
combat put the NPC between the character and camera. That is not the original
cornflower retained-fault failure, but it prevents using this journey as the
physical acceptance required by step 6. Open-perimeter and sustained
vehicle-contact behavior still require the targeted human pass below.

## Acceptance

- No collision or presentation proxy exists solely to contain the current
  two-district authored route.
- Character and vehicle authority can cross all former perimeter planes.
- Sustained vehicle contact may move an NPC across `x=8` without a retained
  runtime or authority-cycle fault.
- The NPC retains one identity/controller, adopts positional ownership once,
  and resumes/defer-rebuilds its admitted semantic intent.
- An inactive destination cannot create mismatched owner/ticket state and does
  not fault the simulation.
- Focused deterministic coverage fails against the original implementation and
  passes after the correction.
- A manufactured runtime fault produces searchable structured fault ownership
  in a fresh incident bundle.
- Human Metal validation confirms open traversal and collision continuity.
