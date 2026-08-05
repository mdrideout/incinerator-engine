# S13 Authored Population and Sandbox Activity Validation

**Status:** S13-A through S13-H automated acceptance complete; final human
walkthrough pending

**Recorded:** 2026-08-01

**Decision:** [ADR-024](../adr/024-authored-population-intent-and-activity-slots.md)

**Plan:** [S13 authored population](../design/s13-authored-population-and-sandbox-activity.md)

**World:** [S13 population evaluation world](../design/s13-population-evaluation-world.md)

## Phase Ledger

| Phase | Status | Evidence |
|---|---|---|
| S13-A — entry characterization and contract | Accepted | This record |
| S13-B — authored catalog and world capacity | Accepted | See below |
| S13-C — population/activity authority | Accepted | See below |
| S13-D — gameplay/session integration | Accepted | See below |
| S13-E — safe replacement and separation | Accepted | See below |
| S13-F — presentation and evidence | Accepted | See below |
| S13-G — lifecycle closure | Accepted | See below |
| S13-H — product acceptance and audit | Automated acceptance complete | See below; human walkthrough pending |

## S13-A — Entry Characterization and Accepted Contract

### Review result

ADR-024 is accepted for implementation without changing its owner model. One
measurement detail was amended: the pre-S13 world has only six independently
validated physical NPC anchors. Manufacturing a sixteen-controller baseline by
co-locating actors would reproduce A-F037 rather than characterize a credible
physical crowd. S13-A therefore records:

- the existing six-controller real-Jolt movement baseline;
- the existing 64-NPC encounter/planner logic-pressure baselines; and
- the missing sixteen-member physical baseline as a deliberate S13-B exit
  measurement after the 24 spawn slots and 16 activity slots are validated.

This is not a relaxed final requirement. S13-H still compares the ordinary
12-member, authored physical 16-member, and synthetic 64-NPC cohorts.

The remaining S12 human Navigation Lab walkthrough and its two requested human
incident captures remain visibly pending. The developer explicitly authorized
S13 implementation to proceed; this ledger does not rewrite S12 as
human-accepted.

### Measured starting budget

Commands:

```sh
zig build measure-s12 -Deditor=false -Doptimize=ReleaseFast --summary all
zig build measure-s11 -Deditor=false -Doptimize=ReleaseFast --summary all
```

Results:

- S12 planner: 32,768 queries in 4,096 eight-query waves, `1.214 ms`
  p99 against the `4.166 ms` ceiling.
- S12 physical movement: six distinct real-Jolt controllers over 2,048 ticks,
  `0.099 ms` p99, six moved, zero blocked, and zero teleport rollbacks.
- S11 encounter pressure: 64 pursuing NPC records and 16 participants over
  16,384 measured steps, `0.048 ms` worst p99, 49,152-byte paired RSS delta,
  and zero workload heap allocations.

The historical `measure-s8` full-physics 64-NPC run was stopped after its
proof child spent more than six minutes at full CPU with all NPCs manufactured
from one start node. It is intentionally not accepted as a physical-population
baseline. Its replay/transaction purpose remains covered by inherited gates;
S13 removes its co-location premise from physical acceptance.

These measurements leave ample fixed-tick headroom for the bounded population
owner. They do not predict crowd quality or justify a crowd solver.

### Owner and consumer inventory

