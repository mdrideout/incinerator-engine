# S11 Playable NPC Encounter And Combat-Response Acceptance

**Status:** Accepted on 2026-07-14; post-acceptance corrective implementation
and automated aggregate revalidation pass; manual real-window control acceptance
is pending

**Accepted:** 2026-07-14

**Platform:** Apple Silicon macOS only

**Design:**
[`docs/design/s11-npc-encounter-combat-response.md`](../design/s11-npc-encounter-combat-response.md)

**Decision:**
[`ADR-019`](../adr/019-authoritative-npc-encounter-and-replacement.md)

**Performance:**
[`docs/performance/s11-baseline.md`](../performance/s11-baseline.md)

## Accepted Outcome

S11 delivers one playable hostile-NPC encounter through the existing solo,
constrained listen, and dedicated authority placements. The authority owns
perception, deterministic target selection, pursuit, search, disengagement,
attack commitment, damage, death, and replacement. Clients render replicated
state and feedback; they cannot choose an NPC target or report an NPC hit,
damage, death, or replacement.

The implementation remains a bounded vertical slice rather than a generic AI
framework:

- `npc_encounter` owns fixed state-machine decisions, stimuli, deadlines,
  transition evidence, and typed locomotion/damage/cue outputs;
- `npc` remains the sole transform, navigation, route, and controller owner;
- `vitals` remains the sole health, damage, and exactly-once death owner;
- sandbox replacement policy owns durable delay, safe candidate evaluation,
  retry, and spawn handoff without owning an NPC entity;
- session authority routes identity, reliable feedback, death proxies, and
  generational projection without owning autonomy; and
- the client owns health, hit, cooldown, windup, death, respawn, and
  replacement presentation.

## Gameplay And Authority Evidence

- Sight and damage stimuli, exact incarnation eligibility, deterministic target
  ranking/stickiness, LOS occlusion, forgetting, leash, route invalidation,
  target death/disconnect, and occupied-vehicle disengagement have focused
  feature tests.
- Players outside an active admitted navigation district are ineligible, and
  NPC controller/navigation unavailability cancels an uncommitted windup and
  returns control to the route owner through a typed transition rather than an
  authority fault.
- Locomotion is a next-tick typed directive into the NPC owner. NPC melee is a
  typed proposal at the declared vitals boundary, so feature registration order
  is not a hidden combat rule.
- Windup, impact-time range/facing/LOS/life validation, recovery, action
  sequencing, simultaneous trade, overkill, death cancellation, and bounded
  saturation are deterministic.
- NPC death creates one bounded noninteractive proxy, schedules one durable
  replacement, and eventually spawns a new entity generation only at an
  authored candidate checked against rigid collision plus live-player distance
  and visibility.
- Full, delta, and join-in-progress protocol revision 12 projections include
  health, life, encounter state, deadlines, removals, and replacement
  generations. NPC projection currently uses the accepted bounded global 10 Hz
  lane; an engaged-priority lane remains a measured P2 decision rather than an
  implemented claim.

## Persistence, Replay, Reconnect, And Faults

The current Simulation snapshot schema 11 stores canonical encounter,
replacement, and explicit persisted-route-mode records with strict cold
preflight and exact resave. Replay schema 8 under the unchanged
`world-config-v5` domain includes a separate `npc_encounter` digest category.
Diagnostic counters and transition history are deliberately noncanonical and
excluded from restore/digests.

The persistent headless composition also consumes restored replacement work:
due records advance from ready to a correlated NPC spawn and then exact vitals
registration. Spawn rejection defers the record. Vitals rejection submits a
compensating despawn and defers only after that exact outcome; only a matching
`registered` outcome completes replacement. Unrelated FIFO heads remain fault
evidence, and an in-flight transaction prevents a quiescent save. Settled,
registered state survives another cold resave/restore cycle without leaving an
unowned feature outcome.

Restored hostile combat uses a separate exact operational correlation. The
headless host peeks and commits only encounter-owned NPC melee damage and, for
a lethal completion, its exact death event. Unrelated damage/death FIFO heads
remain fault evidence. A cold-restored windup completes, kills, reaches
quiescence, and resaves through that boundary.

NPC route persistence distinguishes `exact_prefix` from `deferred_rebuild`.
Farther inactive content cannot falsely complete a goal or flip a patrol leg,
and a restored pursuit remains pending while its target cohort is inactive or
its owner is dormant, then installs after reload.

Logical gameplay publication is independent from the 16-message
per-connection/tick wire ceiling. One conservative participant cycle derives a
172-publication bound; the replay ledger retains two cycles (344 records) and
an ordered cursor drains it over quota-safe ticks. A participant that exhausts
that bounded window is retired without faulting the room or withholding a life
fact from healthy consumers.

