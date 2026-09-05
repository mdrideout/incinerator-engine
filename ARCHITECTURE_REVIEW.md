# Incinerator Engine Architecture Review

**Status:** Living assessment; the Apple Silicon macOS gameplay/session
foundation now includes accepted S12 semantic navigation and S13 authored
population/activity. DR1 deterministic visual fidelity and S14 authoritative
ranged combat are accepted across solo, private-listen, and dedicated
placements. S15 four-district implementation and its automated/native and
product-owner acceptance are complete under ADR-028. Protocol 17, snapshot
15, replay 19,
incident schema 5, Population Lab, the 12/16/64 separated scale cohorts, and
automated Metal/product acceptance are current. EA0 is accepted and makes the
four ADR-029 owners, stable identity, revisioned typed transaction envelope,
crate vertical, authored-change evidence, and endpoint discovery contract
executable. EA0.5 now implements the developer-only local socket, five concrete
sandbox schemas, canonical CLI, graphical-owner dispatch, persistence, and
correlated frame evidence. Its focused/aggregate automation, installed native
Metal journey, LLM-agent workflow, and architecture/security/dead-code/doc
review are complete. Human usability and product-owner acceptance closed on
2026-08-30. The product owner eliminated the planned MCP adapter and authorized
Phase 7 to make the canonical CLI and repository-owned agent skill first-class.
Its implementation, automated, installed Metal, clean-context agent, and
comprehensive manual agent-review pass; product-owner acceptance is complete.
EA1-A now has a complete machine acceptance candidate: host-only glTF/GLB plus
PNG/JPEG import, stable cooked asset identities, renderer-owned texture/sampler
residency, project-owned textured content, read-only Content Browser/Inspector,
and CLI parity. Product-owner visual/usability review remains. EA1-B-EA5 retain
the material-authoring, vehicle-archetype,
lighting, map, and engine/game separation pressure. No open P0 blocks the next
phase decision.
The neural-rendering proof
is retained through RF10 as external technical evidence, but no learned model
is promoted, installed, or selected. The product owner paused that track
indefinitely on 2026-08-17. Deterministic rendering is the active direction;
the shared RF0-RF5 sandbox visual catalog is useful conventional-renderer input,
not an authorization to continue neural work. ADR-025 and ADR-026 remain
preserved boundary policy for an explicit future restart.

**Last reviewed:** 2026-08-30

**Scope:** Accepted EA0 and EA0.5 architecture, their demonstrated strengths,
remaining structural pressure before another product or service slice, the
active deterministic-rendering direction, and the retained paused neural proof

**Related roadmap:** [`OVERHAUL_PLAN.md`](OVERHAUL_PLAN.md)

**Multiplayer strategy:** [`MULTIPLAYER_PLAN.md`](MULTIPLAYER_PLAN.md)

**Latest automated validation:**
[`docs/validation/ea1-a-practical-textures-and-materials.md`](docs/validation/ea1-a-practical-textures-and-materials.md)

**Accepted cohesion contract:**
[`docs/design/m5-client-authority-cohesion.md`](docs/design/m5-client-authority-cohesion.md)

**Current phase sequence:**
[`M6 accepted`](docs/validation/m6-transactional-authority-cycle.md)
→ [`MP6 accepted`](docs/validation/mp6-playable-multiplayer-room-flow.md)
→ [`S10 accepted`](docs/validation/s10-damage-death-respawn.md)
→ [`S11 accepted`](docs/validation/s11-npc-encounter-combat-response.md)
→ [`post-S11 automated closeout passed; manual acceptance exposed validation gaps`](docs/validation/post-s11-runtime-corrective-audit.md)
→ [`IV0-IV5 interaction validation and observability accepted`](docs/validation/gameplay-interaction-validation-and-observability.md)
→ [`IC5 accepted`](docs/validation/human-test-incident-capture.md)
→ [`open-world spatial and vehicle-dynamics correction complete`](docs/design/open-world-spatial-diagnostics-and-playability.md)
→ [`S12 accepted`](docs/validation/s12-destination-driven-navigation.md)
→ [`S13 accepted`](docs/validation/s13-authored-population-and-sandbox-activity.md)
→ [`DR1 accepted`](docs/validation/dr1-playable-deterministic-visual-fidelity.md)
→ [`S14 accepted`](docs/validation/s14-ranged-combat.md)
→ [`S15 accepted`](docs/validation/s15-content-rich-district-expansion.md)
→ [`EA0 accepted`](docs/validation/ea0-ownership-identity-transaction-boundary.md)
→ [`EA0.5 accepted`](docs/validation/ea0-5-local-developer-endpoint-and-canonical-cli.md)
→ `Phase 7 CLI agent contract accepted`
→ [`EA1-A machine candidate; product-owner review pending`](docs/validation/ea1-a-practical-textures-and-materials.md)
→ `EA1-B-EA5 pending`

**Active rendering direction:**
[`DR1 playable deterministic visual fidelity`](docs/design/dr1-playable-deterministic-visual-fidelity.md)

**Completed developer-workspace phase:**
[`ED1 structured developer workspace`](docs/design/ed1-structured-developer-workspace.md)
([validation](docs/validation/ed1-structured-developer-workspace.md))

**Paused experimental rendering track:**
[`RF10 retained externally and unpromoted`](docs/design/neural-rendering-pause.md)

**Completed cleanup record:** [`CLEANUP_PLAN.md`](CLEANUP_PLAN.md)

## Purpose

This is the living architectural health record for Incinerator. It does not
replace phase acceptance evidence or ADRs. It answers a different question:
whether the code and product topology still express the intended architecture
well enough for the next material capability.

The review is updated when a new phase changes ownership, authority, process
topology, persistence, scheduling, or an important dependency boundary. A
finding is not resolved because a file was moved; it is resolved only when the
result has a clearer owner, dependency direction, lifecycle, and acceptance
test.

## Executive Assessment

The engine has a strong modern foundation. The original subsystem-oriented
prototype has been replaced by a thin feature-authoring kernel, vertically
owned gameplay features, explicit capability ports, fixed-tick authority,
presentation extraction, exact persistence/content cohorts, a cold headless
product, bounded diagnostics, and same-cohort replay.

The architecture is stronger than the physical source layout. `App`,
`Simulation`, the Jolt adapter, replay, and several feature roots now combine
too many private responsibilities in large files. Product and validation are
separate at the binary/reachability boundary, but some of that code remains
physically co-located. The current four-phase schedule is explicit at the
coarse level but relies on registration order within a phase. Flecs is safely
encapsulated, although current feature iteration uses private active arrays and
point access more than archetype queries or declared data access.

None of those findings invalidates the completed foundation. MP1-MP3 prove the
graphical-client/authority boundary, direct GNS placement, bounded local
prediction, deterministic network impairment, and accepted-ingress replay for
the character slice. MP4-A through MP4-E extend that model through authoritative
vehicles, carry interaction, district relevance, relevant NPC projection, and
acknowledged prioritized delta replication without generic ECS replication or a
client Flecs/Jolt world. MP5 adds bounded open room/admission semantics while
keeping Steamworks and service state outside gameplay authority. M4 accepts that
Apple Silicon macOS multiplayer foundation.

