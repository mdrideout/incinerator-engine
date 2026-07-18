# ADR-019: Authoritative NPC Encounter And Durable Replacement

**Status:** Accepted

**Date:** 2026-07-14

**Amended:** 2026-07-15 after the playable-runtime corrective review

**Platform:** Apple Silicon macOS; Linux/SteamOS and Windows remain deferred

## Context

ADR-016 through ADR-018 establish one server-authoritative session shared by
solo, listen, and dedicated placements. S10 established authority-owned vitals,
player melee, death, and respawn. The first hostile-NPC product slice must add
perception, pursuit, NPC melee, death presentation, and population replacement
without moving autonomy into session coordination or creating a general AI
framework.

The existing NPC feature owns identity, route state, navigation, controller
lifetime, and transforms. Vitals owns health, damage application, and exactly
once death facts. Those ownership boundaries remain authoritative.

## Decision

### One bounded encounter feature owns NPC combat decisions

`npc_encounter` is a backend-neutral, fixed-capacity feature. It owns private
per-NPC state, sight and damage stimuli, deterministic target selection,
perception deadlines, attack sequences, windup/impact/recovery deadlines,
transition traces, and typed locomotion and damage outputs.

The state machine is explicit:

```text
patrolling -> pursuing -> attack_windup -> attack_recovery -> pursuing
                    \-> searching -> returning -> patrolling
```

Life/death is not duplicated in this state machine. Vitals remains its source
of truth. Clients receive observable state and deadlines but cannot submit an
NPC target, hit, damage, death, or replacement.

### Existing owners retain movement and health

The encounter feature issues only `hold`, `pursue`, `face_and_hold`, and
`resume_route` directives. The NPC feature applies them through its narrow
encounter port, projects pursuit onto the admitted cooked navigation graph,
and remains the only transform/controller owner.

NPC melee produces a typed `npc_melee` damage proposal for the following
declared vitals boundary. Vitals validates the exact source and target
incarnations and applies the stable proposal batch. A committed same-tick
proposal is not retroactively removed when another proposal kills its source;
this permits deterministic trades.

### Determinism and saturation are explicit

Candidates are enumerated by stable semantic identity. Target ranking is:
recent valid damage instigator, retained visible target, nearest other visible
target, squared distance, then stable identity. Jolt is used for bounded world
obstruction only; native result order never selects a target.

Ambient and engaged perception have exact authority-tick intervals. A global
16-query budget and a per-NPC 4-query budget defer work in stable NPC order.
All command, damage, cue, trace, replacement, and snapshot capacities are
bounded. Undrained outputs reject the next encounter frame before mutation;
there are no silent drops.

Only players projected onto an active admitted navigation district are eligible
targets. If an NPC controller or its navigation district becomes unavailable,
the encounter cancels any uncommitted windup, clears the target, resumes the
ordinary route owner, and records a typed transition instead of faulting the
authority.

### Death presentation and replacement have separate owners

On NPC death, encounter attack production stops, the NPC feature receives
`hold`, and the live controller is removed at its ordinary lifecycle boundary.
Session projection may retain a noninteractive, nonpersistent death proxy for
90 ticks. It is presentation state only and cannot participate in gameplay.

`sandbox_npc_replacement` separately owns durable pending replacement records,
the 300-tick initial delay, stable authored spawn candidates, collision/player
distance/player-visibility checks, typed retry reasons, and spawn handoff. It
owns no NPC entity or health. A successful spawn receives a new generation and
persistent identity; an unsafe or rejected spawn remains pending and retries.

### Persistence and compatibility cohorts are intentionally broken

At the initial 2026-07-14 S11 closeout, this greenfield change advanced the
cohorts to:

- simulation snapshot schema 10, including encounter records and durable
  replacement records;
- replay schema 7 and world-domain version 5, with an independent
  `npc_encounter` logical category; and
- the S11 semantic network/content cohort, including NPC health, life,
  encounter state, and combat deadlines. No committed intermediate artifact
  establishes a durable numeric protocol revision for this initial closeout.

Only canonical decision state enters persistence and replay digests.
Diagnostic counters and bounded transition history are intentionally excluded
because they are not restored. Saved locomotion intent is restored exactly at
the NPC boundary before simulation resumes.

### 2026-07-15 streamed-route and operational amendment

The corrective review intentionally supersedes only the affected same-cohort
formats:

- simulation snapshot schema 11 uses explicit `exact_prefix` and
  `deferred_rebuild` persisted-route modes;
- replay schema 8 records that canonical meaning; and
- the 2026-07-15 corrective cohort is semantic protocol revision 12 and adds
  authoritative wheel presentation, while `world-config-v5` and content cohort
  `s11` remain unchanged.

An exact prefix may retain and traverse its verified admitted edge while
farther content is inactive, but it cannot falsely complete a farther goal or
flip a patrol leg. A deferred rebuild retains an owner-aligned anchor and must
rebuild after the required content becomes active. Restored pursuit remains a
pending locomotion intent while its target cohort is inactive or its owner is
dormant, then installs after reload.

The persistent headless host now owns the complete replacement transaction. A
due record becomes a correlated NPC spawn; an exact spawn rejection defers it.
An exact successful spawn proceeds to vitals registration, and only the
matching `registered` outcome completes replacement. Registration rejection
submits a compensating despawn and defers only after that exact outcome. An
in-flight transaction is not quiescent and cannot be saved; the settled,
registered state cold-restores and resaves exactly.

The same persistent host owns restored encounter combat without stealing a
shared FIFO head. NPC melee uses the encounter feature's stable attack
correlation. The host peeks and commits an exact owned damage outcome and, when
lethal, its exact death event as one operational pair. Any unrelated damage or
death head remains retained fault evidence. A cold-restored windup completes,
reaches quiescence, and resaves through that contract.

## Consequences

- Solo, listen, and dedicated placements execute the same NPC authority.
- `AuthorityCore` gains only identity, reliable feedback, and presentation
  routing; perception, behavior, navigation, attack timing, and replacement
  policy remain outside it.
- The slice scales to the declared 64-NPC/16-participant validation ceiling by
  bounded, staggered work rather than a new scheduler, ECS, or job system.
- Automatic listen/dedicated product bootstrap is six NPCs, one per authored
  route node. The 64-NPC cohort remains a synthetic scale ceiling and
  deliberately permits co-location at those six nodes until a denser authored
  placement/crowd contract exists.
- The cooked graph remains sufficient for this slice. Recast/Detour is deferred
  until irregular city geometry demonstrates the need.
- Firearms, lag compensation, factions, wanted levels, squads, vehicles,
  Smart Objects, generic behavior trees/GOAP, and MMO services are deferred.

## Verification

Focused contracts cover target selection, occlusion and forgetting, damage
retargeting, occupied-vehicle disengagement, LOS saturation, windup/commit,
death cancellation, canonical cold restore, output saturation, safe
replacement retry, death-proxy expiry, and replacement generation. The S11
gate composes these with simulation snapshot/replay, session/fault/reconnect,
normal-product NPC-caused character death/cooldown/respawn correlation,
graphical host compilation, source-package closure, and inherited regression
tests.

## Detailed Plan

See
[`docs/design/s11-npc-encounter-combat-response.md`](../design/s11-npc-encounter-combat-response.md)
for the research position, characterization values, acceptance matrix, and
explicit deferrals.