| Current path | Consumer/owner | S13 disposition |
|---|---|---|
| `features/population/contract.zig::plan` | S8 measurement and installed S8 smoke | Retain only as historical synthetic-pressure fixture until S13-H replaces its build dependency; never use for product population |
| `sandbox/product_encounter.zig` | Product composition in `main.zig` | Remove when population bootstrap owns the ordinary roster |
| Uncorrelated host-managed NPC spawn outcomes | Product composition and authority observation lane | Population consumes only its request namespace; unrelated outcomes remain observable |
| `AuthorityCore.npcReplacementCandidates` | Session death path | Remove; member definitions own spawn-slot candidates |
| `sandbox_npc_replacement` | Simulation snapshot/replay and session replacement cycle | Fold into population membership after equivalent retry/persistence proofs pass |
| `hostile_npc_limit` | NPC encounter observation | Replace with explicit member combat disposition |
| NPC/vitals/encounter FIFOs | Session authority | Preserve exact peek/commit or single-drain routing; population may not steal unrelated outcomes |
| `SnapshotV13.npc_replacements` | Snapshot preflight/restore | Replace in one snapshot cohort with population member, slot, and replacement records |
| Replay-14 NPC replacement commands | Accepted-ingress replay | Replace in one replay cohort with population commands; no decoder for the old cohort |
| Protocol-14 NPC projection | Solo/listen/dedicated clients | Extend only with coarse member/role/activity state needed by product presentation |
| Gameplay Inspector, Navigation Lab, schema-5 incident state | Editor and incident tooling | Add a separate Population Lab and stable member/activity evidence |

No unexplained normal-product bootstrap or replacement consumer remains after
this inventory. Direct tests and synthetic tools may still submit raw NPC
commands because they intentionally test the NPC boundary, not product policy.

### Accepted capacities

| Capacity | Accepted value | Basis |
|---|---:|---|
| Ordinary authored roster | 12 | Readable product cohort with all three roles |
| Authored physical stress roster | 16 | One actor per validated activity slot |
| Synthetic logic pressure | 64 | Existing NPC/encounter/planner fixed capacities |
| Spawn slots | 24 | Twelve per district and multiple candidates per member |
| Activity sites / slots | 8 / 16 | Visible contention without node co-location |
| Activity steps per program | 6 | Small explicit cyclic programs |
| Population decisions per tick | 4 | Bounded authority work below the S12 eight-query planner budget |

The global Jolt capacity is 128 virtual characters; the product uses one
player plus at most sixteen authored NPC controllers. NPC feature capacity
remains 64. The accepted product cohort therefore consumes 17/128 controller
slots and 16/64 NPC slots at physical stress.

### Exact cohort breaks

S13 will make one coordinated greenfield cohort break when durable population
state enters authority:

- snapshot `13 -> 14`;
- replay `14 -> 15`;
- protocol `14 -> 15`;
- incident `4 -> 5`;
- district recipe/content fingerprint `6 -> 7`; and
- simulation configuration cohort `3 -> 4`.

The break removes old replacement records/commands and adds population
membership/activity/slot state. There is no compatibility decoder, fallback
bootstrap, dual-write, or migration path.

### Architecture and scope gate

Accepted:

- one sandbox population owner for durable authored intent;
- S12 remains the sole route/movement owner;
- encounter remains the combat-locomotion owner;
- session remains transaction, identity, replication, and lifecycle routing;
- fixed arrays, bounded work, stable IDs, and explicit state machines; and
- separate product, physical-stress, and synthetic cohorts.

Still deferred:

- behavior trees, StateTree, GOAP, blackboards, navmesh, local crowd
  avoidance, generative agents, relevance/LOD expansion, city streaming
  expansion, firearms, services, and secondary platforms.

No S13-A P0/P1 finding remains. S13-B may proceed.

## S13-B — Authored Catalog and Evaluation-World Capacity

### Implemented

- Exact renderer-neutral contracts for member, program, role, disposition,
  site, activity slot, spawn slot, kind masks, and role masks.
- Twelve ordinary members: five residents, four workers, three visitors, with
  P01 as the only explicitly hostile member.
- Four bounded cyclic programs, eight sites, sixteen capacity-one activity
  slots, and twenty-four spawn slots split evenly across both districts.
- Sixteen exact semantic destinations while retaining the S12 16-node,
  32-directed-edge graph and route owner.
- Cold admission for identity/reference integrity, program/site compatibility,
  exact destination poses, district ownership, blocker clearance,
  pose-to-anchor traversal, pairwise separation, unique initial placement,
  role admission, cross-district replacement candidates, and exact roster
  distribution.
- Content recipe `7` and content cohort
  `4cf1512641aa88af49b71a09c4504c528d8ef4edaa070d7a79699e88d6cce290`.