M4 intentionally did not reclassify the broad embedded-solo facade as complete.
M5 replaces its separate character dispatcher with one
opaque embedded placement over the shared authority core, routes character,
vehicle, and carry requests through session admission, renders those gameplay
surfaces from replicated client state, and moves durable commit plus district
streaming behind dedicated owners. It also removes the historical 120 Hz
mismatch: graphical embedded authority advances at the accepted 60 Hz,
independently paced from presentation, with 20 Hz replication. The complete
owner boundary, regression matrix, documentation, and independent review are
accepted in the M5 evidence record.

The accepted M6 tree closes the post-M5 transactional pressure point with a
class-reserved stable-prefix mailbox, eight explicit fail-stop stages,
preflighted admission, double-buffered publication metadata, generational
delivery leases, per-lane application receipts, bounded reconnect replay, and a
stage-seven durable disposition. Physical network delivery and blocking storage
remain separate owner state machines. The guarantee is atomic publication, not
rollback of an already stepped Flecs/Jolt world.

The incident corrective tree preserves those ownership boundaries rather than
introducing a telemetry bus. The developer host owns fixed requests and local
evidence orchestration; the writer alone owns files; renderer adapters own
bounded GPU capture state; authority owns relevance; and replay exposes one
explicit consumable-output boundary. Tri-state cross-boundary membership and
tombstones make disappearance diagnosable without copying an ECS/world into
the recorder. The district fix remains a sandbox-specific one-hop visual
prefetch policy, not a generalized streaming framework.

The accepted MP6 tree returns the program to player-visible product pressure.
It presents the room/admission core through one generation-safe graphical
coordinator and proves constrained localhost/LAN listen plus dedicated direct-IP
play without Steam/NAT/public-service scope. S10 is the accepted gameplay
slice that adds feature-owned vitals, server-derived damage, exactly-once death cleanup,
and a stable participant possessing a generational disposable avatar. It
closes that slice with a backend-neutral bounded vitals owner, authoritative
Jolt-queried melee, typed death cleanup, dead reconnect, deterministic safe
explicit respawn, and real graphical listen/dedicated process evidence. S11
extends that boundary through deterministic hostile NPC encounters and durable
replacement. The post-S11 corrective pass advances the semantic protocol to
revision 12 for authoritative wheel presentation and retains health, death,
spawn placement, NPC decisions, and vehicle state as server truth in every
placement.

## Accepted Architectural Thesis

The accepted foundation remains:

1. A thin kernel owns lifecycle, schedule, identity, bounded mechanics, and
   diagnostics—not gameplay or backend policy.
2. Gameplay features own behavior end to end across commands, state, systems,
   persistence, presentation extraction, diagnostics, and tests.
3. Features depend on narrow capabilities; SDL, Jolt, storage, platform, and
   future transport integrations remain adapters.
4. One owner thread mutates one authoritative world. Workers publish bounded
   copied results and never mutate authority directly.
5. Rendering, editor UI, replay evidence, and future clients consume immutable
   projections or submit typed requests; they are not parallel authorities.
6. Shared infrastructure is extracted only from demonstrated consumers and
   retains domain-specific policy at its edge.
7. The conventional deterministic renderer is the active product renderer and
   consumes only immutable presentation snapshots. It must remain independently
   playable, observable, and testable without a learned model or experiment
   artifact.
8. The paused neural renderer remains presentation infrastructure only. If the
   product owner explicitly restarts it, it may consume immutable versioned
   raster inputs and only a deliberately promoted immutable content bundle;
   promotion-eligible weights remain title-specific, random-initialized, and
   trained on title-owned paired data. External models remain comparisons.

The accepted multiplayer refinement is:

> Authority is a role, not a machine. Solo, listen-hosted, and dedicated modes
> use the same authoritative session semantics with different links and
> process placement.

That refinement is described in accepted
[ADR-016](docs/adr/016-authority-session-topology.md) and
[ADR-017](docs/adr/017-network-identity-protocol-and-replication.md).
[ADR-018](docs/adr/018-gamenetworkingsockets-and-steam-compatible-routing.md)
selects the open-source GameNetworkingSockets flat C API, direct IP for the
first remote proof, dedicated authority as the canonical public topology, and
an optional non-vendored Steamworks adapter for Steam networking compatibility.

## Current Strengths

### Feature and dependency direction

- `src/root.zig` exposes a deliberately small backend-neutral engine surface.
- Feature implementations import the engine and explicit shared contracts,
  not SDL, ImGui, the renderer, raw Flecs, or JoltC.
- Raw JoltC access is isolated behind the engine-owned Jolt adapter and
  engine-defined handles/capabilities.
- The sandbox owns installed coordinates, routes, controls, and content policy;
  reusable district contracts own bounded structural values and validation.
- Editor mutations use the same typed authority commands as other producers.

### Authority, persistence, and lifecycle

- Runtime, persistent, physics, content, and presentation identities have
  explicit lifetimes and do not masquerade as each other.
- Dynamic physics owns simulation transforms; presentation reads interpolated
  previous/current state.
- Snapshot V12 is canonical logical state and contains no Flecs IDs, Jolt
  handles, GPU objects, borrowed pointers, or asynchronous worker ownership.
- Feature queues and external-producer paths are bounded with typed admission,
  reserved authority outcomes, and visible observational loss.
- The M3 authority validates configuration, content, and saves before acquiring
  the one Flecs/Jolt world, then drains and durably commits only healthy state.

### Observability and evidence

- Structured diagnostics preserve the immutable first authority fault.
- Replay records semantic authority ingress and reports category-first logical
  divergence within an exact build/content cohort.
- Physics visualization and profiling consume bounded immutable evidence and
  cannot mutate authority.
- Normal client, visual validation, cold authority, and extracted packages have
  separately verified membership and linkage boundaries.
- Debug, ReleaseFast, editor, native Metal, failure, lifecycle, packaging, and
  soak evidence exist for the current Apple Silicon macOS contract.

### Multiplayer foundation

- The remote graphical client owns only protocol/session state, disposable
  prediction, replicated presentation, GNS transport, SDL input, and rendering;
  it has no authoritative Simulation/Flecs/Jolt world.
- The authority accepts bounded semantic character, vehicle, and carry requests
  and projects backend-neutral character, vehicle, carryable, district, and NPC
  state without automatic ECS replication.
- Acknowledged full/delta history, relevance, explicit removals, and overload
  degradation have declared per-client entity, byte, event, and memory budgets.
- Open room/invite admission binds external identity to a participant while
  keeping lobby/service state, Steamworks, and transport routes outside world
  authority.
- The aggregate M4 gate retains real two-client GNS, deterministic network
  faults, prediction/reconciliation, reconnect, accepted-ingress replay, cold
  authority, installed Metal, and architecture evidence.

## Findings Register

Priorities describe current structural pressure and explicit triggers. Resolved
rows preserve what later slices corrected; open rows are not regressions in the
accepted phase evidence, but they must not disappear behind a broad closeout
claim.