The inherited MP4-D impairment gate proves clean, nominal, adverse, blackout,
join-in-progress, reconnect, saturation, and 64-NPC convergence for the shared
authority/projection path. The MP6 lifecycle gate proves clean through blackout
room lifecycle behavior. S11's focused authority, canonical restore, replay,
reliable-result idempotency, death-proxy, and replacement-generation tests
cover the new semantics on those accepted transport/session boundaries.

## Playable And Developer Evidence

- The normal product uses the same typed local client/authority link. A narrow
  initializer waits for the local player and west district, submits one initial
  hostile through the host-managed authority, and correlates its exact result.
  A separate narrow product-character owner correlates the authority-owned
  local life fact, character despawn, respawn result, new character spawn, and
  new avatar/HUD projection; a renderer-free host test proves NPC-caused death,
  cooldown, explicit respawn, and post-respawn survival.
- The installed validation host separately proves the complete solo combat
  presentation at 240 Hz and 80 Hz: NPC spawn, melee hits, player death and
  respawn, NPC death, character/NPC health bars, bounded character/NPC hit
  flashes and expiry, NPC windup, melee cooldown, respawn countdown/ready,
  retained dead-avatar anchor, respawned character, and NPC death rendering.
  `Q` requests player melee and `R` requests respawn in ordinary play.
- The graphical listen process gate composes one local host client and one real
  GameNetworkingSockets guest. Both observe the same authoritative NPC death
  and replacement generation.
- The graphical dedicated process gate runs a cold headless authority and two
  real GameNetworkingSockets clients. An attacker kills an NPC; an observer
  sees the death proxy; either client uses the real authoritative respawn flow
  if killed by the encounter; both converge on the replacement generation.
- Immutable per-NPC inspection exposes state, transition reason, target,
  last-seen evidence, route, deadlines, and LOS budget. Aggregate diagnostics
  expose state/candidate/query/attack/death/replacement/saturation counts.
  Authority-only bounded debug geometry draws sight/melee/leash ranges, FOV,
  last-known position, and current route without widening the network schema.

## Scale Evidence

The fresh-process paired `ReleaseFast` measurement exercises 64 pursuing NPCs,
16 eligible participants, fully consumed LOS budget, deterministic deferral,
and output draining for 16,384 measured ticks per trial. The worst scale p99 is
49,083 ns, worst paired RSS delta is 81,920 bytes, fixed encounter storage is
147,160 bytes, and workload allocation is zero. This is safely inside the
retained 4.166 ms p99 and 8 MiB RSS ceilings.

## Acceptance Commands

```sh
zig fmt --check build.zig src tools/s11_measure.zig
zig build verify-s11 -Deditor=true -j1 --summary failures
zig build measure-s11 -Deditor=false -Doptimize=ReleaseFast
zig build test -Deditor=false -j1 --summary failures
zig build test -Deditor=false -Doptimize=ReleaseFast -j1 --summary failures
```

`verify-s11` composes focused encounter/replacement/vitals, simulation,
snapshot, replay, session, developer-diagnostics, measurement-methodology,
MP4-D fault/reconnect/scale, MP6 lifecycle, architecture, validation,
source-package, normal-product encounter lifecycle, installed solo Metal, and
graphical listen/dedicated process gates.

## Independent Review Findings Closed

1. Canonical digests initially included nonrestored metrics. They now contain
   decision state only, preserving exact cold restore/replay semantics.
2. Stable NPC iteration could starve later identities under a saturated global
   LOS budget. Tick-derived deterministic rotation now gives bounded fair
   service while preserving reproducibility; the 64/16 test fixes the contract.
3. Contract and policy dependency classifications were tightened in the source
   architecture gate instead of allowing broad host dependencies.
4. The initial replacement candidates all remained visible in one small
   district. Each authored slot now retains two local candidates and one
   deterministic candidate in the alternate active district, so an unsafe
   visible death location cannot permanently prevent replacement. A focused
   regression and both graphical process gates prove the correction.
5. The inherited MP4-D gate exposed that an out-of-navigation player could be
   perceived before route projection failed and faulted authority. Eligibility
   now requires an active admitted navigation position; unavailable NPC
   controllers cancel uncommitted attacks and return to patrol with a typed
   reason. Focused and inherited fault-profile tests prove the correction.
6. Repeated graphical execution exposed observers that could die before
   crossing replacement relevance. The dedicated clients already used the
   production authoritative cooldown/respawn flow; the local listen-host
   observer now does as well. Both process windows cover convergence after that
   lifecycle instead of relying on survival timing.