- An explicit historical `planSynthetic` producer for inherited 64-NPC
  transaction pressure; it cannot be mistaken for product population policy.

The first cold admission rejected West spawn 04 because it was only `0.86 m`
from South Gate activity slot A. The coordinate was moved to `(2, 0, -7)` and
the exact cohort was re-admitted.

### Automated evidence

```sh
zig build test-s13-population -Deditor=false --summary all
```

Result: `17/17` steps and `8/8` tests passed. The native placement test creates
both exact Jolt district collision cohorts and sixteen `CharacterVirtual`
actors, settles them for 120 ticks, and proves support, x/z stability,
controller count, and pairwise separation.

```sh
zig build test-content-cooker test-replay test-s12-navigation \
  -Deditor=false --summary all
```

Result: `101/101` steps and `292/292` tests passed. Fresh cooking is
deterministic, the headless manifest matches the new content cohort, replay
uses the recipe-7 fingerprint, and all inherited S12 planner, movement,
persistence, session, and authority tests remain healthy.

### Review result

The catalog owns only immutable sandbox content and cold validation. It does
not own runtime claims, ECS, Jolt handles, NPC transforms, routes, sessions, or
rendering. Marker coordinates are available to presentation, but interactive
marker drawing remains S13-F work rather than making the renderer-neutral
catalog import editor policy.

No navmesh, crowd solver, generic smart-object framework, random scheduler, or
compatibility decoder was introduced. No S13-B P0/P1 finding remains. S13-C
may proceed.

## S13-C — Durable Population Member and Activity Authority

### Implemented

- One fixed-capacity `sandbox_population.Owner` retains the selected authored
  roster, stable actor generations, cyclic program cursor, activity state,
  claims, leases, retry deadlines, and replacement readiness.
- Authority work is stable member-ID order with a hard four-decision budget
  per tick. Non-live lifecycle decisions precede live activity decisions so
  bootstrap and replacement cannot be starved.
- Activity selection rotates each site's stable slot order by member ID,
  reserves in the same authority call, and emits one correlated semantic
  destination intent. No runtime random source or allocator participates.
- Spawn and destination outputs use one bounded exact peek/commit queue.
  Calling the producer again while outputs remain pending is rejected instead
  of overwriting or double-consuming work.
- Claimed slots become occupied only through an exact member/actor arrival.
  Dwell completion, claim-lease expiry, encounter interruption/resume, vacancy,
  replacement delay, and typed spawn deferral each have explicit transitions.
- Immutable member/slot views, aggregate lifecycle/slot/queue diagnostics, and
  a stable little-endian logical digest expose the complete pure-owner state.
- Transition evidence has fixed capacity. Saturation preserves authority state
  and records every rejected diagnostic transition rather than allocating or
  corrupting the queue.

### Automated evidence

```sh
zig build test-sandbox-population -Deditor=false --summary all
```

Result: `4/4` steps and `7/7` tests passed. The focused cases prove bounded
bootstrap waves, same-tick exclusive contention, arrival/dwell completion,
claim-lease expiry, interruption/resume, vacancy/replacement generation,
exact output ownership, deterministic digest, typed spawn retry, and explicit
transition saturation.

```sh
zig build test-s13-population test-s12-navigation \
  -Deditor=false --summary all
```

Result before the final two focused saturation cases: `114/114` steps and
`304/304` tests passed. The focused target above admits those additional
cases; the combined gate is rerun at every later integration boundary.

### Review result

The owner contains no ECS entity, Jolt handle, route planner, session identity,
renderer, allocator, or wall-clock dependency. The authored catalog remains
immutable content; the owner alone mutates member and slot lifecycle; NPC
remains the future executor of emitted semantic destinations.

Queue behavior is deliberately asymmetric: uncommitted gameplay intents stop
the next producer step because losing one is an authority error, while a full
diagnostic-transition queue counts evidence loss without stopping gameplay.
This ownership is explicit and tested.

No S13-C P0/P1 finding remains. S13-D may proceed.