| ID | Finding | Priority | Trigger / target | Status |
|---|---|---:|---|---|
| A-F001 | The solo `App` remains the graphical composition root and retains presentation, input, authoring, and validation orchestration; embedded authority, district streaming, persistence, and developer state are separate opaque owners | P1 | Complete independent M5 review of cohesive graphical/developer/streaming/persistence/authority ownership | Resolved for M5; the graphical composition root is intentional and architecture-gated |
| A-F002 | `Simulation` remains a broad private live-authority facade; canonical DTOs and the durable snapshot codec/preflight are extracted, while live composition, restore, replay capture, ticking, outcomes, diagnostics, and queries remain together where they share the world | P1 | Keep the authority surface narrow; split only responsibilities that gain an independent lifecycle or consumer | Mitigated and accepted for current scope; retain as a measured pressure point |
| A-F003 | The Jolt adapter combines runtime/world, bodies, characters, vehicles, contacts, and debug extraction in one physical module | P2 | Before a multiplayer phase materially changes two or more physics concerns | Open |
| A-F004 | Feature implementation roots still combine private components, systems, persistence/restore, extraction, diagnostics, and extensive tests; canonical public value/protocol contracts are now extracted | P2 | Split only roots materially changed by M5 or the next gameplay slice; do not perform unrelated file-only churn | Partially mitigated; open measured pressure point |
| A-F005 | M6 now provides class-reserved ingress, preflighted admission, eight-stage fail-stop execution, atomic derivative/metadata publication, leased adapter delivery, application receipts, reconnect replay, and staged durable decisions; intra-phase feature order remains registration order | P1 | Preserve S11's typed next-tick locomotion directive and declared vitals proposal boundary; add no scheduler DAG without measured need | Transactional boundary resolved in M6; S11 proves combat ordering without registration order becoming a rule |
| A-F006 | The visual product had no client/authority separation or local-session seam; character input reached `Simulation` directly | P0 | MP1 | Resolved for the character slice: typed local session plus separate MP2 products |
| A-F007 | Client replicated-state plus bounded character and owned-vehicle prediction/reconciliation exist without a second Flecs/Jolt world; remote vehicles remain interpolated | P1 | MP3 / MP4-A2 | Resolved and contract-tested through MP4-A2 |
| A-F008 | Persistent/runtime and session/account/participant/connection/replicated/input/snapshot identities must remain distinct | P0 | MP0/MP2 | Resolved and contract-tested |
| A-F009 | The durable snapshot is suitable for restore but must not become a bandwidth-oriented network snapshot or protocol DTO | P0 | ADR-017 before protocol implementation | Guardrail recorded |
| A-F010 | Accepted character, vehicle, enter/exit, and carry interaction ingress records participant, generational connection, sequence, target/admission tick, target entity, intent, and fingerprint and replays into a fresh authority; district/NPC autonomy is authority-owned rather than client ingress | P1 | Apply the same rule to every later client-originated feature request | Resolved for the complete M4 gameplay surface |
| A-F011 | Feature iteration relies on private active arrays and point component access; city-scale query locality and parallel access are not demonstrated | P2 | Profile the first substantially larger replicated population before changing the model | Accepted pressure point |
| A-F012 | The zflecs cohort permits one owned world per process, constraining an embedded authority plus any future full client ECS | P1 | Accepted topology starts with one authority world plus lightweight client state | Accepted constraint |
| A-F013 | Engine/game dependency direction exists internally, but no separately built game package currently proves the intended open-engine/separate-game consumer boundary | P1 | First production game composition | Open |
| A-F014 | Validation and operational rigor have advanced faster than player-visible game depth, risking further infrastructure without product pressure | P1 | M5 may extract only ownership required by the accepted boundary; later infrastructure must be pulled by a real product/gameplay slice | Active guardrail |
| A-F015 | The engine has no selected license, third-party notice set, stable public API promise, or external consumer guide | Release | Before public distribution, not before multiplayer architecture work | Deferred by owner |
| A-F016 | Vehicle exit needs bounded collision-safe placement and disconnect teardown even when every candidate is blocked | P1 | Resolve before district collision/relevance makes blocked exits routine | Resolved in MP4-A2: five deterministic candidates, then typed teardown-only release and immediate hidden-character despawn |
| A-F017 | At M5 entry, embedded solo owned a separate `Simulation` dispatcher and sent only character gameplay through the local protocol; M5 uses the shared authority behavior and routes character, vehicle, and carry gameplay through admission | P0 | M5 local/remote semantic parity and final regression | Resolved and accepted in M5 |
| A-F018 | Embedded solo advanced authority from the historical 120 Hz presentation accumulator while the accepted session authority was 60 Hz; its three-tick snapshot divisor therefore yielded 40 Hz rather than 20 Hz | P0 | M5 independent 60 Hz authority clock plus product-level cadence tests | Resolved: embedded authority is 60 Hz, replication is 20 Hz, and 80/240 Hz cadence contracts cover independent presentation |
| A-F019 | The M4 static check scanned one graphical client file for direct import names rather than proving the complete client-facing source/API closure | P1 | M5 transitive source-boundary and negative API checks | Resolved by the accepted M5 transitive architecture gate |
| A-F020 | The implemented MP5 registry models bounded room/admission state, but the graphical product has no single generation-safe create/join/connect/synchronize/reconnect coordinator and listen placement is not executable | P1 | MP6 playable room flow | Resolved and accepted in MP6: one sanitized generation-safe coordinator drives graphical listen and dedicated placements |
| A-F021 | Participant lifecycle formerly assumed one active character identity and had no explicit stable-player/disposable-avatar incarnation contract for death and replacement | P1 | S10 damage/death/respawn | Resolved and accepted in S10: the participant survives death/reconnect while each physical avatar has a checked disposable incarnation |
| A-F022 | No feature formerly owned generic player/NPC vitals, deterministic same-tick damage application, exactly-once death, or typed cross-feature death cleanup | P1 | S10 damage/death/respawn | Resolved and accepted in S10 through the backend-neutral bounded vitals feature and authority-coordinated typed cleanup |
| A-F023 | `AuthorityCore` contains substantial transaction, replication, room-facing session, player lifecycle, and thin NPC death-proxy/replacement routing in one physical module even though those responsibilities retain explicit private contracts | P2 | Reassess only when another slice creates an independently testable session-lifecycle owner | Mitigated and accepted through S11: autonomy and durable replacement policy remain separate owners; no cohesive extraction seam justified file churn |
| A-F024 | Logical blockers, their mandatory visual proxies, character spawn clearance, and navigation clearance previously had separate implicit assumptions, allowing invisible collision and unsafe authored positions | P0 | Post-S11 corrective pass | Resolved: one canonical recipe now drives blocker presentation and swept capsule preflight; default movement, all automatic participant slots, and every installed navigation edge are checked |
| A-F025 | Character/NPC facing, chassis-derived exit direction, and wheel presentation previously duplicated conventions or discarded authoritative wheel motion at the client boundary | P0 | Post-S11 corrective pass | Resolved: one engine facing contract, explicit degenerate-exit fallback, protocol revision 12 wheel state, and one shared pure wheel composer; installed 240/80 Hz Metal gates prove wheel spin and steering plus the full vehicle-control scenario |
| A-F026 | Graphical network products rendered no relevant district blockers, ignored mouse-look events, and used one arrival clock for common 20 Hz and NPC 10 Hz projection lanes | P1 | Post-S11 corrective pass | Resolved: bounded relevant-district presentation, shared right-drag/focus-loss policy, and client-owned applied-world clocks per projection lane |
| A-F027 | Arithmetic participant spawn positions intersected canonical blockers and did not reserve same-cycle choices or account for live fixture placement | P1 | Post-S11 corrective pass | Resolved: one bounded initial/respawn catalog, real Jolt placement queries, continuous materialized-character occupancy through the vitals handoff, driving-aware live-character/NPC scoring, same-cycle reservations, and participant-capacity evidence against the fully settled vehicle plus 64-NPC synthetic fixture |
| A-F028 | The composition-owned global support body and each streamed district support box remain coplanar physical surfaces | P2 | Before changing support topology, contact behavior, or streaming bootstrap order | Resolved by S15: the composition ground is the sole flat support body and districts own only explicit obstacles; exact physical placement evidence proves one support plus eight obstacle bodies |
| A-F029 | The first client vehicle layout is a hard-coded single-archetype cohort assumption rather than an admitted catalog identity; wheel unwrap also estimates whole turns from endpoint velocity across gaps | P2 | EA2 or a materially harsher vehicle replication profile | Open: EA2 owns stable archetype identity plus admitted layout/tuning/material digests and live authoring; evaluate authoritative unwrapped phase or a server-tick presentation timeline only if the new cohort exposes a wheel-phase defect |
| A-F030 | Vehicle snapshots still resend raw float wheel state, authority projection is recomputed per relevant participant, and graphical multiplayer acceptance proves lifecycle semantics more strongly than exact draw composition | P2 | Measure the declared four-active-vehicle/64-NPC profile or add another client-visible dynamic feature | Open measured pressure point; retain simple current limits until bandwidth/projection/render-plan evidence justifies change |
| A-F031 | Accepted S11 combat/life fields reached the solo client but were discarded by `local_solo` draw extraction and the renderer displayed unchanged character/NPC materials | P1 | Post-S11 corrective pass | Resolved: one renderer-neutral, tick-keyed combat presentation owner feeds solo and graphical network scenes with health bars, hit flashes, encounter/death colors, and retained cooldown/respawn/no-safe-spawn HUD markers |
| A-F032 | Several policies treated the retained hidden CharacterVirtual pose as the player location while driving, and the authority still admitted on-foot melee from or against vehicle occupants | P1 | Post-S11 corrective pass | Resolved: one authority participant-world-position boundary uses the occupied chassis for focus/relevance/spawn safety; replacement visibility does the same through a narrow vehicle read port; client and authority both enforce on-foot-only melee |
| A-F033 | Durable pending NPC replacement records could be restored by the persistent headless product, but no operational consumer completed or deferred the emitted replacement outcome | P1 | Post-S11 corrective pass | Resolved: the headless composition advances an exact transaction from ready to correlated NPC spawn to vitals registration; only the matching `registered` outcome completes replacement, spawn rejection defers, vitals rejection compensates with an exact despawn before deferral, unrelated FIFO heads remain fault evidence, and in-flight transactions forbid quiescent save while settled state cold-restores and resaves exactly |
| A-F034 | The accepted S11 record claimed an engaged-NPC replication priority while all NPC projection still uses the global 10 Hz lane | P2 | Before combat density or reaction readability depends on a faster engaged cadence | Open; measure and design an explicit priority budget instead of treating cue-forced publication as a second cadence |
| A-F035 | Sandbox replacement candidates were selected inside session authority, and hostile assignment followed current persistent-identity rank rather than authored durable population intent | P2 | S13 authored population | Resolved: stable population membership now owns role, explicit combat disposition, cyclic activity, authored spawn candidates, typed retry, and replacement across actor generations; session authority only routes intents and performs bounded placement queries |
| A-F036 | Reliable life feedback fans out room-wide, carries no NPC source cue, and graphical acceptance/inspection remains stronger on lifecycle logs than source direction, semantic mid-state JIP, and per-NPC decision evidence | P2 | Before directional damage UI, materially larger rooms, or more sophisticated NPC behavior | Open; add relevance/recipient policy and a typed source cue only with the product UI that consumes it, then strengthen renderer-neutral semantic acceptance and selected-NPC inspection |
| A-F037 | NPC replacement placement queried rigid bodies and live-player separation but not another live `CharacterVirtual`; the 64-NPC synthetic cohort mapped too many actors onto too few physical anchors | P2 | S13 authored placement and separation | Resolved for declared scope: 24 spawn slots, sixteen unique real-Jolt placements, live-NPC capsule separation, same-cycle reservation, and zero measured placement/separation failures cover the 12/16 physical cohorts; 64 is explicitly logic/projection pressure, not crowd acceptance |
| A-F038 | A compact saved NPC route prefix could be mistaken for a completed farther goal while destination content was inactive, flipping a patrol leg; restored pursuit could also be lost while its target cohort or owner was unavailable | P1 | Post-S11 corrective pass | Resolved: persisted routes distinguish `exact_prefix` from owner-aligned `deferred_rebuild`; inactive content cannot manufacture goal completion, patrol intent survives, and pending pursuit installs only after the required target/owner cohort reloads. Snapshot V11/replay 8 and focused navigate/patrol/pursuit restore tests fix the contract |
| A-F039 | Valid S11 life/action bursts competed directly with the 16-message per-connection wire quota, conflating logical publication with transport preparation and allowing one slow consumer to threaten room progress | P1 | Post-S11 corrective pass | Resolved: one conservative admitted cycle derives 172 participant publications and the ledger retains two cycles (344 records); a cursor drains ordered batches under the 16-message wire ceiling, overflow retires only the slow participant, and exact burst/reconnect/client/presentation FIFO tests preserve bounded delivery |
| A-F040 | The normal `zig build run` product had no playable hostile NPC even though validation-only S11 compositions did, so the accepted solo product claim exceeded ordinary composition | P1 | Post-S11 corrective pass | Resolved: a narrow product owner waits for the player and west district, submits one initial hostile through the host-managed authority, correlates its exact result, and has a renderer-free normal-product host test; the installed validation smoke separately proves the full combat presentation |
| A-F041 | After that bootstrap correction, ordinary product routing still classified the authority-owned character despawn and new spawn caused by NPC combat death/respawn as bootstrap faults | P1 | Second post-S11 audit | Resolved and revalidated: a narrow product-character lifecycle owner correlates local life facts, replicated avatar/HUD state, persistent-character despawn, respawn result, new character spawn, and new projection; the renderer-free normal-product host proves NPC-caused death, cooldown, respawn, and post-respawn survival |
| A-F042 | A cold-restored hostile encounter could resume NPC melee in the persistent headless product, but that host had no exact owner for the resulting public vitals damage/death FIFO pair | P1 | Second post-S11 audit | Resolved: encounter attacks have a stable typed correlation domain; the operational host peeks and commits only an exact owned damage outcome plus its exact lethal death event, preserves unrelated heads as fault evidence, and proves cold-restored combat reaches quiescence and resaves |
| A-F043 | The client-owned combat-presentation owner retains local feedback and HUD-anchor state without an explicit local avatar/session identity key, so a future fresh join that reuses one graphical scene could briefly display the prior avatar's cooldown, disposition, or anchor | P2 | Before fresh room/account switching or avatar-identity replacement can reuse a graphical scene | Open: key local presentation by session plus participant/avatar generation/incarnation, reset local-only feedback/anchor on an identity transition, retain it across same-avatar reconnect, and test both paths |
| A-F044 | The dedicated cold `-Dproduct=headless` build graph drifted from the shared simulation imports after S11: `vitals_contract` and `npc_encounter_contract` reached the client graph but not the cold root | P1 | Final post-S11 packaging audit | Resolved and verified: the cold product declares both exact root imports, its direct test/lifecycle gate exits successfully, and the current extracted-source aggregate passes 182/182 broad steps with 409/409 tests plus 32/32 cold steps with 62/62 tests |
| A-F045 | Human trace evidence showed that death removed the local projection, district-edge drop placement rejected valid player intent without a readable reason, and high-rate movement samples evicted useful causal context | P1 | Post-IV human-trace corrective | Resolved and later superseded at the drop boundary: authority retains a noninteractive zero-health death proxy through respawn; trace schema 2 preserves typed reasons and semantic transitions; ADR-022 removes district-residency gating and old-pose fallback entirely so a held object drops at its authoritative spatial destination |
| A-F046 | MP3 included asynchronous world bootstrap, the listen observer could finish before the remote member, and IV5 clean-repeat compared live sampled bytes as though the non-lockstep engine promised bitwise determinism | P1 | Post-IV aggregate stabilization | Resolved without weakening product claims: MP3 uses its deterministic host-managed empty-world scope, listen waits for bounded remote completion, and IV5 settles bootstrap then compares causal action/submission/outcome semantics while the impaired link retains exact same-message seeded decisions |
| A-F047 | `drawMeshWithMaterial` ignored `base_color` for `pos_color` primitives, so combat supplied a red corpse while the product remained orange; the independent visibility fragment used the intended color and accepted a nearly occluded corpse | P1 | Final rendered human acceptance | Resolved: primitive material tint is a reflected 16-byte fragment contract, debug draws push white explicitly, dead avatars remain in NPC presentation separation, and the Metal death checkpoint requires at least 64 depth-tested local-corpse pixels. Direct swapchain acceptance confirms the corpse is visibly red and distinct from the hostile |
| A-F048 | V1 human incident evidence treated flag time as symptom time, sampled too sparsely, lost absent entity membership, reported stale live health, and omitted an NPC encounter replay output lane | P0 | IC5 evidence corrective | Resolved and human-accepted in schema 3: the -5 through +2 second visual window, actual indexed times, atomic lifecycle/health, tri-state membership, tombstones, replay, live handoff, failure profiles, and fresh human bundles make the current incident workflow usable without treating flag time as symptom time |
| A-F049 | District recipe cohort 3 reached manifests, replay, configs, and graphical streaming while the cold headless manifest validator duplicated and retained recipe 2 | P0 | IC5 source-package closeout | Resolved without compatibility: `headless_content` imports the sandbox recipe owner for exact fail-closed admission, and the cold lifecycle plus filtered-source gates execute the current cohort. |
| A-F050 | NPC death scheduled replacement directly at the authority-to-simulation seam, mutating the `npc_encounter` digest outside the normalized replay command spine; short replays never reached death and missed it | P0 | IC5-G long replay | Resolved in replay cohort 10: bounded schedule/defer/complete ingress is canonically encoded and applied before its eligible tick; focused codec/simulation tests and the 2,106-tick journey replay match through death and replacement. |
| A-F051 | The initial full-drawable anchor policy reserved 239,155,200 bytes on a Retina 2560x1440 window, violating the declared 128 MiB capture-memory boundary | P0 | IC5-G capture-cost gate | Resolved without relaxing the budget: the 30 Hz product lane owns transient continuity and four 1 Hz full-drawable slots own human/UI context. Measured bounded downloads are 121,190,400 bytes; a fresh smoke and full journey retain all five requested anchors with zero warnings. |
| A-F052 | A process killed while post-roll was capturing had no materialized anomaly marker yet, and both fresh-agent diagnostic consumers aborted instead of explaining the valid live partial state | P0 | IC5-G unclean-exit gate | Resolved: the atomic running manifest and anomaly index remain authoritative; inspector and canonical/personal skill report `capturing`, `marker=pending`, zero finalized windows, absent replay/handoff, and explicit partial-in-time warnings without mutating the bundle. |
| A-F053 | Exact district equality removed an authority-live vehicle/carryable from the client projection, while incident state and semantic maps could not prove those object boundaries; accepted-ingress replay then compared a newer authority frame once the objects remained visible | P0 | IC5-H human vehicle incident | Resolved with the deliberately bounded four-vehicle/four-carryable projection, typed bounded/controlled/held/dormant evidence, stable identities and tombstones, shared chassis/wheel semantic identity, a manifest capability matrix, recorded-tick replay comparison, and same-identity real-GNS/Metal seam acceptance. A future spatial policy requires measured hysteresis and no-pop evidence; no generic replication graph was added. |
| A-F054 | Carryable existence and player-requested drop were incorrectly coupled to exact active district residency, preventing ordinary open-world interaction outside the tiny authored catalog | P0 | ADR-022 open-world correction | Resolved without compatibility: spatial coordinates are indexing metadata, `InteractionFeature` remains the lifetime/body owner, drop uses one authoritative carrier-relative pose, and unload/reload cannot suspend or hide the object |
| A-F055 | Vehicle handling had only subjective play evidence, so friction/stability changes could silently trade braking, lateral slip, recovery, and rollover behavior | P1 | First handling correction | Resolved for the current single archetype: explicit backend-neutral tire curves and a real-Jolt 120 Hz rig measure stopping, steady turn, slip, slalom, skid recovery, and rollover; the report and tuning skill preserve accepted tradeoffs |
| A-F056 | Incident manifests write stale protocol/snapshot literals instead of sourcing the accepted live cohort, so a navigation incident could misidentify the runtime that produced it | P1 | S12-A preflight | Resolved: schema-4 manifests source protocol/replay/snapshot cohort constants, drift tests fail closed, and a fresh protocol-14/replay-14/snapshot-13 bundle passes strict inspection |
| A-F057 | NPC base intent is a cooked node reference; route results conflate inactive/capacity/disconnected outcomes, and failed displacement recovery may restore an old pose | P1 | S12 destination/recovery contract | Resolved under [ADR-023](docs/adr/023-semantic-destinations-and-navigation-recovery.md): semantic destination intent, one pure typed planner, explicit execution status/lineage, collision-aware re-anchoring, confirmed edge exclusions, and a zero-teleport counter replace raw-node/BFS/snap-back behavior |
| A-F058 | The installed six-node line and triangle presentation cannot exercise alternate routes, topology replanning, or human-readable navigation diagnosis | P1 | S12 playable evaluation | Resolved and accepted for the bounded slice: the installed 16-node/32-edge urban block has two transactional seam gates, visible blockers, six destinations, Navigation Lab, independent overlays, schema-4 route evidence, and a completed product-owner walkthrough |
| A-F059 | The conventional renderer lacked a versioned neural-input ABI, paired-capture path, runtime inference owner, and promoted-model content contract; adding these directly to `renderer.zig` would conflate renderer, experiment, content, and history lifecycles | P1 | NR0 game-specific neural-rendering feasibility slice | Resolved at the foundation level by ADR-025 and accepted NR0-A through NR0-D: engine-owned input/capture/evaluation hosts and external experiment ownership are separate. Promotion and the final GPU-resident runtime remain intentionally blocked on a worthy title model. |
| A-F060 | A visually rich pretrained video model could redirect the engine toward external checkpoints, fine-tuning, appearance-only conditioning, or pseudo-targets instead of the intended reproducible game-owned renderer | P1 | Post-NR-0003 strategy correction | Resolved by ADR-026 and the title neural renderer north star: learned product components start from declared random initialization on title-owned exact pairs; NR-0003 is comparison evidence only; NR4-A is human-accepted and NR4-B now proves the exact rights-clean direction over motion. |
| A-F061 | Ordinary macOS graphical binaries still compile/link the dormant Core ML adapter and neural-input shaders even though no learned bundle is installed or selected | P2 | Before distribution, secondary-platform work, or a measured default-build/runtime problem | Open but non-blocking for the current macOS developer product: runtime activation is explicit through neural-only environment inputs and returns before allocating neural hosts by default. Do not add a speculative compatibility layer while the track is paused; first measure binary/build/platform cost, then either keep the direct macOS linkage or add one explicit build exclusion. |
| A-F062 | SDL 3.4.14's Metal backend inverted the documented `SDL_QueryGPUFence` result while screenshot, semantic-ID, and physics-debug consumers also fenced a later empty submission instead of the frame containing their work | P0 | DR1-A native evidence | Resolved at the exact platform/submission boundary: one macOS cohort helper inverts only the pinned 3.4.14 result and names upstream removal commit `b340ddcd7b44511f7b49005ba4a91a3c9907f77e`; the renderer acquires and reference-shares the real frame-submission fence. Foreground native runs restore district residency plus 362/362 trail and 31/31 anchor completions with zero misses/failures, and the final full journey repeats zero failures. |
| A-F063 | The engine had no ranged-combat rule owner, authoritative ray/occlusion boundary, finite-ammunition state, or correlated replay/incident contract; allowing clients to name targets would have broken the shared solo/multiplayer source of truth | P1 | S14 ranged combat | Resolved by ADR-027: one backend-neutral handgun feature owns admission/ammo/deadlines, session authority derives current pose and stable semantic/Jolt hit results, vitals owns damage/death, and clients receive only authoritative results/snapshots/events. Protocol, replay, fault, reconnect, incident, Metal, listen, and dedicated gates cover the boundary without lag-compensation or firearms-framework scope. |
| A-F064 | Reliable weapon results and unreliable snapshots can cross in transit; the first S14 client projection also treated the latest result as permanent HUD state, masking later reload completion, while the private-listen local adapter did not drain weapon/shot feedback | P1 | S14 graphical acceptance | Resolved: weapon results carry the authority tick, client weapon state advances monotonically across result/snapshot lanes, combat presentation treats results as feedback rather than a second state owner, and private-listen host controls/feedback now match the remote graphical client. Regression tests plus real-GNS listen/dedicated observer journeys prove convergence and publication. |
| A-F065 | The content path proved deterministic embedded PNG base-color material cooking and GPU residency but required a texture, UV0, one sampler policy, and fixture-sized district limits; it was not yet a practical project asset workflow | P1 | EA1 materials/textures | EA1-A candidate resolves import/runtime pressure with host-only GLB/glTF plus rooted PNG/JPEG dependencies, optional base-color textures, explicit color/sampler state, measured limits, stable game-owned identities, project content, renderer residency, Content Browser/Inspector, CLI parity, source-package proof, and native Metal automation. EA1-B still owns richer material inputs plus preview, assignment, revert, and durable commit; product-owner EA1-A visual review remains first. |
| A-F066 | Revisioned authoring and undo/redo existed only for crate relocation; Render Lab settings bypass an owner request, and no discoverable typed process-local path let an LLM inspect/apply/revert validated settings | P1 | EA0.5 foundation, then EA1-EA3 feature owners | EA0 and EA0.5 foundation resolved: stable run/asset/target/transaction/revision/source/scope contracts, typed crate authority transactions, authored-change evidence, executable four-owner classification, owner-safe local discovery/transport, five concrete schemas, and the canonical CLI are implemented. The sandbox-aware protocol/transport/client are truthfully game tooling, while the socket thread owns no mutable product policy. EA1-EA3 must add their own material, vehicle, and lighting owner transactions through the accepted client rather than a generic CVar/property/command system. |
| A-F067 | The deterministic renderer owns a valid directional sun/ambient contract, but title values are fixed at startup and no stable authored point-light, selection, persistence, gizmo, or incident correlation exists | P2 | EA3 lighting | Open under ADR-029: make the game-owned sun preset and stable point lights editable through typed presentation owners after EA2 proves the shared authoring/control adapter |
| A-F068 | The accepted four-district map combines deterministic cooked scenes with hard-coded game-specific recipe/composition/population arrays, so ordinary map construction still requires Zig edits and engine/game ownership is not physically provable | P1 | EA4 then EA5/G1 | Open under ADR-029: introduce a versioned game-owned placed-asset map and construction workflow in EA4, reproduce S15 without changing behavior, then prove the separately built game/content boundary in EA5/G1 |

