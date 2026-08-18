# S13 Authored Population and Sandbox Activity

**Status:** Accepted; S13-A through S13-H implementation, automated evidence,
and the ordinary product-owner walkthrough are complete

**Date:** 2026-07-28

**Platform:** Apple Silicon macOS only

**Decision:** [ADR-024](../adr/024-authored-population-intent-and-activity-slots.md)

**Evaluation world:**
[S13 Population Evaluation World](s13-population-evaluation-world.md)

**Entry checkpoint:** The S12 human Navigation Lab checkpoint is accepted. Its
clean final walkthrough did not manufacture anomaly flags; real incidents
continue through the accepted schema-5 evidence workflow.

## Goal

Deliver a playable two-district sandbox populated by twelve authored
pedestrians whose roles, activity programs, destinations, slot use, combat
disposition, death, and replacement are visible, deterministic, authoritative,
persistable, replayable, and diagnosable.

S13 must directly resolve A-F035 and A-F037 without adding a generic AI,
navigation, crowd, or service framework.

## Product Outcome

A player should be able to enter the ordinary product and understand that:

- residents, workers, and visitors have different authored movement patterns;
- pedestrians travel to recognizable sites, wait for exclusive activity slots,
  dwell, and continue;
- one explicitly authored hostile member still exercises combat;
- vehicle displacement interrupts navigation truthfully without erasing
  activity intent;
- two pedestrians do not spawn into the same physical space;
- killing a pedestrian creates one readable vacancy and safe replacement of
  the same authored member; and
- the Population Lab and incident bundle explain every role, activity, slot,
  interruption, retry, death, and replacement transition.

## Current Baseline and Problems to Remove

| Current mechanism | S13 treatment |
|---|---|
| `features/population/contract.zig` repeats one spawn template | Replace with authored catalog plus durable population runtime owner |
| `sandbox/product_encounter.zig` spawns one product hostile | Remove after ordinary product bootstraps through the population owner |
| `sandbox_npc_replacement` owns only delayed node candidates | Fold its durable replacement responsibility into population membership |
| Session `npcReplacementCandidates(npc_index)` chooses nodes | Remove; candidates come from authored member/spawn-slot policy |
| `hostile_npc_limit` ranks persistent IDs | Remove; encounter observes explicit authored combat disposition |
| NPC spawn occurs exactly on a route node | Extend the greenfield command to authored pose plus admitted start anchor |
| Replacement ignores live NPC virtual capsules | Add bounded NPC separation after sufficient slots exist |
| 64 NPCs co-locate in synthetic tests | Keep 64 as logic/transaction pressure only; use 16 unique authored members for physical scale |
| Role/activity state is absent from inspection and incident evidence | Add compact projected state plus complete authority-side evidence |

No compatibility path keeps any superseded policy alive.

## Ownership and Data Flow

```text
authored population catalog
  -> population member + cyclic activity program
  -> claim one authored activity slot
  -> issue semantic destination to NPC feature
  -> NPC feature plans/follows through S12
  -> arrival changes claim to occupied
  -> dwell deadline completes activity
  -> release slot and advance program

vitals death
  -> population member becomes vacant
  -> release activity slot
  -> safe authored spawn-slot selection
  -> host creates/registers new NPC actor
  -> bind new actor to the same population member
  -> resume retained activity program
```

Cross-owner calls remain typed and bounded:

- population reads copied NPC/vitals/navigation facts;
- population emits correlated spawn, goal, and replacement intents;
- NPC owns all movement and route state;
- encounter owns only transient combat locomotion;
- session maps population member, physical NPC, replicated ID, and result; and
- presentation consumes immutable projected values.

## Proposed Canonical Values

Names may change during S13-A if the existing contract naming requires it, but
the responsibilities may not drift.

```text
PopulationMemberId(u16)
PopulationRoleId(u8)
ActivityProgramId(u8)
ActivitySiteId(u16)
ActivitySlotId(u16)
SpawnSlotId(u16)

Role = resident | worker | visitor
CombatDisposition = passive | hostile_to_players
ActivityKind = commute | shop | visit | idle
ActivityState =
    selecting
    waiting_for_slot
    traveling
    dwelling
    completing
    interrupted
    vacant
    replacement_pending
SlotState = free | claimed | occupied
```

### Authored catalog