## S13-D — Gameplay, Session, and Product Cutover

### Implemented

- NPC spawn now accepts an exact authored position, facing, admitted anchor,
  explicit combat disposition, and semantic goal. Route-node position is no
  longer overloaded as physical spawn intent.
- Every product population member owns one reserved replication slot. Session
  routing retains the member ID, actor generation, spawn correlation, activity
  sequence, destination correlation, and live persistent actor identity.
- Population spawn and destination intents cross the ordinary NPC feature
  command boundary. Exact correlation handling binds actors, advances
  activities, and defers typed failures without consuming unrelated NPC
  outcomes.
- NPC encounter observations carry explicit authored hostility. The former
  persistent-rank hostile limit is gone.
- Encounter transitions interrupt and resume the exact population member.
  NPC death vacates that member, retains the death proxy, advances the actor
  generation, and clears the proxy only after replacement vitals registration.
- Sandbox solo, listen-room, and dedicated product configurations explicitly
  enable authored population. Feature and low-level tests remain
  population-neutral unless their composition opts in.
- The one-off `sandbox/product_encounter.zig` owner and its special product
  bootstrap were deleted. A renderer-free product acceptance now admits both
  districts and proves twelve unique actors are authoritative and presented
  through the local-session boundary.
- The dead session drain for standalone replacement outcomes was removed.
  Legacy replacement snapshot/replay records remain isolated from the product
  path until their coordinated deletion in S13-G.

### Automated evidence

```sh
zig build test-sandbox-product-population-host --summary all
```

Result: `8/8` build steps and `1/1` tests passed. The real embedded
host/session composition activated both authored districts, admitted twelve
unique actors exactly once, retained twelve authority NPCs, and presented all
twelve to the client.

```sh
zig build test-m6-transaction --summary all
```

Result: `26/26` build steps and `110/110` tests passed, including the full
authority transaction suite.

```sh
zig build test-mp6-hosts check-mp6 --summary all
```

Result: `41/41` build steps and `6/6` host tests passed. The dedicated server,
ticketed graphical client, and listen-room executable all compiled.

```sh
zig build test-s13-population --summary all
```

Result: `20/20` build steps and `15/15` tests passed after the integration
cutover. The attempted `zig build check` was not a validation failure: this
repository defines no step named `check`; `check-mp6` is the applicable
multiplayer compile gate and passed above.

### Review result

Normal product runtime now has one authored source for roster, role, activity,
hostility, and replacement intent. Session retains transport, correlation,
identity, replication, and transactional routing; it does not select roles,
programs, or candidates. NPC owns locomotion and S12 owns routes.

The exact catalog initially used mathematical `pi` for two backward-facing
poses. Cold validation correctly rejected that noncanonical endpoint, and the
authored values now remain inside `[-pi, pi)`. Product population is opt-in at
composition construction so unrelated unit fixtures do not manufacture a
twelve-controller world.

No normal-product one-off bootstrap or persistent-ID-rank policy remains.
The old standalone replacement module is still referenced only by the
pre-S13 durable snapshot/replay cohort and its focused legacy tests. Removing
that state before the population records exist would destroy persistence
coverage, so its deletion remains an explicit part of the S13-G greenfield
schema break. No S13-D P0/P1 finding remains. S13-E may proceed.

## S13-E — Safe Spawn, Replacement, and Separation

### Implemented

- Each member retains a bounded authored candidate cursor. Cold admission
  starts at the exact initial slot; every typed deferral rotates to the next
  distinct candidate. Replacement starts at a deterministic member/generation
  rotation and never repeatedly tests one blocked pose.
- Spawn admission has one simulation-owned physical query. It checks NPC
  capacity, same-cycle reservations, all live NPC `CharacterVirtual`
  positions, replacement distance from living players or their occupied
  vehicle chassis, replacement visibility, and the real Jolt shape query for
  static and dynamic rigid-body occupancy.
