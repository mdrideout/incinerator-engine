# S11 Playable NPC Encounter And Combat-Response Slice

**Status:** Accepted on 2026-07-14; corrective implementation and automated
aggregate revalidation completed on 2026-07-15; manual real-window control
acceptance pending

**Date:** 2026-07-14

**Prerequisites:** Accepted S8 navigation/population, M6 transactional authority,
MP6 playable room flow, and S10 damage/death/respawn

**Current platform scope:** Apple Silicon macOS only. Linux/SteamOS and Windows
remain deferred product ports and add no requirements to this slice.

## 2026-07-15 Implementation Amendment

The playable-runtime audit keeps the S11 ownership model and tightens eight
contracts:

- canonical persistence at this amendment was `SnapshotV11` plus replay schema 8 under the
  unchanged `world-config-v5` cohort; semantic protocol revision 12 adds
  authoritative wheel presentation without changing the S11 content cohort;
- NPC route persistence distinguishes a verified `exact_prefix` from an
  owner-aligned `deferred_rebuild`, and restored pursuit remains pending across
  inactive target content or a dormant owner until reload;
- persistent-headless replacement is a correlated spawn, vitals registration,
  and, on registration failure, compensating-despawn transaction; replacement
  completes only after exact vitals registration and an in-flight transaction
  prevents a quiescent save;
- persistent-headless combat consumes only NPC-melee damage with the encounter
  feature's exact attack correlation. A lethal completion is committed only
  with its exact death-event mate, while unrelated FIFO heads remain retained
  fault evidence; cold-restored hostile combat reaches quiescence and resaves;
- logical gameplay publication is independent from transport preparation. The
  conservative 172-publication participant-cycle bound is retained for two
  cycles (344 records), drained under the 16-message wire ceiling, and an
  exhausted consumer is retired without faulting the room;
- automatic listen/dedicated bootstrap now creates six NPCs, one per authored
  route node, while 64 remains the synthetic scale ceiling. The normal embedded
  product uses a separate narrow initializer for one playable hostile after the
  player and west district are ready; and
- the normal graphical product separately correlates the authority-owned local
  player lifecycle across NPC-caused death, character despawn, cooldown,
  explicit respawn, new character spawn/projection, and post-respawn survival;
  and
- the cold `-Dproduct=headless` root explicitly imports the vitals and encounter
  contracts required by the shared S11 simulation graph; direct cold lifecycle
  and extracted-source gates must prove this independently of the client graph.

The later IC5 incident-reliability work advances the current replay cohort to
11 without changing `SnapshotV11` or `world-config-v5`: cohort 9 records vitals
commands, cohort 10 records authority-owned NPC replacement
schedule/defer/complete ingress, and cohort 11 records explicit player-requested
versus forced-cleanup drop purpose. This closes the exact death/repopulation
and interaction-intent replay boundaries exposed by graphical incident journeys.

## Outcome

Deliver one playable hostile-NPC encounter through the existing authoritative
solo, constrained listen, and dedicated placements. The slice must make the
current architecture carry real GTA-style gameplay pressure without adding
firearms, lag compensation, public services, or MMO infrastructure.

The accepted experience for S11 is:

- the player sees authoritative health, hit, death, cooldown, and respawn
  feedback;
- an authority-owned NPC perceives eligible players, becomes hostile, selects
  one deterministic target, chases, attacks, searches, disengages, and returns
  to its prior route;
- NPC melee emits a trusted damage proposal through the existing vitals
  boundary and never mutates health directly;
- damage causes a visible reaction and an immediate authority stimulus;
- NPC death stops control and combat exactly once, preserves a bounded death
  presentation, and schedules a safe population replacement with a new
  identity/incarnation; and
- restart, replay, reconnect, deterministic impairment, saturation, scale, and
  real graphical placements prove the same semantics.

S11 is a vertical `npc_encounter` feature and sandbox policy, not a general AI
framework.

## July 2026 Research Position

Production game AI still rests on mature, explicit techniques: hierarchical
state machines or event-driven behavior trees, timestamped perception stimuli,
bounded target scoring, authoritative navigation and combat, significance-based
update rates, and strong runtime inspection. The useful newer direction is to
combine those techniques with signal-driven work and data-oriented scheduling,
not to replace them with an opaque planner or learned runtime.