The sandbox catalog contains fixed arrays of:

- role definitions with presentation profile;
- member definitions with stable member ID, role, program, phase offset,
  combat disposition, and allowed initial/replacement spawn slots;
- activity programs with at most six explicit steps;
- activity sites and capacity-one slots;
- spawn slots with exact pose, facing, navigation anchor, and member/role
  admission; and
- the exact destinations required by activity slots.

Catalog validation rejects:

- duplicate or zero stable IDs;
- missing role/program/site/slot/destination references;
- programs with zero steps or out-of-range cursors;
- activity kinds unsupported by the referenced site;
- spawn or activity poses outside the installed two-district cohort;
- spawn pose/anchor ownership mismatch;
- static blocker or capsule-clearance failure;
- paths from spawn pose to anchor that cross canonical blockers;
- two spawn slots closer than the declared capsule separation;
- insufficient spawn candidates for any member;
- insufficient total slots for the ordinary and physical-stress cohorts; and
- a role/program/disposition distribution that does not match the accepted
  product roster.

### Runtime member record

One fixed record per authored member retains:

- member ID;
- lifecycle and current physical NPC binding;
- activity program cursor and monotonic activity sequence;
- current kind/state/site/slot;
- claim and dwell deadlines;
- retry tick and typed retry reason;
- replacement generation and transaction correlation; and
- last transition tick/reason.

Role, program contents, slot pose, and spawn candidate definitions are resolved
from the exact catalog rather than duplicated into mutable records.

### Deterministic activity producer

S13 uses no runtime random choice.

1. Read the member's current program step.
2. Enumerate compatible slots at that step's site in stable slot-ID order,
   rotated by `member_id % site_slot_count` to avoid permanent low-ID bias.
3. Exclude invalid, claimed, occupied, inactive, or physically unavailable
   slots.
4. Reserve the first candidate in the same authority phase.
5. Issue the matching semantic destination.
6. On arrival, occupy and dwell for the authored tick duration.
7. On completion, release, advance the program cursor, and select again.

No available slot enters `waiting_for_slot` with a staggered deterministic
retry. Repeated unavailability is visible in diagnostics; it does not become
unreachable navigation or an authority fault.

### Interruption policy

- S12 `waiting_for_content` or `blocked` retains the current activity and claim
  until its bounded lease expires.
- Vehicle displacement retains the current activity; S12 replans.
- Encounter engagement releases a claimed/occupied slot and marks the activity
  interrupted so combat cannot starve the site.
- Encounter return retries the same retained program step.
- Death releases the slot, retains the program cursor on the population member,
  and begins safe replacement.
- Replacement binds a new physical NPC and retries the retained step.

## Implementation Sequence

Every phase ends with focused tests, a documentation/status review, and a
comparison against ADR-024. Do not begin the next phase with an unresolved
P0/P1 finding.

### S13-A — Entry characterization and accepted contract

- [x] Complete/review the S12 human checkpoint. Preserve real incident evidence
  rather than manufacturing two anomaly flags during a clean walkthrough.
- [x] Measure current ordinary-product/encounter, six-anchor physical, and
  64 synthetic baselines before changing population. A credible 16-member
  physical measurement moves to S13-B because the pre-S13 world does not have
  sixteen validated non-overlapping placements.
- [x] Inventory every initial NPC bootstrap, NPC outcome consumer, death/
  replacement transaction, snapshot record, replay command, projection field,
  editor consumer, and build gate.
- [x] Validate the proposed 12/16-member, 24-spawn-slot, and 16-activity-slot
  targets against map area, controller capacity, and fixed-tick headroom.
- [x] Accept or amend ADR-024 before runtime implementation.
- [x] Record exact schema/content/protocol/replay cohort breaks; no old decoder.

**Exit:** one accepted owner/data/lifecycle contract and measured starting
budget; no unexplained FIFO consumer or bootstrap path.

### S13-B — Authored catalog and evaluation-world capacity

- [x] Add fixed value contracts for roles, member definitions, programs, sites,
  activity slots, and spawn slots under sandbox ownership.
- [x] Author the exact 12-member roster, 3 roles, 8 sites, 16 activity slots,
  and 24 spawn slots specified by the evaluation-world plan.
- [x] Add any narrowly required destinations/navigation anchors while retaining
  the two-district topology and S12 route ownership.