EA0.5's graphical composition adapter is intentionally substantial because it
projects live owner state and correlates typed producer results at the one
composition root. It is not a second authority and is not a current blocker.
Before EA1/EA2 materially expand endpoint schemas, extract projection and
correlation by demonstrated feature boundary rather than allowing `main.zig`
to become the permanent home of every future authoring schema.

No finding authorizes a service locator, universal mutable context, generic
command bus, reflective ECS replication framework, speculative backend layer,
or platform expansion.

## Multiplayer Pressure on Existing Boundaries

### Source of truth

The authoritative world must remain the only source of gameplay truth in every
mode. A solo process may embed that authority, but the graphical client remains
a requester and approximate observer. Client prediction is disposable and
reconciled; it never becomes persistence or authority.

NPC decisions, physics, vehicle occupancy, carried-object ownership, district
ownership, spawn/despawn, and durable saves remain server-owned. Lobby and
party services discover or assemble a session; they do not own world state.

Dedicated authority is canonical for public multiplayer. MP6 implements one
accepted constrained localhost/LAN private listen proof with explicit host trust,
performance, latency, availability, and shutdown limitations. Public Internet,
Steam P2P/SDR, NAT/relay, and host migration remain later work. P2P may
describe how guests reach that listen authority; it never means shared
authority or peer lockstep.