- Cold level admission intentionally omits player visibility suppression:
  those actors are admitted as part of world bootstrap before presentation.
  Replacement uses the strict proximity/visibility policy because that is the
  player-visible pop-in path. Both use the same physical and NPC-separation
  checks.
- Session retains only same-cycle pending spawn slots and passes their
  positions into the simulation query. It does not own physical policy or
  candidate order.
- Every member retains saturating counts for district-inactive, occupied,
  NPC-overlap, player-near, player-visible, and capacity deferrals. Aggregate
  diagnostics sum the exact per-member records.
- An unsafe replacement remains one `replacement_pending` vacancy with no
  actor and the same actor generation. A successful bind alone returns it to
  live state.

### Automated evidence

```sh
zig build test-sandbox-population --summary all
```

Result: `4/4` build steps and `8/8` tests passed. New cases prove candidate
rotation, typed per-member and aggregate retry counts, fixed retry deadlines,
and retention of one vacancy across an unsafe replacement attempt.

```sh
zig build test-simulation --summary all
```

Result: `7/7` build steps and `48/48` tests passed. The native admission test
distinguishes same-cycle NPC overlap, player proximity, player visibility,
cold bootstrap, and a real Jolt blocker.

```sh
zig build test-sandbox-population-placement --summary all
```

Result: `7/7` build steps and `1/1` test passed. Sixteen activity poses and
sixteen initial authored spawn poses create distinct real Jolt controllers.
After removing P01, its ordered replacement candidates yield a pose clear of
all fifteen retained controllers and the physical world.

```sh
zig build test-m6-transaction test-sandbox-product-population-host \
  --summary all
```

Result: `29/29` build steps and `111/111` tests passed. The exact authored
member death/replacement case retains its death proxy after despawn, through
replacement spawn and vitals registration, then clears it only when the new
generation is live.

### Review result

Candidate order remains durable population intent. Live-world classification
belongs to simulation because it owns Jolt, characters, vehicles, NPC views,
and vitals. Same-cycle reservations belong to session because it owns the
transaction interval before submitted NPC commands become physical. No layer
duplicates another layer's authority.

The runtime Jolt query does not treat `CharacterVirtual` controllers as rigid
bodies, so live NPC and same-cycle controller separation are explicit bounded
XZ checks. Vehicles and other dynamic rigid bodies remain covered by Jolt;
the occupied player vehicle is also used as the player-proximity origin. This
is a deliberate split, not an inferred collision guarantee.

No safe candidate does not despawn the death proxy, invent a fallback pose,
or silently reduce the roster. The vacancy and typed evidence remain until a
later authored candidate is admitted. No S13-E P0/P1 finding remains. S13-F
may proceed.

## S13-F — Presentation, Population Lab, and Incident Evidence

### Implemented

- The protocol and local client projection carry stable population member,
  role, combat disposition, coarse activity kind, and activity state for each
  authored NPC. Unrelated synthetic NPCs remain explicitly unassigned.
- Resident, worker, visitor, and hostile base colors are distinct. Encounter,
  windup/recovery, hit, death, and replacement presentation retain higher
  precedence, so role color never hides gameplay-critical feedback.
- A dedicated Population Lab owns only selected-member UI state. It shows
  lifecycle/activity/slot aggregates, the stable selected member and current
  actor generation, role/disposition, program step, activity slot/destination,
  deadlines, transition reason, spawn candidate, and typed retry totals.
- Bounds debug adds bounded spawn-slot and activity-slot separation circles,
  free/claimed/occupied color, and role-colored live
  member-to-destination lines. The Population Lab enables the existing
  renderer-neutral visualization mailbox; it receives no simulation or Jolt
  authority.
- Gameplay Inspector and incident `entity_state` records expose current
  population identity/activity. Population-owner transitions emit
  `action=population` timeline records only when state changes, with exact
  program/cursor/kind/sequence, site/slot, deadline, generation, and retry
  evidence.
- The manifest capability matrix, strict incident inspector, handoff search
  guidance, and canonical `incinerator-incident-diagnostics` skill require and
  explain population-activity evidence.

### Automated evidence