| Approach | July 2026 assessment | S11 decision |
|---|---|---|
| Explicit hierarchical state machine | Mature and robust | Adopt as Zig enums, fixed records, and explicit transitions |
| Event-driven behavior tree | Mature | Borrow event/timer wakeups; do not build a tree runtime or blackboard |
| StateTree-style hierarchy | Modern and increasingly mature | Borrow its state/transition shape; do not add an asset compiler or interpreter |
| Stimulus perception and forgetting | Mature | Adopt sight and damage stimuli with exact authority ticks |
| Utility/EQS candidate scoring | Mature | Adopt one bounded deterministic target-ranking function |
| Recast/Detour navigation | Mature and open source | Keep the admitted cooked graph for S11; reconsider when irregular city geometry requires a navmesh |
| Significance/update LOD | Mature | Adopt fixed ambient and engaged update rates |
| Signal-driven, data-oriented mass AI | Modern and rapidly evolving | Borrow budgets and wakeups; do not add another ECS, job graph, or parallel scheduler |
| Smart Objects/reservable affordances | Mature and relevant to a GTA-style world | Defer until the encounter loop is proven |
| Reinforcement learning or generative/LLM agents | Emerging | Keep out of deterministic combat authority and replay |

Unreal is only a comparison point, not a dependency. Its current
[StateTree](https://dev.epicgames.com/documentation/unreal-engine/overview-of-state-tree-in-unreal-engine?lang=en-US)
combines hierarchical states with behavior-tree-like selection, while its
[behavior trees](https://dev.epicgames.com/documentation/en-us/unreal-engine/behavior-tree-in-unreal-engine---overview)
are event-driven to avoid evaluating every branch every frame. Its
[AI Perception](https://dev.epicgames.com/documentation/en-us/unreal-engine/ai-perception-in-unreal-engine)
and [Environment Query System](https://dev.epicgames.com/documentation/en-us/unreal-engine/environment-query-system-overview-in-unreal-engine)
provide mature references for expiring stimuli and bounded candidate
filtering/scoring.

The [Unreal 5.8 Mass changes](https://dev.epicgames.com/documentation/unreal-engine/unreal-engine-5-8-release-notes)
show the modern high-scale direction: signals, sparse fragments, off-thread
creation, and finer dependency scheduling. That is evidence to retain bounded,
data-oriented records and explicit wakeups, not evidence that a 64-NPC slice
needs a parallel framework.

## Source Of Truth

Solo, listen, and dedicated placements run the same NPC authority. The
authority owns:

- eligible combatant observations and current incarnations;
- perception results, memory, hostility, target choice, and behavior state;
- navigation desire, attack windup/impact/recovery ticks, and cooldown;
- attack validation, damage proposals, health, death, and replacement policy;
- canonical persistence, replay state, and diagnostics; and
- the observable combat state projected to clients.

Clients own presentation only. They may animate a received windup or show a
cosmetic hit flash, but they never submit NPC perception, a target, an NPC hit,
damage, death, or replacement.

## Ownership And Boundaries

```text
authoritative combatant observations ----> npc_encounter
Jolt obstruction queries ----------------> npc_encounter
npc_encounter -- typed locomotion -------> existing NPC feature
npc_encounter -- damage proposal --------> existing vitals feature
vitals -- damage/death facts ------------> encounter + session authority
NPC + encounter + vitals views ----------> replication/presentation
NPC death/removal ------------------------> sandbox population policy
population policy -- safe spawn request -> existing NPC feature
```

### `npc_encounter` owns

- fixed per-NPC hostility and encounter state;
- private perception memory and deterministic target selection;
- state transitions and transition reasons;
- attack sequence, windup, impact, recovery, and cancellation;
- copied immutable presentation state;
- canonical encounter records, replay digest contribution, and diagnostics;
- bounded commands, outcomes, cues, and their saturation policy.

### Existing NPC feature continues to own

- persistent NPC identity and generational runtime/controller lifetime;
- semantic route, route cursor, district owner, and residency behavior;
- `CharacterVirtual` movement and transform publication;
- spawn, locomotion, goal, transfer, and despawn outcomes.

The encounter feature receives no controller, Flecs component, district-private
state, or mutable route slice. It issues a narrow queued locomotion directive
such as pursue, face/hold, or return-to-route. The NPC feature applies that
directive at its own boundary and remains the only movement owner.

### Existing vitals feature continues to own

- health, maximum health, life state, and exact target incarnation;
- deterministic bounded damage application;
- exactly-once death facts; and
- canonical vitals records and diagnostics.

The encounter feature emits an explicit `npc_melee` proposal. It does not
reuse client `MeleeAction`, directly change health, or create a generic
ability/effect system.

### Sandbox population policy owns

- desired authored encounter population;
- bounded pending replacement records and deadlines;
- safe replacement candidate selection and retry reason; and
- durable/replay state for pending replacements.

It owns no NPC entity, controller, health record, or replicated identity. The
existing stateless population planner may remain a pure command producer; the
new timed replacement policy is a distinct sandbox owner rather than hidden
state added to that planner.

### Session authority owns only session-facing coordination

`AuthorityCore` may map participants, current avatars, replicated identities,
and reliable victim/attacker feedback. It must not gain NPC perception,
behavior, target, navigation, attack-timer, or replacement policy.

This slice activates architecture finding A-F023. If S11 requires more than
thin identity/result routing in `AuthorityCore`, extract only the cohesive
combat-feedback or roster owner that gains an independent lifecycle and test
seam. Do not reorganize the entire authority module or create a universal
combat context.

## Behavior State Model

Use one explicit, hard-coded state machine:

```text
patrolling
  -> pursuing
  -> attack_windup
  -> attack_recovery
  -> pursuing

pursuing
  -> searching
  -> returning
  -> patrolling
```

Rules:

- `dead` is not duplicated as an encounter state; vitals owns life state.
- A visual hit reaction is initially a sequenced cue and damage stimulus, not
  a top-level state. A future stagger mechanic must add an explicit authority
  deadline only when it changes gameplay.
- Every transition records authority tick, previous state, next state, and one
  typed reason.
- All timers are authority ticks; wall-clock time and presentation frames are
  forbidden inputs.
- No generic blackboard is introduced. A fixed `PerceptionMemory` retains only
  the current target identity/incarnation, last-seen tick and position, recent
  damage instigator/tick, and exact expiry deadlines.

## Perception, Hostility, And Target Selection

S11 has exactly two authority stimuli:

1. **Sight:** candidate eligibility, horizontal distance, field of view, then
   an authoritative world-obstruction query.
2. **Damage:** the validated damage source becomes an immediate stimulus.

Hearing, factions, civilian disposition graphs, wanted levels, squads, and
shared threat tables are outside S11. The installed S11 cohort has one authored
`hostile_to_players` disposition.

Target ranking is a deterministic tuple:

1. recent valid damage instigator;
2. retained current visible target;
3. nearest other visible eligible player;
4. squared distance; and
5. stable participant/avatar identity.

Candidates are filtered before a physics query by current incarnation, alive
state, S11 attack eligibility, resident/relevant world area, sight radius, and
facing cone. A target switch occurs only when the current target is invalid or
a candidate has a strictly higher discrete threat tier; this prevents
distance-noise target thrashing.

S11 initially treats an occupied vehicle as non-attackable and disengages or
selects another target. Vehicle occupant damage and vehicle combat require a
later explicit policy.

## Jolt Query And Determinism Policy

The current characters are `CharacterVirtual` instances, which are not normal
broad-phase bodies. S11 therefore enumerates bounded authoritative player/NPC
candidates and uses Jolt only for world obstruction, matching the existing
authoritative melee approach.

Jolt documents that broad-phase queries are not deterministic and that
narrow-phase results are consistent while result order may vary. Every
gameplay-relevant collected result must therefore be filtered against actual
bounds where required and sorted by stable semantic identity before use. No
callback or native handle order becomes a target-selection rule. See
[Jolt architecture and determinism](https://jrouwe.github.io/JoltPhysics/)
and [CharacterVirtual](https://jrouwe.github.io/JoltPhysics/class_character_virtual.html).

## Scheduling And Damage Ordering

S11 does not add a generic dependency scheduler.

- Perception and behavior evaluate a stable completed authority state.
- Locomotion directives use a bounded typed queue and become eligible on the
  following fixed tick, independent of same-phase registration order.
- Damage crosses a trusted `DamageProposalSink`-sized boundary into vitals'
  declared deterministic application phase; encounter code cannot call a
  direct health mutation.
- Damage outcomes/death facts become encounter stimuli and cleanup work at the
  next declared boundary.
- Stable semantic identity and action sequence order all same-tick proposals.

S11-A must prove the exact phase/queue order with a focused executable test.
No gameplay result may change when unrelated feature registration order
changes. This is the S11 response to architecture finding A-F005; it does not
authorize a schedule DAG.

Attack commitment is explicit: a source that is already dead or stale before
impact admission cannot produce damage. Once a proposal is admitted for an
authority tick, another proposal killing its source in that same deterministic
vitals batch does not retroactively erase the committed impact. This permits a
well-defined same-tick trade rather than making proposal sort order an
accidental cancellation rule.

## Navigation And Pursuit

Use the admitted cooked navigation graph for S11:

- project the target to a bounded nearest admitted route node;
- build a bounded route using the existing route contract;
- replan on target movement threshold, route invalidation, district generation
  change, or a fixed maximum interval;
- use direct final-segment steering only when the local segment is clear;
- preserve an encounter origin/leash and the NPC's prior semantic patrol goal;
- search the last-known position for a bounded duration, then return to the
  saved route.

Do not integrate a navmesh for this slice. Recast/Detour remains the mature
open-source candidate when real city geometry, path corridors, or streamed
navigation tiles require it. A later Zig integration should use an
engine-owned narrow C ABI, and DetourCrowd must never become a second transform
authority beside Jolt. See
[Recast/Detour](https://github.com/recastnavigation/recastnavigation) and its
[path-corridor model](https://github.com/recastnavigation/recastnavigation/blob/master/DetourCrowd/Source/DetourPathCorridor.cpp).

## NPC Melee Contract

An NPC attack:

1. selects one exact target identity/incarnation;
2. enters a replicated windup with an authority impact tick;
3. faces/holds or pursues through the NPC locomotion port;
4. at impact validates source life/incarnation, target life/incarnation,
   attack eligibility, range, facing, and line of sight;
5. submits one bounded `npc_melee` damage proposal with an NPC-owned monotonic
   action sequence and correlation;
6. enters recovery whether the attack hits or misses; and
7. records one typed hit, miss, stale, occluded, out-of-range, source-dead,
   target-dead, or saturated disposition.

Clients never report the hit. Server-side NPC melee needs no lag compensation
because the authority owns both the attacker and validation.

## Death, Reaction, And Population Replacement

Damage applied to a living NPC emits a sequenced reaction cue and a damage
stimulus. It may retarget the instigator but does not automatically grant a
gameplay stagger.

On death:

- vitals emits one death fact for the exact incarnation;
- encounter decision/attack production stops immediately;
- locomotion is neutralized and the authoritative NPC/controller is removed at
  the existing safe lifecycle boundary;
- a presentation-only death proxy may linger for a bounded authored duration
  without health, input, authority collision, or persistence as a living NPC;
- population policy retains one pending replacement deadline;
- replacement checks a fixed authored spawn catalog for collision, distance
  from living players, and player visibility in stable candidate order;
- no-safe-spawn retains the request and retries later with a typed reason; and
- a successful replacement receives a new persistent identity/incarnation.

The dead NPC is never silently resurrected. Living NPC capacity, death-proxy
capacity, pending replacement capacity, and their overflow behavior are
declared separately.

## Replication And Presentation

Observable NPC combat projection contains only what a client needs to render:

- behavior state and state-enter tick;
- attack impact and recovery/ready ticks;
- health, maximum health, life state, and incarnation;
- sequenced hit-reaction/death cues; and
- ordinary generational removal/replacement state.

Private target scores, candidate lists, last-seen memory, and perception
internals are not protocol state. Target identity is replicated only if a
specific presentation need is proven; facing and observable state should be
sufficient for the initial slice.

Presentation adds:

- local authoritative health;
- player melee cooldown from an authority `ready_tick`;
- bounded nondirectional damage flash for a struck player (the current protocol
  does not carry an impact source vector);
- NPC health while recently damaged or deliberately targeted;
- NPC windup, hit reaction, death, and replacement presentation;
- death overlay and authoritative player respawn countdown; and
- explicit `no_safe_spawn` feedback rather than a silent failed respawn.

NPC transform and combat projection currently use the accepted global 10 Hz
NPC lane. Windup state and deadlines provide snapshot fallback, while victim
damage/life results remain reliable and idempotent; ordinary NPC swing
animation is never an unbounded reliable event stream. A distinct engaged-NPC
priority budget is deferred until measured readability or density requires it.

## Debugging And Observability

S11 debugging is acceptance scope, not later polish. The immutable per-NPC
inspection contract shows:

- state, state-enter tick, and last transition reason;
- target identity/incarnation and eligibility;
- last-seen position/tick and expiry;
- recent damage instigator/tick;
- latest sight/LOS result and rejection reason;
- current route, waypoint, saved patrol goal, leash, and replan reason;
- windup, impact, recovery, and ready ticks; and
- perception/LOS budget use and deferral.

Developer overlays draw sight and melee ranges, leash, field-of-view edges,
last-known target position, and the current route for the bounded encounter
population. A bounded transition trace retains tick/from/to/reason for
post-fault inspection.

Aggregate metrics include state population, candidates considered, LOS queries
and deferrals, acquisitions, target switches/losses, replans, attacks
attempted/hit/cancelled, damage, deaths, proxies, replacements, queue high
water, saturation, and maximum decision age.

This follows the mature pattern of network-aware live inspection plus recorded
traces represented by Unreal's
[Gameplay Debugger](https://dev.epicgames.com/documentation/unreal-engine/using-the-gameplay-debugger-in-unreal-engine),
[Visual Logger](https://dev.epicgames.com/documentation/en-us/unreal-engine/visual-logger-in-unreal-engine),
and [StateTree debugger](https://dev.epicgames.com/documentation/unreal-engine/statetree-debugger-quick-start-guide).

## Persistence, Replay, Reconnect, And Faults

Canonical encounter state includes hostility, behavior state, target
identity/incarnation, perception expiry values required to resume behavior,
attack sequence/deadlines, saved patrol/encounter origin, and pending
replacement records. Runtime controller handles, native query results,
borrowed slices, and debug trace history are not serialized.

An `exact_prefix` cursor retains a verified admitted edge. It may traverse that
edge while farther content is inactive, but may not manufacture a farther goal
completion or patrol-leg change. A `deferred_rebuild` cursor retains only an
owner-aligned anchor and rebuilds when the required cohort is active. Restored
pursuit likewise remains a pending intent until its target route and owner are
available.

Accepted-ingress replay continues to record player-originated intent rather
than network packets. Authority-owned NPC behavior is reproduced from the same
accepted player inputs, content/tuning fingerprint, fixed tick, canonical
state, and deterministic query ordering. Replay adds a separate
`npc_encounter` digest category so an altered stimulus, target decision,
attack, or replacement diverges at the first responsible tick.

Network impairment must not change server NPC decisions. It may delay what a
client observes, but the client must converge through later state. Duplicate
or replayed reliable damage/life feedback is idempotent.

Reconnect/JIP cases include pursuit, windup, recovery, player dead, NPC death
proxy, and pending replacement. A reconnect never restarts a cooldown, revives
an NPC, or repeats an already applied attack.

## Initial Characterization Values

These are starting calibration for the first acceptance cohort, not permanent
game balance or a stable public API. They live in validated, fingerprinted
authored configuration.

| Parameter | Initial value |
|---|---:|
| Sight radius / field of view | 20 m / 120 degrees |
| Last-seen memory | 180 ticks / 3 seconds |
| Pursuit leash | 30 m from encounter origin |
| Ambient / engaged perception | 2 Hz / 10 Hz |
| Route replan maximum interval | 12 ticks / 5 Hz |
| Melee range | 2.25 m |
| Attack windup | 30 ticks / 0.5 seconds |
| Attack recovery | 45 ticks / 0.75 seconds |
| Attack damage | 20 health |
| Death presentation linger | 90 ticks / 1.5 seconds |
| Replacement delay | 300 ticks / 5 seconds |

The initial fixed global LOS budget is 16 queries per authority tick in stable
NPC order. Measurement may change that value before acceptance, but saturation
must remain typed and deterministic. Movement and attack deadlines remain 60
Hz even when perception is staggered.

## Implementation Sequence

### S11-A — Contract, baseline, and ordering proof

- [x] Record the S11 ADR with ownership, state machine, attack commitment,
  capacities, scheduling, persistence schema, tuning fingerprint, and explicit
  deferrals.
- [x] Add the backend-neutral encounter contract and one hostile-NPC headless
  authority test without presentation or protocol work.
- [x] Add the narrow combatant-observation, NPC-locomotion, world-visibility,
  damage-proposal, and population-policy capabilities.
- [x] Prove next-tick locomotion and declared damage ordering without relying
  on same-phase registration order.
- [x] Characterize the current S10 authority baseline before adding encounter
  cost.

### S11-B — Perception, target selection, and pursuit

- [x] Implement sight/damage stimuli, forgetting, deterministic target ranking,
  target stickiness, and exact incarnation validation.
- [x] Implement patrol-to-pursuit, search, leash, disengagement, and
  return-to-route through the existing NPC owner.
- [x] Add deterministic staggering, global/per-NPC query budgets, typed
  saturation, transition traces, and aggregate diagnostics.
- [x] Prove district unload/reload, route invalidation, target death,
  disconnect, and occupied-vehicle disengagement.

### S11-C — NPC attack, reaction, death, and replacement

- [x] Implement windup, impact-time validation, recovery, NPC action sequence,
  explicit dispositions, and `npc_melee` damage through vitals.
- [x] Add damage stimuli/reaction cues and exactly-once death cancellation.
- [x] Add bounded death presentation, safe delayed replacement, retry, new
  identity/incarnation, capacity preflight, and durable replacement state.
- [x] Prove simultaneous/overkill/trade semantics and full queue saturation
  without partial authority state.

### S11-D — Replication, presentation, and debugging

- [x] Extend full/delta/JIP projection with observable encounter state and
  explicit generational removal/replacement.
- [x] Add local/NPC health, hit, cooldown, windup, death, respawn, and
  no-safe-spawn feedback through a client-owned view model.
- [ ] Add a measured engaged-NPC replication priority without starving required
  ambient convergence; the current implementation deliberately retains one
  bounded 10 Hz NPC lane.
- [x] Add immutable per-NPC inspection data, authority-only spatial overlays,
  transition history, and budget counters without exposing authority mutation.
- [ ] Add a graphical selected-NPC inspector when a concrete developer workflow
  needs it; the present editor exposes aggregate/overlay evidence, not a full
  semantic selection workflow.

### S11-E — Durability, replay, reconnect, faults, and scale

- [x] Add canonical encounter/replacement records, strict cold preflight,
  restart, resave, and a separate replay digest category.
- [x] Prove clean replay plus exact first-category divergence after an altered
  stimulus/configuration.
- [x] Prove deterministic nominal/adverse/blackout impairment, reliable result
  replay/idempotency, and eventual client convergence.
- [ ] Add renderer-neutral semantic reconnect/JIP assertions for every pursuit,
  windup, recovery, death, and pending-replacement midpoint. Current coverage
  proves generic convergence plus focused canonical state survival, not every
  graphical midpoint as one matrix.
- [x] Characterize 64 NPCs and up to 16 synthetic participants, including the
  fully engaged worst case, without loosening an existing performance ceiling
  silently.

### S11-F — Installed graphical acceptance and independent review

- [x] Solo: the ordinary product host proves its hostile crosses the local
  session/authority path and correlates death, cooldown, replacement, and the
  new projection without a bootstrap fault, while the installed validation
  host proves perception, chase, mutual damage, death, respawn, replacement,
  and complete combat presentation at both accepted render cadences.
- [x] Listen: host and guest graphical clients observe one authoritative target
  choice, damage, death, reconnect, and replacement through local plus real GNS
  links.
- [x] Dedicated: one cold headless authority plus two real graphical clients
  proves the same behavior over real GNS.
- [x] Run installed fault profiles, source-package, cold-authority, save/replay,
  architecture, macOS, and complete inherited regression gates.
- [ ] Finalize the post-S11 aggregate evidence after the completed architecture,
  correctness, dead-code, documentation-drift, performance, and playable
  reviews; retain all deferred P2 findings in the living architecture register.

## Acceptance Matrix

| Concern | Required evidence |
|---|---|
| Authority | Clients cannot choose target, report NPC hits, damage, death, or replacement |
| Perception | Occlusion, forgetting, damage retarget, tie-break, target death/disconnect, and budget deferral are deterministic |
| Behavior | Patrol, pursue, windup, recovery, search, disengage, and return transitions have exact reasons and deadlines |
| Combat | Impact validates exact incarnations, life, range, facing, LOS, cooldown, sequence, and capacity; damage flows only through vitals |
| Death/replacement | One death, no post-death attack, bounded presentation, safe retry, and a new replacement identity |
| Placement | Solo, constrained listen, and dedicated use the same authority semantics; dedicated means a headless server plus graphical clients |
| Replay/restart | Fresh authority reproduces encounter/damage/replacement state and classifies the first divergence |
| Reconnect/JIP | Generic convergence and canonical state survival are accepted; a complete semantic midpoint matrix remains recorded P2 work |
| Faults | Network faults alter observation latency only; authority decisions and eventual state remain correct |
| Scale | 64 NPC/16 participant synthetic ceiling, query/queue saturation, zero silent drops, resource drain, and measured p99/RSS/allocation evidence |
| Debugging | Immutable per-NPC evidence explains perception, choice, attempt, and transition; a graphical selected-NPC workflow remains recorded P2 work |

## Architecture Review Gates

- A-F005: no same-phase registration order becomes a combat rule; use typed
  next-tick directives and one declared vitals proposal boundary.
- A-F011: retain fixed-array iteration and single-threaded authority until the
  S11 fully engaged measurement demonstrates a locality or scheduling need.
- A-F013: keep sandbox hostility/tuning/replacement policy out of the reusable
  kernel. S11 does not by itself create the separately licensed game package.
- A-F023: keep NPC autonomy out of `AuthorityCore`; extract only a new cohesive
  owner with a real lifecycle/test seam.
- No new generic AI, scheduler, ECS replication, ability, faction, navigation,
  or service framework is accepted merely because S11 could consume it.

## Explicit Deferrals

- Firearms, ammunition, projectiles, armor, status effects, and lag
  compensation.
- Vehicle occupant damage, NPC vehicle use, traffic, crashes, and vehicle
  combat.
- Hearing, factions, wanted levels, police dispatch, squads, cover tactics,
  civilian schedules, dialogue, or social memory.
- Generic behavior trees, GOAP, utility frameworks, blackboards, ability/effect
  systems, or environment-query languages.
- Recast/Detour integration, crowd/RVO ownership, dynamic navmesh carving, and
  city-scale path streaming.
- Smart Objects, interaction reservation, cover slots, doors, shops, or world
  affordance databases.
- Parallel AI execution, another ECS, GPU crowd simulation, learned policies,
  reinforcement learning, or generative/LLM agents. The open-source
  [Unity ML-Agents](https://github.com/Unity-Technologies/ml-agents) and
  [Generative Agents research](https://arxiv.org/abs/2304.03442) remain
  research/authoring references rather than combat-authority dependencies.
- Authoritative ragdolls, persistent corpses, loot, inventory loss, scoring,
  progression, hospitals, public services, anti-cheat products, or MMO
  infrastructure.

The mature next candidate after S11 is a bounded Smart Object/affordance slice,
because spatial query plus reservation lets players and NPCs share GTA-style
world interactions without moving execution logic into the object. See the
[Smart Objects overview](https://dev.epicgames.com/documentation/unreal-engine/smart-objects-in-unreal-engine---overview?lang=en-US).