Authority placement (`embedded`, `listen`, `dedicated`), connection route
(`local`, `direct_ip`, `steam_p2p`, `steam_sdr`), and identity provider remain
separate concerns. This prevents Steam lobby/identity/routing decisions from
leaking into gameplay authority or persistence.

### One-world process model

The current one-Flecs-world rule fits a dedicated authority and can fit an
embedded/listen authority if the graphical client stores a lightweight
replicated scene rather than a second authoritative `Simulation`. A client
prediction world, editor preview world, hot authority replacement, or full
client ECS would require a later measured decision to replace/fork zflecs or
separate processes. The accepted MP0 topology makes that choice without
pretending the constraint does not exist.

### Persistence and replay

Durable saves, network snapshots, and replay envelopes serve different
lifetimes:

| Artifact | Owner | Purpose | Lifetime |
|---|---|---|---|
| Durable save | Authority snapshot source + persistence owner | Canonical complete logical recovery; authority captures, persistence owner encodes/commits | Across process/session restart |
| Replication snapshot | Authority per connection | Relevant approximate client state | Short-lived network baseline |
| Client prediction history | Client | Responsive local correction | Bounded recent ticks |
| Accepted-ingress replay | Authority evidence | Reproduce admitted semantic work | Exact diagnostic cohort |