```sh
zig build -Deditor=true --summary all
```

Result: `59/59` build steps passed. The Metal/SDL editor product and all
installed headless/replay/save/incident tools compile with the new Population
Lab boundary.

```sh
zig build test-s13-population test-sandbox-product-population-host \
  test-session-contracts --summary all
```

Result: `65/65` build steps and `168/168` tests passed. This includes the
ordinary twelve-member local-session product, protocol round trips, exact
authority projection, role-feedback precedence, and population owner/catalog
tests.

The simulation debug test allocates caller-owned bounded storage, enables the
population at a cold boundary, and proves all 24 spawn slots and 16 activity
slots emit valid correlated bounds geometry with no dropped primitives.

### Review result

Presentation consumes copied projection values; it does not query population
authority. Population Lab borrows immutable catalog/member/slot records and
uses only the existing visualization request mailbox. Runtime debug geometry
is emitted by simulation because it alone can correlate catalog intent with
live NPC transforms, but it remains non-authoritative.

Transition evidence is event-driven rather than sampled per tick. Sampled
incident state explains current condition; timeline evidence explains how the
member entered it. Stable member ID survives actor replacement, while actor
generation prevents stale physical identity from appearing current.

No S13-F P0/P1 finding remains. S13-G may proceed with the coordinated
snapshot/replay/protocol/incident/config cohort break and deletion of the
standalone replacement owner.

## S13-G — Persistence, Replay, Reconnect, and Fault Closure

### Implemented

- Snapshot schema 14 owns canonical authored-population configuration, member,
  activity, claim, actor-generation, retry, and replacement records. Cold
  preflight verifies the exact catalog version and every member-to-program,
  slot, actor, NPC, vitals, encounter, and lifecycle relationship before native
  authority is constructed.
- The canonical slot table is the claim index. Restore validates it directly
  against member records; there is no second mutable index to rebuild, no
  conflict repair, and no legacy decoder.
- Pure-owner and complete-simulation restore preserve traveling, dwelling,
  waiting-for-slot, interrupted, vacant, and replacement-pending states and
  reproduce the exact snapshot and logical digest.
- Accepted-ingress replay schema 16 records population steps, intent commits,
  actor binds, spawn/destination deferrals, arrival, interruption, resumption,
  and vacancy. Tick digests add the population category so the first mismatch
  is attributed to population authority.
- The real product recorder now captures population owner mutations. A
  renderer-free product test records a twelve-member session, destroys it,
  replays into fresh authority, and matches every completed-tick digest.
- Incident snapshots encode only commands that affected the last completed
  tick. Incomplete zero-tick fault captures remain inspectable, while complete
  captures without a digest remain invalid.
- The standalone NPC-replacement owner, snapshot, replay command, diagnostics,
  host consumer, build steps, and tests were deleted. Population membership is
  the sole durable replacement source of truth.
- Protocol 15, snapshot 14, replay 16, world config 7, and incident schema 5
  advance as one greenfield cohort with exact pins and no compatibility path.

### Automated evidence

```sh
zig build test-sandbox-population test-simulation \
  test-simulation-snapshot test-replay --summary all
```

Results: population `9/9`, simulation `46/46`, snapshot `3/3`, and replay
`20/20` tests passed. These include the six simultaneous lifecycle midpoints,
exact cold save/restore/resave, catalog/claim drift rejection, population
command codec coverage, zero-tick failed-capture inspection, and stable-prefix
recording.

```sh
zig build test-sandbox-product-population-host \
  test-m6-transaction --summary all
```

Results: the real twelve-member product record/destroy/replay case passed
`1/1`; the transactional authority cohort passed `110/110` tests. The
full-world NPC seam-projection test also passed `49/49` in its isolated owner
suite.

```sh
zig build verify-interaction-matrix --summary all
```

Result: `17/17` steps and `3/3` contract tests passed. Seven fixed 4,800-tick
journeys passed across clean, nominal, adverse, and blackout transport,
including reconnect, player death/respawn, NPC death/replacement, dropped,
duplicated, and reordered packets. The clean repeat matched population,
action, submission, outcome, and ingress digests exactly.

