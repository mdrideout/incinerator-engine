# S10 Damage, Death, And Respawn Slice

**Status:** Implemented, independently reviewed, and accepted on Apple Silicon
macOS

**Date:** 2026-07-14

**Prerequisites:** Accepted M6 transactional authority cycle and accepted MP6
playable room flow

**Acceptance record:**
[`S10 Damage, Death, And Respawn Acceptance`](../validation/s10-damage-death-respawn.md)

**Current platform scope:** Apple Silicon macOS only; Linux/SteamOS and Windows
remain deferred product ports and add no requirements to this design.

## Outcome

Two players can damage, kill, observe, reconnect, and respawn through the same
server-authoritative semantics in solo, listen, and dedicated placements. NPCs
use the same vitals feature. A short-range authoritative melee action makes the
slice genuinely playable without prematurely adding firearms, ammunition,
full-world rollback, or lag compensation.

## Identity And Lifetime Model

Keep these identities distinct:

- `ParticipantId` is stable for the admitted session participant.
- A player lifecycle record is stable across avatar death and replacement.
- The physical avatar is a disposable runtime entity with a nonzero
  incarnation/generation.

Death replaces the avatar, not the participant or connection. Every avatar
target in protocol, prediction, outcomes, and replication includes its
incarnation so a delayed command or result cannot affect a replacement avatar.
Reconnect while dead restores the same lifecycle state and never grants an
implicit respawn.

## Feature Ownership

Do not create a generic ability/effect framework for this slice.

- `features/vitals` owns health, maximum health, life state, damage
  application, exactly-once death facts, snapshot records, diagnostics, and
  feature outcomes.
- A narrow player-lifecycle owner maps participant possession to one avatar,
  coordinates typed death cleanup, decides respawn eligibility, and creates the
  replacement incarnation.
- The initial melee producer validates an attack and emits a bounded internal
  damage proposal. It does not own or directly mutate health.
- Vehicle, interaction, character, district, NPC, replication, persistence,
  and presentation owners retain their existing state and expose only the
  narrow commands/outcomes required for death cleanup or respawn.

Split only the feature roots materially touched by these responsibilities. Do
not use S10 as a file-reorganization phase.

## Authority Pipeline

```text
client attack intent
  -> session admission and sequence/ownership/quota validation
  -> authoritative cooldown/range/line-of-sight query
  -> bounded damage proposal
  -> deterministic modifier/application phase
  -> damage outcome
  -> optional exactly-once death event
  -> typed ownership cleanup and possession removal
  -> replication/reliable feedback/durable decision
```

Clients submit attack and respawn intent only. They never submit a hit result,
target health, damage amount, death, or respawn transform.

A damage proposal records source/instigator, target avatar plus incarnation,
cause, authority tick, action correlation, integer base amount, and proposal
ordinal. Application produces applied amount and a typed disposition. Health
uses bounded integer units, clamps at zero, and emits at most one death event
for an incarnation.

## Same-Tick Ordering

Collect bounded proposals and apply them in one declared phase after relevant
physics queries/contacts. Registration order must not become an accidental game
rule. The initial stable ordering is:

1. target persistent/runtime identity;
2. cause priority;
3. source persistent/runtime identity;
4. source action sequence; and
5. proposal ordinal.

Simultaneous lethal or excessive damage therefore remains reproducible and
emits one death fact.

## Initial Playable Damage Source

The first player action is short-range melee:

- authority validates alive state, participant/avatar ownership, cooldown,
  sequence, and target tick;
- a bounded Jolt ray/shape query begins from the authoritative avatar pose;
- layer/body filters restrict eligible living targets;
- the closest valid target uses deterministic tie-breaking;
- the action can damage another player or an NPC; and
- the client may play speculative swing presentation but shows hit/death
  confirmation only after authoritative outcome.

Environmental, fall, vehicle-impact, projectile, firearm, armor, status-effect,
and friendly-fire policy are future producers over the same vitals boundary.

## Death Cleanup

The first lethal application makes the avatar non-alive for admission in that
cycle. Later input/actions targeting it are rejected. Typed cleanup then:

- neutralizes character and vehicle control;
- resets local prediction when the replicated death/removal is applied;
- releases an occupied vehicle using the existing safe exit/teardown policy;
- drops a carried object at a valid candidate or records an explicit teardown
  disposition if no placement is possible;
- detaches participant possession;
- removes authoritative controller/collision state at its safe structural
  boundary; and
- publishes death plus avatar removal without removing the participant.

Authoritative ragdoll simulation is deferred. Initial presentation may play a
bounded death animation or cosmetic client-only ragdoll from the authoritative
death fact.

## Respawn

The initial policy is a three-second authority cooldown followed by an explicit
player respawn request. Automatic respawn, hospitals, penalties, teams, beds,
and other game policy remain later slices.

Respawn admission validates dead state, cooldown, connection generation,
participant ownership, current avatar incarnation, feature capacity, and
publication capacity. The current permanently resident sandbox examines a
fixed, bounded engine-authored spawn catalog:

1. a Jolt narrow-phase capsule query finds no blocking shape;
2. the point has explicit clearance from living players and NPCs;
3. a deterministic score prefers distance from living threats; and
4. stable catalog order breaks ties.