They may share feature-owned value encoders only where their invariants are
actually identical. They must not share a wire envelope merely because all
contain entity state.

### Scheduling and threading

Network polling, decode, admission, authority ticks, replication extraction,
and send routing are host/session responsibilities around the existing runtime
phases. A transport callback cannot mutate ECS, Jolt, persistence, UI, or
renderer state. The first implementation should keep authority single-threaded
and make bounded queues visible before considering parallel simulation.

The selected GNS adapter has one explicit connection/callback owner. It pumps
independently of world loading and exchanges bounded copied envelopes with the
client/authority owners. No GNS or Steam handle, callback, address, or identity
enters Flecs, Jolt, a gameplay feature, persistence, or replication schemas.

## Recommended Cleanup Sequence

Architectural cleanup should be delivered through the multiplayer program,
not as an unbounded file-reorganization phase.

1. **MP0 records decisions and budgets — complete.** Topology, identity, protocol,
   dedicated-first placement, GNS, direct-IP-first routing, Steam compatibility,
   initial player scale, starting rates, impairment profiles, and per-client
   ceilings are recorded as initial contracts.
2. **MP1 separates owners — historical character seam complete.** The
   graphical client, authoritative session, and typed local link became
   explicit; M5 owns the later whole-gameplay cohesion work.