```sh
zig build verify-source-package --summary all
```

Result: the filtered package passed `187/187` steps and `422/422` tests, then
its cold headless product cohort passed `32/32` steps and `54/54` tests. M5,
M6, MP6, final-binary, lifecycle, and dependency/replay cohort proofs passed.

The full editor build also passed `59/59` steps. The incident skill's schema-5
summarizer compiles with Python, and `git diff --check` reports no whitespace
defects.

### Review result

The acceptance sweep found and fixed one general incident-recording flaw:
outcome draining can admit a next-tick population command after the last
completed digest. Stable-prefix encoding now excludes that future command
instead of producing an unreplayable bundle. It also restored the intended
inspectability of a fault that occurs before tick one.

One NPC seam-projection assertion missed its 32-tick readiness bound only while
two independent cold-build matrices competed for CPU. The same owner suite
passed in the extracted package and again in isolation; no runtime policy or
test timeout was changed.

Population intent now survives save, restore, replay, reconnect, impaired
transport observation, and retained authority faults without allowing those
observation concerns to mutate activity or replacement authority. No S13-G
P0/P1 finding remains. S13-H may proceed.

## S13-H — Product Acceptance, Performance, Cleanup, and Review

### Implemented

- The ordinary product now boots the complete twelve-member authored roster;
  the installed S13 smoke observes every stable member, all three roles,
  traveling/dwelling/waiting activity, exact full-cohort presentation, and no
  unexplained disappearance after first admission.
- Full-world NPC projection now derives a valid interest origin while the
  observer has no live avatar. It uses the retained player death proxy when
  present and the owned district center during pre-spawn bootstrap. Player
  death can no longer temporarily remove the ordinary population projection.
- The installed product incident journey now targets the explicitly authored
  hostile member P01 and proves replacement by stable population-member ID.
  Another living pedestrian cannot falsely satisfy the replacement check.
- The final product journey deliberately moves the player to a reachable safe
  point after P01 dies. Typed player-visible, player-near, NPC-overlap, and
  physical-obstruction retries remain evidence; success requires P01 to return
  on a new actor generation.
- A `ReleaseFast` S13 measurement separates the 12-member owner, 16-member
  owner, sixteen real-Jolt controllers at unique authored placements, 64-NPC
  logic pressure, snapshot persistence, and protocol-15 projection costs.
- Incident capture's atomic record line budget is now 4 KiB. The composed
  S12-navigation plus S13-population entity record has a direct regression
  test, so a valid large record cannot masquerade as queue overload.
- `zig build verify-s13` is the current aggregate. It selects the authored
  S13 product/physical cohorts directly and retains 64 only through explicitly
  named synthetic pressure. The historical `verify-s12`/S8 gate remains
  available as historical regression evidence but is not the S13 product
  definition.

### Performance evidence

The recorded machine-readable result and interpretation are in
[`../performance/s13-baseline.json`](../performance/s13-baseline.json) and
[`../performance/s13-baseline.md`](../performance/s13-baseline.md).

```sh
zig build test-s13-measure -Deditor=false -Doptimize=ReleaseFast
zig build measure-s13 -Deditor=false -Doptimize=ReleaseFast --summary all
```

Results:

- twelve-member owner p99: `250 ns` across 8,192 fixed ticks;
- sixteen-member owner p99: `333 ns` across 8,192 fixed ticks;
- fixed population-owner storage: `21,992` bytes for either cohort;
- population decision/claim workload heap allocations: zero;
- sixteen unique real-Jolt controllers p99: `26,917 ns` across 2,048
  measured ticks after 120 warmup ticks;
- placement queries/rejections/separation violations: `16/0/0`;
- 64-command planning-wave p99: `1,542 ns` across 4,096 waves; and
- exact full-snapshot wire size: `918`, `1,210`, and `4,714` bytes for the
  12/16/64 cohorts.

Every p99 is below the conservative 4.166 ms ceiling. Owner intent and
transition queue high-water marks were 4 and 8 with zero transition drops.