- [x] Validate every identity, reference, capsule clearance, separation, and
  capacity before cooking or authority construction.
- [x] Advance the exact content fingerprint and cooker/catalog checks together.
- [x] Expose exact site/slot/spawn marker values from the renderer-neutral
  catalog. Their interactive rendering remains with the Population Lab in
  S13-F so content admission does not import presentation policy; decorative
  geometry never becomes authoritative collision.

**Exit:** one exact renderer-neutral catalog proves sufficient unique physical
placement and activity capacity before runtime population logic exists.

### S13-C — Durable population member and activity authority

- [x] Replace the stateless population contract with one fixed-capacity
  `sandbox_population` owner.
- [x] Implement cold bootstrap of the authored roster with stable
  `PopulationMemberId`.
- [x] Implement the explicit activity and slot state machines, same-tick
  reservations, deterministic program advancement, deadlines, and typed
  transitions.
- [x] Add bounded correlated outputs and exact peek/commit ownership.
- [x] Add immutable views, aggregate diagnostics, logical digest, and saturation
  behavior.
- [x] Prove slot contention, lease expiry, interruption, retry, and queue
  saturation without ECS, Jolt, session, or rendering.

**Exit:** pure deterministic roster/activity/claim behavior is complete and
independently testable.

### S13-D — NPC, encounter, vitals, and session integration

- [x] Extend NPC spawn to accept an authored pose plus admitted start anchor;
  remove the assumption that physical spawn equals route-node position.
- [x] Bind each live NPC actor to exactly one population member and reject
  duplicates/stale generations.
- [x] Route population-owned set-goal correlations through the existing NPC
  command boundary without stealing unrelated FIFO outcomes.
- [x] Replace `hostile_npc_limit` with explicit authored combat disposition in
  the encounter observation boundary.
- [x] Route death to the exact member vacancy and replacement transaction while
  retaining the existing vitals/death-proxy guarantees.
- [x] Replace the one-off normal-product encounter bootstrap with ordinary
  population bootstrap.
- [x] Remove `product_encounter`, normal-product use of the old stateless
  planner, session `npcReplacementCandidates`, and the dead session drain for
  standalone replacement outcomes.
- [x] Remove the standalone replacement snapshot/replay cohort after population
  durable records cut every consumer over in S13-G.

**Exit:** normal solo, listen, and dedicated placements use one population
source of truth; no product role/candidate decision depends on session array
or persistent-ID rank. Persistent headless state joins that source in the
coordinated S13-G schema break.

### S13-E — Safe replacement and live-NPC separation

- [x] Evaluate spawn candidates from the member's authored spawn-slot set.
- [x] Add real-Jolt placement, static clearance, player/occupied-vehicle,
  rigid-body, live-NPC `CharacterVirtual`, visibility, and same-cycle
  reservation checks.
- [x] Retain typed retry counts for inactive, occupied, NPC-overlap,
  player-near, player-visible, and capacity outcomes.
- [x] Prove no safe candidate retains one pending vacancy and death proxy.
- [x] Prove the same member receives a new physical identity/incarnation after
  successful registration and resumes its activity program.
- [x] Run the 16-member physical authored stress cohort with no initial or
  replacement overlap.

**Exit:** A-F035 and A-F037 are mechanically resolved for the declared product
and authored-stress cohorts.

### S13-F — Presentation, Population Lab, and incident evidence

- [x] Project member ID, role/presentation profile, and coarse activity kind/
  state needed by product rendering.
- [x] Give roles readable base presentation while preserving hit, hostility,
  death, cooldown, and replacement feedback precedence.
- [x] Add a dedicated Population Lab rather than overloading Navigation Lab.
- [x] Show roster counts, selected member/actor identities, role/disposition,
  activity program/cursor/state, site/slot/claim, deadlines, retry reason,
  navigation state, and replacement lifecycle.
- [x] Add spawn-slot, activity-slot, claim, separation-radius, and
  member-to-destination overlays with text plus color.
- [x] Extend gameplay trace and schema-5 incident state with stable population
  identity and current activity.
- [x] Emit transition-only timeline records for claim, travel, dwell,
  interruption, vacancy, retry, spawn, bind, and replacement; no per-tick
  transition spam.