Candidate iteration rotates from participant/incarnation to avoid permanent
candidate-zero bias. If no point is safe, the participant remains
`respawn_pending`, receives a typed `no_safe_spawn` result, and may explicitly
retry with a newer action sequence. The engine never force-spawns inside
another body. District-specific spawn availability and authored hazard volumes
belong to the later world/content policy that first introduces them; S10 does
not invent empty abstractions for those absent concepts.

The replacement avatar receives a new incarnation. Possession, initial vitals,
replication baseline/delta state, and reliable respawn outcome publish in the
same M6 authority batch.

## Replication, Prediction, Replay, And Persistence

- Replication projects avatar/incarnation, integer health/max health, and life
  state with explicit removal/replacement behavior.
- Damage feedback is relevance-filtered; the victim and eligible instigator
  receive reliable correlated outcomes while observers receive replicated
  authoritative state/events.
- Health and death are not client predicted. Local attack animation is
  speculative and disposable.
- Accepted-ingress replay records attack/respawn intent, including avatar
  incarnation, without recording transport packets. Snapshot comparison
  includes vitals/life state so a replay cannot silently accept a lifecycle
  divergence.
- Reconnect and join-in-progress reproduce the correct living, dead, or
  respawn-pending state and current incarnation.
- Session/world saves may capture current vitals/lifecycle state for sandbox
  restart. This is not a durable account death, inventory-loss, or progression
  policy.

## Lag Compensation Boundary

S10 does not add firearm lag compensation. When a later firearm slice requires
it, record a separate ADR for bounded rewind of compact historical hit volumes.
Do not rewind or clone the complete Flecs/Jolt world. Current ownership,
ammunition, rate, and eligibility remain authoritative even when historical hit
volumes are queried. Dynamic vehicles, doors, cover, and occluders require an
explicit fairness policy rather than accidental partial rewind.

## Completed Implementation Sequence

1. [x] Add narrow vitals and player-lifecycle contracts, integer health, life
   state, avatar incarnation, and exact snapshot/preflight rules.
2. [x] Add deterministic bounded damage proposal/application and exactly-once
   death outcomes for players and NPCs.
3. [x] Add typed vehicle/carry/character/possession cleanup and replicated avatar
   removal.
4. [x] Add the authoritative melee intent/query/outcome and client presentation.
5. [x] Add bounded spawn selection, cooldown, respawn request, new avatar
   incarnation, and client prediction reset/reinitialize.
6. [x] Add full/delta replication, JIP/reconnect, accepted-ingress replay, durable
   restart, diagnostics, and deterministic impairment coverage.
7. [x] Add installed two-client listen and dedicated playable evidence and retain
   complete M6/MP6/M5/M4/macOS regression.

## Acceptance

- Two real graphical clients can melee, damage, kill, and respawn each other in
  constrained listen and dedicated placements.
- Solo uses the identical admission, vitals, death, cleanup, and respawn
  semantics through the local link.
- NPCs use the same vitals boundary and can be valid damage sources/targets
  without client-owned AI decisions.
- Duplicate, stale, reordered, unauthorized, dead-avatar, and wrong-incarnation
  attack/respawn intents are harmless typed rejections.
- Simultaneous/overkill damage emits one death and cannot underflow health.
- Vehicle seat and carried-object cleanup cannot duplicate or strand ownership.
- Reconnect works while alive, dead, and respawn-pending; JIP sees exact life
  and incarnation state.
- Blocked or saturated spawn attempts return a typed result without overlap or
  partial possession; district/hazard selection remains explicitly outside the
  permanently resident S10 sandbox.
- Reliable result loss across reconnect is recovered through the M6 delivery
  ledger and duplicate receipt/application is idempotent.
- Accepted-ingress records include both new intent categories and avatar
  incarnation; replay snapshot comparison includes vitals/lifecycle state.
- Save/restart, fault harness, source package, cold authority, installed Metal,
  and all earlier accepted gates remain green.

The linked acceptance record contains exact final-tree commands and automated
two-client graphical evidence for both accepted placements.

## Explicit Deferrals

- Firearms, ammunition, projectiles, armor, status effects, and a generic
  ability framework.
- Lag compensation and historical dynamic-world occlusion policy.
- Authoritative ragdolls, corpse persistence, loot/inventory loss, hospitals,
  teams, scoring, and progression penalties.
- Public services, anti-cheat products, moderation, and account persistence.
- District-specific spawn catalogs, hazard-volume policy, and spawn-side game
  rules beyond collision/threat clearance in the current resident sandbox.

## Reference Influences

- [Unreal Gameplay Framework](https://dev.epicgames.com/documentation/en-us/unreal-engine/gameplay-framework-in-unreal-engine)
  provides a mature comparison for persistent player/controller state
  possessing a replaceable physical pawn.
- [Jolt narrow-phase queries](https://jrouwe.github.io/JoltPhysics/class_narrow_phase_query.html)
  support authoritative filtered ray/shape checks for melee and spawn safety.
- [Valve lag compensation](https://developer.valvesoftware.com/wiki/Lag_Compensation)
  is a later bounded-rewind reference, not an S10 implementation requirement.