### Installed Metal and incident evidence

```sh
zig build smoke-installed-s13-macos -Deditor=true --summary all
```

Both installed Metal runs completed all `66/66` build steps:

- at 240 Hz, 3,840 frames produced 960 authority ticks, including 2,880
  zero-tick frames and no multi-tick frame;
- at 40 Hz, 640 frames produced the same 960 authority ticks, including 320
  multi-tick frames and no zero-tick frame; and
- both observed all twelve members, all roles and activity-state classes,
  peak twelve draws, nonzero deterministic contention, and zero incomplete
  frames after the cohort first became fully visible.

The paired 2,400-frame incident benchmark measured capture-disabled
`1.600/3.382/3.850 ms` p50/p95/p99 and capture-enabled
`1.775/3.791/4.275 ms`. Capture retained all `80/80` trail images and `6/6`
anchors with queue high-water `28/1024` and zero dropped records. Enabled p99
remained below one 16.667 ms frame.

The corrected installed product journey completed at tick 2,466. Its
schema-5 bundle reported:

- `8,891` records in eight stream segments;
- four complete anomaly windows and 342 visual artifacts;
- zero suspicious artifacts, warnings, or dropped records;
- durable queue progress `3,483/3,483`;
- a persisted replay and handoff; and
- a verified 2,406-tick accepted-ingress replay.

The population trace shows P01 generation 1 becoming vacant at tick 1,743,
replacement eligibility at tick 1,923, typed unsafe retries, and generation 2
binding actor `1:20:2` at tick 2,105. This is stable authored identity across
a disposable physical actor, not a count-based replacement inference.

### Aggregate acceptance

```sh
zig build verify-s13 -Deditor=true -Doptimize=Debug -j1 --summary all
```

The final aggregate passed `253/253` build steps and `341/341` tests. It
includes focused S13 owner/catalog/placement/product-host tests, inherited S12
navigation and S11 combat gates, the deterministic interaction/fault matrix,
listen and dedicated process acceptance, packaged-source and cold extracted
verification, all five incident-hardening profiles, and installed 240/40 Hz
Metal population smokes. Performance remains a separate `ReleaseFast`
measurement so this broad correctness aggregate does not needlessly optimize
and relink every inherited executable.

### Cleanup and architecture audit

The audit confirms:

- the old standalone replacement owner, contract, product encounter owner,
  focused test, replay lane, diagnostics, and build wiring are deleted;
- role, combat disposition, activity, activity-slot claims, authored spawn
  candidates, retry state, and replacement now have one population owner;
- session authority routes typed intents/results and performs placement
  queries but no longer invents population policy from persistent-ID order;
- live-NPC capsule separation and same-cycle spawn reservation cover the
  declared 12/16 physical cohorts;
- `planSynthetic` remains only in explicitly named S8/S13 logic-pressure
  fixtures and cannot bootstrap ordinary product population;
- protocol 15, snapshot 14, replay 16, world config 7, and incident schema 5
  are exact current cohorts with no compatibility decoder or deprecation path;
  and
- no new behavior tree, navmesh, crowd solver, scheduler, ECS framework,
  relevance cutoff, or service abstraction entered the slice.

The audit found and corrected two acceptance weaknesses rather than relaxing
them: a missing full-world NPC interest origin during player death and a
count-based product-journey replacement assertion. It also found the 2 KiB
incident-record budget failure and corrected its explicit capacity.

A-F035 is resolved: authored population owns disposition, activity, candidate
selection, and replacement across actor generations. A-F037 is resolved for
the declared product/physical scope: 24 spawn slots, sixteen unique physical
placements, live-NPC separation, same-cycle reservation, and measured
sixteen-controller Jolt acceptance replace the invalid 64-overlapping-actor
premise. The 64 cohort is intentionally retained as logic/projection pressure.

No S13-H P0/P1 finding remains. Implementation and automated acceptance are
complete. The final human walkthrough in the ordinary product is the only
remaining acceptance checkpoint.