3. **M5 completes embedded cohesion — complete and accepted.** M5 uses one
   embedded/dedicated authority behavior and
   60 Hz clock, routes local character/vehicle/carry gameplay through semantic
   admission, and introduces opaque streaming and persistence owners plus
   narrower private authority contracts and an opaque heap-stable developer
   owner. Aggregate regression and independent review are recorded in the
   acceptance evidence.
4. **MP2 proves the boundary — character slice complete and audited.** Two clients connect to one authority with
   versioned admission, session identities, sequenced input, initial state,
   snapshots, interpolation, leave, and reconnect.
5. **MP3 adds responsiveness and fault evidence — complete for character.**
   Bounded prediction, reconciliation, impairment, quotas, network diagnostics,
   terminal lifecycle, and accepted-ingress replay are accepted.
6. **MP4 decomposes features when touched — complete.** Vehicle, interaction,
   district, and NPC replication reuse explicit semantic feature surfaces
   without exposing private components or backend handles.
7. **MP5/M4 close the open multiplayer foundation — complete.** Open room
   admission, real-GNS placement, bounded relevance/deltas, and architecture
   evidence are accepted without proprietary service dependencies.
8. **M6 hardens the authority transaction — complete and accepted.** The
   implementation freezes class-reserved bounded ingress, separates admission from semantic work,
   prepare immutable derivatives, publish outputs atomically, lease delivery,
   acknowledge reliable application per lane, and queue durable decisions as
   specified in the
   [`M6 Transactional Authority Cycle`](docs/design/post-m5-transactional-authority-cycle.md).
9. **MP6 makes room flow playable — complete and accepted.** The
   generation-safe client coordinator, graphical room lifecycle, constrained
   localhost/LAN listen placement, dedicated direct-IP parity, real-GNS process
   proofs, and deterministic lifecycle harness are accepted in
   [`MP6 Playable Multiplayer Room Flow Acceptance`](docs/validation/mp6-playable-multiplayer-room-flow.md).
10. **S10 adds damage/death/respawn — complete and accepted.** Backend-neutral
    bounded vitals, authoritative melee, exactly-once death cleanup, dead
    reconnect, and deterministic generational avatar respawn are accepted in
    [`S10 Damage, Death, And Respawn Acceptance`](docs/validation/s10-damage-death-respawn.md).
11. **S11 scale and ECS access reassessment — complete.** The paired ReleaseFast
    64-NPC/16-participant workload measured a worst 49,083 ns p99, 81,920-byte
    paired RSS delta, 147,160 fixed feature bytes, and zero workload
    allocations. Fixed-array single-threaded authority remains appropriate;
    no Flecs query, scheduler, or parallel execution response is justified.

12. **S11 architectural pressure test — complete and accepted.** The
    [`S11 NPC Encounter And Combat-Response Acceptance`](docs/validation/s11-npc-encounter-combat-response.md)
    applies the accepted source-of-truth model to authority-owned perception,
    target selection, navigation desire, NPC melee, damage reaction, death,
    replacement, presentation, and debugging. Its entry gates explicitly keep
    autonomy out of `AuthorityCore`, preserve NPC/vitals movement and health
    ownership, reject registration order as a combat rule, and provide
    deterministic fault/replay/reconnect/64-NPC scale evidence without a
    scheduler, generic AI framework, or parallel-ECS response.
13. **Post-S11 playable-runtime correction and interaction validation —
    accepted.** The corrective and IV phases close the movement/facing,
    blocker, wheel, client-input, projection-clock, combat-presentation,
    streamed-route, reliable-delivery, persistent-headless, ordinary
    product-bootstrap/lifecycle, causal-trace, silent-action, close-contact,
    and human-visible death gaps found by real play plus independent audits.
    It also reduced the then-automatic product population to six distinct
    authored nodes while retaining 64 as a synthetic pressure profile and
    recording the physical-density gap later resolved by S13. The complete automated matrix and direct rendered
    acceptance pass; the historical corrective record is superseded by the
    accepted
    [`Gameplay Interaction Validation And Observability Evidence`](docs/validation/gameplay-interaction-validation-and-observability.md).
14. **IC5 and the open-world corrective — complete and human-accepted.**
    Schema-3 incident evidence, destructive/failure hardening, recipe-5 open
    traversal, collision-driven NPC route rebasing, spatial carryable lifetime,
    district/navigation overlays, and objective vehicle handling close the
    current macOS baseline without adding a telemetry platform, generic
    streaming framework, or speculative AI/navigation stack.

S12 supplies the intended route boundary: semantic destination is durable
intent, route state is derived, district authority owns topology/gates, and
physical pose remains truth. S13 now gives population pressure a narrow owner. Stable
population membership survives disposable NPC actor replacement; an immutable
sandbox catalog owns roles, cyclic activity programs, sites, activity slots,
spawn slots, and explicit combat disposition; a bounded population runtime
owns activity/claim/replacement decisions; and NPC/navigation/encounter/vitals/
session retain their existing movement, route, combat, health, and routing
responsibilities. The initial 12-member product and 16-member physical cohort
are deliberately separate from the 64-NPC synthetic engine ceiling.