- [x] Update the canonical incident-diagnostics skill and inspector together.

**Exit:** a human tester and a fresh LLM agent can explain why any pedestrian
is present, moving, waiting, fighting, dead, absent, or replacing.

### S13-G — Persistence, replay, reconnect, and fault closure

- [x] Add canonical member/activity/claim/replacement records to the snapshot.
- [x] Cold-preflight all member-to-actor, catalog, slot, NPC, vitals, encounter,
  and transaction relationships before native authority.
- [x] Restore traveling, dwelling, waiting-for-slot, interrupted, vacant, and
  replacement-pending midpoints exactly.
- [x] Validate the canonical slot ledger directly and reject claim conflicts;
  no separate derived claim index or silent repair path exists.
- [x] Advance accepted-ingress replay and logical digests so first divergence
  names population/activity ownership.
- [x] Prove solo/listen/dedicated semantic parity, join-in-progress, reconnect,
  delayed/lost/reordered transport observation, authority fault retention, and
  persistent-headless quiescence.
- [x] Confirm network impairment changes observation timing, never activity or
  replacement authority.

**Exit:** population intent survives every accepted authority lifecycle and
fault profile with exact evidence.

### S13-H — Product acceptance, performance, cleanup, and review

- [x] Run the scripted product journey from the evaluation plan in the ordinary
  `zig build run -Deditor=true` product.
- [x] Complete the final human walkthrough in that ordinary product.
- [x] Run installed Metal at low/high render cadence while authority remains
  fixed at 60 Hz.
- [x] Measure ordinary 12-member, physical 16-member, and synthetic 64-NPC
  cohorts separately; record CPU, memory, queue, query, body/controller, draw,
  projection, bandwidth, and incident costs.
- [x] Require zero steady-state allocation in population decision/claim paths
  and retain fixed-tick headroom.
- [x] Inspect at least one contention incident, one combat/replacement incident,
  and one displacement/interruption incident.
- [x] Audit dead code, old cohorts, compatibility branches, broad imports,
  ownership drift, duplicated policy, and documentation drift.
- [x] Update `OVERHAUL_PLAN.md`, `ARCHITECTURE_REVIEW.md`,
  `MULTIPLAYER_PLAN.md`, README, ADR status, and a new S13 validation ledger.

**Automated exit:** passed. No unresolved P0/P1 remains, and all S13-owned P2
findings are resolved with evidence. Human acceptance remains the only S13
checkpoint before the phase is marked fully accepted.

## Scenario and Test Strategy

### Pure contract tests

- unique stable IDs and exact reference validation;
- member/program/role distribution;
- deterministic slot ordering and member offset;
- same-tick claim contention;
- claim-to-occupy-to-release lifecycle;
- lease expiry and retry;
- encounter/death interruption;
- activity cursor persistence;
- stale actor/replacement generation rejection;
- queue saturation and exact FIFO ownership; and
- canonical digest and record ordering.

### Headless authority journey

1. Bootstrap twelve authored members from unique spawn slots.
2. Register vitals and explicit disposition for every physical actor.
3. Observe all three roles execute at least two program steps.
4. Force two members to contend for one site and observe one typed wait.
5. Close a traversal gate; retain activity while S12 replans or waits.
6. Displace one NPC; retain member/activity identity through S12 recovery.
7. Engage and kill the authored hostile; retain its population member.
8. Reject unsafe replacement candidates, then register one safe replacement.
9. Save/restore during travel, dwell, slot wait, and replacement pending.
10. Replay the full journey into fresh authority and compare logical digests.

### Network and client journey

- solo, listen host/guest, and dedicated client observe the same member/role/
  activity sequence;
- join-in-progress sees current activity without replaying stale cues;
- reconnect retains current actor/member binding;
- fresh actor replacement receives a new identity but the same member/role;
- faults affect delivery only; and
- role/activity feedback never overrides more important hit/death/respawn
  presentation.

### Human walkthrough

See the exact sequence in
[`s13-population-evaluation-world.md`](s13-population-evaluation-world.md).
The ordinary product is the acceptance surface. A validation-only fixture
cannot substitute for seeing twelve pedestrians, activity contention, combat,
and replacement in the rendered sandbox.

## Diagnostics Contract

### Population Lab

Global:

- desired/live/vacant/replacing member counts;
- counts by role, activity kind, and activity state;
- free/claimed/occupied activity slots;
- free/reserved/blocked spawn slots;
- decisions deferred by per-tick budget;
- replacement attempts and typed retry reasons;
- nearest live-NPC separation and overlap violations;
- queues, high-water marks, drops, and transition retention.

Selected member:

- stable member ID;
- current persistent/replicated actor and incarnation;
- role, presentation profile, and combat disposition;
- program ID, cursor, activity sequence, and current step;
- activity state/kind/site/slot and claim state;
- claim/dwell/retry deadlines;
- current semantic destination and S12 navigation lineage;
- last transition, reason, and tick;
- vacancy/replacement generation and transaction stage.

### Incident records

The compact state lane adds current population fields. The timeline writes
full data only on transitions:

```text
population_member
role
combat_disposition
activity_program
activity_sequence
activity_kind
activity_state
activity_site
activity_slot
slot_state
transition_reason
deadline_tick
replacement_generation
current_npc_identity/incarnation
```

Each record keeps authority tick, wall time, runtime phase/system/error, and
the relevant navigation route lineage. An anomaly around disappearance or
overlap must be searchable by population member even when its physical NPC ID
changes.

## Acceptance Matrix

| Concern | Required evidence |
|---|---|
| Authored intent | Every ordinary NPC maps to one stable member, role, program, and disposition |
| Activity | Members visibly travel, claim, dwell, release, and advance |
| Determinism | Same state/cohort produces the same slot and activity sequence |
| Separation | Unique initial placement and safe replacement reject live NPC overlap |
| Navigation | Activity retains semantic intent through wait, block, gate change, and displacement |
| Encounter | Only explicitly hostile members engage; combat interruption cannot corrupt activity |
| Replacement | Same member/role/program, new physical actor/incarnation, readable pending state |
| Persistence | Every accepted midpoint cold-restores or fails before native authority |
| Replay | First population divergence identifies exact member/transition/tick |
| Multiplayer | Solo/listen/dedicated share authority; faults change observation only |
| Presentation | Role/activity are understandable and combat/death remain visually dominant |
| Debugging | Inspector, overlay, trace, incident, and replay explain the same state |
| Performance | 12 ordinary and 16 physical members retain 60 Hz headroom and bounded memory |
| Cleanup | Old bootstrap/rank/candidate/replacement paths and obsolete cohorts are absent |

## Proposed Build Gates

Exact names may follow existing build conventions, but their ownership must
remain distinct:

```text
zig build test-s13-population -Deditor=false --summary all
zig build measure-s13 -Deditor=false --summary all
zig build smoke-installed-s13-macos -Deditor=true --summary all
zig build verify-s13 -Deditor=true --summary all
```

`verify-s13` composes focused population tests with inherited S11 encounter,
S12 navigation, replay, save, incident, source-package, headless, listen,
dedicated, and installed Metal gates. It must not duplicate those systems.

## Stop and Review Conditions

Stop rather than silently adding infrastructure if:

- final approach to an activity slot needs continuous local steering beyond
  S12's destination contract;
- authored placement cannot support sixteen unique live NPC capsules;
- program steps require a behavior graph, open-ended planner, or blackboard;
- a crowd solver is proposed without measured blocking or collision evidence;
- population state starts owning NPC transforms, navigation routes, vitals, or
  encounter decisions;
- session authority gains role/activity policy rather than thin routing;
- private activity candidates would enter the normal protocol only for tools;
- steady-state activity creates allocation or misses the fixed-tick budget; or
- work expands into S14, S15, G1, MP7, or secondary platforms.

## Documentation Strategy

1. ADR-024 owns durable ownership, identities, semantics, and explicit
   nonclaims.
2. This document owns sequence, tests, acceptance, and stop conditions.
3. The evaluation-world document owns exact roster/site/slot intent, visual
   language, and human walkthrough.
4. [`../validation/s13-authored-population-and-sandbox-activity.md`](../validation/s13-authored-population-and-sandbox-activity.md)
   records commands, measurements, incidents, deviations, and phase reviews.

Every phase updates its checklist and the parent roadmap. Implementation
discoveries amend the proposed decision before broadening it. Historical
S8/S11/S12 records remain historical evidence rather than being rewritten as
though they already implemented S13.