7. The ReleaseFast closeout found an inherited room-ticket test comparing the
   undefined tail of a fixed-capacity member array. The codec was correct; the
   test now compares only semantic intent, `member_count`, and the initialized
   member slice. Debug and ReleaseFast session/full regressions pass.
8. A post-acceptance interactive product pass found that the embedded solo host
   submitted raw digital diagonals while network clients used a normalized
   character vector. Character movement now has one explicit normalization
   boundary, vehicle axes remain independent, and a renderer-free regression
   fixes the session contract. Expected out-of-range `E`/`F` and lifecycle
   action rejections are also classified without swallowing protocol, queue,
   link, or authority faults.
9. The inherited MP3 loopback then exposed an NPC whose encounter route crossed
   a district while residency still validated its patrol route. Residency now
   follows the active encounter route, hold/attack preserves an owner anchor,
   and return rebuilds the base goal route from that anchor. A focused
   cross-owner pursue/hold/resume regression and the inherited loopback prove
   the correction.
10. The complete Debug build compiled a backend-neutral replay-contract test
    outside the narrower S11 graph and found that its fixture omitted the new
    encounter digest. The fixture now fixes category tag 8 and exact field
    routing; complete Debug and ReleaseFast builds pass.
11. The macOS play-through and its follow-up audit found presentation,
    blocker/spawn, facing, wheel, driver-location, action-ordering, streamed
    route-residency, and persistent-headless handoff defects that the original
    S11 closeout did not cover. Their repairs and exact final evidence are
    tracked in
    [`post-s11-runtime-corrective-audit.md`](post-s11-runtime-corrective-audit.md).
12. Compact restored routes could falsely treat a truncated inactive-content
    prefix as a completed goal, and restored pursuit could disappear while its
    target or owner was unavailable. Explicit exact/deferred route modes,
    pending pursuit, Snapshot V11/replay 8, and navigate/patrol/pursuit restore
    tests now fix that contract.
13. Reliable gameplay facts formerly competed with the immediate wire quota.
    Derived two-cycle retention, ordered cursor drain, isolated slow-consumer
    retirement, and exact burst/reconnect/client/presentation FIFO tests now
    separate logical publication from transport preparation.
14. The validation compositions contained the encounter while ordinary
    `zig build run` did not. A narrow normal-product initializer and its
    renderer-free host acceptance now close that product gap without moving
    encounter authority into the graphical host.
15. The next normal-product audit found that authority-owned character despawn
    and new spawn outcomes caused by NPC combat death/respawn were still routed
    as bootstrap faults. A narrow product-character lifecycle correlator plus a
    host regression through death, cooldown, explicit respawn, new projection,
    and post-respawn survival closes that seam; the aggregate revalidation
    passes and is recorded in the corrective audit.
16. Persistent headless restore could resume a hostile NPC windup but did not
    own the resulting public vitals damage/death pair. Stable encounter attack
    correlation plus transactional vitals event peek/commit now consumes only
    the exact owned pair, retains unrelated FIFO heads, and proves cold combat
    reaches quiescence and resaves.
17. The final packaging audit found that the dedicated
    `-Dproduct=headless` graph did not declare the new vitals and encounter
    contract root imports even though the client graph did. The cold root now
    owns those imports, and direct cold lifecycle plus extracted-source gates
    prevent the client graph from masking this drift.

The corrective audit retains explicit P2 pressure points in the living
architecture register rather than repeating the former "no P2" overclaim. No
compatibility shim, generic AI/ability/faction framework, new scheduler, second
ECS, platform abstraction, firearm/lag-compensation path, public service, or
MMO infrastructure was added.

## Retained Limits And Next Product Pressure

Linux/SteamOS and Windows remain deferred. Steamworks, NAT/relay, public room
services, host migration, firearms, vehicle combat, crowds, factions/wanted
levels, and city-scale navigation remain future product decisions.

Automatic listen/dedicated bootstrap uses six NPCs, one per authored route
node. The 64-NPC cohort is a synthetic scale ceiling that deliberately permits
co-location at those six nodes. Replacement therefore does not yet impose
NPC-to-NPC capsule separation; authored denser slots/crowd policy must precede
that bounded query, as retained in A-F037.

The client combat-presentation owner also assumes that a graphical scene does
not switch to a fresh session/participant/avatar identity in place. Same-avatar
reconnect and ordinary incarnation respawn are covered; a future room/account
switch that reuses the scene must key and reset local feedback plus HUD-anchor
state, as retained in A-F043.

The strongest next gameplay candidate is a bounded Smart Object/affordance
slice: shared spatial query plus reservation for a small set of player/NPC world
interactions, with execution still owned by the consuming feature. It should be
planned from actual product interactions before any general framework is
introduced.