This is architecturally preferable to adopting a broad AI stack now. Activity
owns why a destination is selected, S12 owns how it is reached, and a
free/claimed/occupied slot ledger owns exclusive use. Behavior graphs,
navmeshes, crowd avoidance, simulation/representation/replication LOD, and
generative agents remain explicit measured triggers. The recorded p99 for the
sixteen-controller real-Jolt cohort is 0.027 ms, so no broad AI/crowd framework
is justified by current pressure. See
[`ADR-024`](docs/adr/024-authored-population-intent-and-activity-slots.md),
the
[`S13 plan`](docs/design/s13-authored-population-and-sandbox-activity.md), and
the
[`S13 evaluation world`](docs/design/s13-population-evaluation-world.md), with
executed evidence in the
[`S13 validation ledger`](docs/validation/s13-authored-population-and-sandbox-activity.md)
and [`performance baseline`](docs/performance/s13-baseline.md).

## Architecture Definition of Done Through S13

M4 satisfies the remote multiplayer foundation. M5 satisfies embedded
cohesion. M6 satisfies the transactional authority boundary. MP6 satisfies the
playable room and constrained listen/dedicated placement criteria. S10 proves
player combat/lifecycle authority. S11 proves that a second combat producer,
autonomous NPC behavior, death presentation, and durable replacement can extend
those boundaries without moving source of truth into the client. S12 separates
semantic destination from derived route, and S13 separates durable population
intent from disposable physical actors while preserving the same authority in
solo, listen, and dedicated placements; the linked acceptance records contain
the evidence.

- Embedded solo, constrained listen, and dedicated placement share one authority
  model; public Internet/Steam/NAT listen-host productization remains future work.
- The visual client cannot mutate `Simulation`, Flecs, Jolt, or durable storage
  directly.
- The authority product can run without SDL, GPU, renderer, editor, visual
  content, lobby SDKs, or client prediction code.
- Local and network links deliver the same typed protocol semantics without a
  generic message bus.
- Durable and replicated state have separate schemas, limits, and validation.
- Persisted NPC route modes distinguish an exact admitted prefix from an
  owner-aligned deferred rebuild, and pending encounter pursuit survives
  inactive streamed content without false completion.
- Session/network identity never leaks raw Flecs or Jolt handles.
- Prediction is explicitly non-authoritative and corrects from server state.
- Feature-owned replication does not expose private components or backend
  types.
- All remote ingress has bounded sequencing, ownership, quota, and outcome
  policy.
- The placement and authority traces prove their actual nested owner order. The
  authority trace covers all eight transactional stages, completed failure
  prefixes, retained first fault, and absent publication after failure.
- Adapter acceptance, client application receipt, reconnect replay, and durable
  storage are explicit bounded owner state machines rather than hidden inside
  simulation mutation.
- Logical gameplay publication is independent from the per-tick wire quota;
  bounded ledgers drain through ordered cursors and retire only a consumer that
  exhausts its declared retained window.
- Existing save, replay, diagnostics, package, and macOS readiness guarantees
  remain intact or are deliberately superseded by reviewed evidence.
- NPC movement, vitals, encounter decisions, replacement policy, session
  projection, and client presentation retain distinct owners and contracts.
- The normal embedded product composes one playable hostile through the same
  host-managed authority boundary rather than relying on a validation-only
  scenario. A separate narrow product-character owner correlates the local
  player's authority-owned death/despawn/respawn lifecycle instead of treating
  expected character outcomes as bootstrap faults.
- The declared fully engaged scale ceiling remains far below the retained
  4.166 ms feature budget with zero workload allocation.

## Explicit Non-Goals

- General-purpose engine networking or automatic component replication.
- Peer-to-peer or lockstep authority.
- Cross-platform deterministic Jolt simulation.
- Accounts, commerce, social graph, matchmaking backend, anti-cheat platform,
  distributed persistence, sharding, or MMO operations.
- Host migration before the initial session product requires it.
- Linux/SteamOS/Windows implementation during the macOS architecture proof.
- Multiple simultaneous authoritative worlds in one process.
- Mandatory Steamworks, lobby, SDR, cloud, or orchestration dependencies in the
  open engine or cold direct-GNS authority.

## Reference Influences

These are comparison points, not frameworks Incinerator promises to reproduce:

- [Flecs design guidance](https://www.flecs.dev/flecs/md_docs_2DesignWithFlecs.html)
  recommends feature-oriented modules, while the
  [systems/staging model](https://www.flecs.dev/flecs/md_docs_2Systems.html)
  documents deferred structural mutation and explicit sync behavior.
- [Bevy render extraction](https://docs.rs/bevy/latest/bevy/render/struct.Extract.html)
  provides a current example of read-only simulation-to-render-world
  extraction and independent presentation scheduling.
- [SDL GPU architecture](https://wiki.libsdl.org/SDL3/CategoryGPU) reinforces
  explicit command-buffer, pass, resource, fence, and submission ownership.
- [Jolt deterministic-simulation guidance](https://jrouwe.github.io/JoltPhysicsDocs/3.0.1/)
  motivates the exact-cohort replay nonclaims and server-snapshot approach
  rather than peer lockstep assumptions.
- [GameNetworkingSockets API contracts](https://github.com/ValveSoftware/GameNetworkingSockets/blob/master/include/steam/isteamnetworkingsockets.h)
  distinguish transport queue acceptance from application observation and
  guarantee reliable ordering only within one lane.
- [Steam matchmaking and lobbies](https://partner.steamgames.com/doc/features/multiplayer/matchmaking?language=english)
  provide a mature comparison for lobby assembly followed by a separate host
  or game-server connection.
- [Unreal Gameplay Framework](https://dev.epicgames.com/documentation/en-us/unreal-engine/gameplay-framework-in-unreal-engine)
  is a comparison for persistent player/controller lifetime possessing a
  replaceable physical avatar.
- [Jolt narrow-phase queries](https://jrouwe.github.io/JoltPhysics/class_narrow_phase_query.html)
  provide the accepted backend capability for authoritative melee and safe
  spawn occupancy checks.
- [Valve lag compensation](https://developer.valvesoftware.com/wiki/Lag_Compensation)
  is a later bounded-rewind reference and is explicitly not part of S10.
- [Unreal Gameplay Debugger](https://dev.epicgames.com/documentation/unreal-engine/using-the-gameplay-debugger-in-unreal-engine)
  and [Visual Logger](https://dev.epicgames.com/documentation/en-us/unreal-engine/visual-logger-in-unreal-engine)
  inform S11's immutable inspection, spatial overlays, and bounded transition
  evidence without becoming runtime dependencies.

## Review Cadence

Update this document:

- when a multiplayer ADR is accepted, rejected, or superseded;
- at the close of every MP phase;
- when a finding changes priority or is resolved;
- before introducing a shared scheduler, replication, asset, physics, or
  service abstraction;
- when a separately licensed game consumer is created;
- before selecting a second platform or public engine license.
