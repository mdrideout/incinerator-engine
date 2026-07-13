# M3 Pre-Server Readiness Design

> **Historical pre-cleanup design.** This was the delivery contract when M3
> closed. Product/module layout below may have been consolidated later. See
> [ADR-015](../adr/015-macos-pre-server-readiness.md) and the
> [cleanup plan](../../CLEANUP_PLAN.md) for current architecture.

**Status:** Complete and independently reviewed

**Platform:** Apple Silicon macOS only

**Scope:** Operational headless authority before multiplayer

The governing decision is
[ADR-015](../adr/015-macos-pre-server-readiness.md). M3 closes the final
pre-multiplayer phase without implementing networking. Acceptance and measured
budgets are recorded separately once the integrated product and soak pass.

## Outcome

One installed, renderer-free process launches outside the repository, admits
an exact versioned configuration and logical content cohort, constructs or
restores one authoritative world, accepts bounded synthetic crate-relocation
producers, advances fixed ticks without skipping authority, drains accepted
work, commits a healthy canonical save, and restores it in a fresh process.

The intended owner flow is:

```text
bounded CLI/config/content/save bytes
  -> exact preflight before world construction
  -> one Simulation on one owner thread
  -> bounded external router
  -> feature command reservation
  -> fixed 120 Hz tick
  -> feature outcome
  -> exact transaction owner delivery
  -> healthy quiescent snapshot
  -> durable save commit
  -> reverse-order teardown
```

No node in that flow imports or requires SDL, GPU, renderer, editor, shader,
source-art, or cooked visual-bundle code.

## Current Implementation Snapshot

The implementation and final acceptance matrix are complete. Evidence is
recorded in [`m3-acceptance.md`](../validation/m3-acceptance.md) and the
measured [`m3-baseline.md`](../performance/m3-baseline.md).

| Area | Current state |
|---|---|
| One-world policy | `Runtime` enforces one live owned Flecs world; the operational host constructs only after exact preflight and replaces authority only by durable process restart |
| Feature boundaries | Fixed command/outcome/event capacities, reservation, typed rejection, saturation, drain, reuse, and diagnostics are implemented across crate, character, vehicle, district, interaction, and NPC paths |
| External producers | A fixed generational router is wired to the sole authority and proves exact completion ownership, four distinct saturation modes, shutdown closure, and retained fault evidence |
| Cold product graph | Early `-Dproduct=headless`, lazy visual dependencies, exact install allowlist, source/linkage/install verification, and isolated extracted-tree Debug/ReleaseFast checks pass |
| Startup policy | The installed product consumes bounded V1 configuration and logical-only content, rejects incompatible cohorts before authority construction, and supports three explicit restore policies |
| Clock and signals | Rational 120 Hz virtual/real-time scheduling, soft-lag authority-only catch-up, hard-lag failure, and minimal macOS `SIGINT`/`SIGTERM` handling are integrated |
| Durable lifecycle | The owner loop drains all accepted work and outputs before committing the S5 envelope through the macOS save-slot adapter; failure preserves the prior slot |
| Soak and review | Versioned routine/long soaks, three-run budgets, the installed failure/restart matrix, full macOS gates, and independent P0/P1/P2 review pass |

## M3-A: Bound Every Authority Edge

The feature budgets are part of the product contract, not dynamically growing
defaults:

| Feature | Commands | Outcomes | Events | Admission rule |
|---|---:|---:|---:|---|
| Crates | 128 | 128 | — | accepted command retains one outcome slot |
| Character | 128 | 128 | 256 | accepted command retains one outcome; event overflow is counted |
| Vehicle | 128 | 128 | 256 | accepted command retains one outcome; event overflow is counted |
| District | 16 | 32 | 16 | load reserves acknowledgement + completion; cancel/unload reserve one; event overflow is counted |
| Interaction | 16 | 16 | — | commands and unread outcomes share one delivery budget |
| NPC | 128 | 128 | 256 | commands and unread outcomes share one delivery budget; event class loss is counted |

An enqueue failure is a typed capacity result and leaves the feature unchanged.
Outcome occupancy is never solved by dropping unread authority. Event queues
are permitted to lose only observational entries, with occupancy, capacity,
high-water, and cumulative loss visible through diagnostics. Active and
presentation collections are preallocated to their declared world capacities;
steady-state command processing must not use unbounded growth as backpressure.

The M3 external-router cohort is exact:

| Resource | Capacity |
|---|---:|
| Registered synthetic producers | 2 |
| Shared ingress FIFO | 16 |
| Live transaction table | 16 |
| Pending transactions per producer | 8 |
| Reserved result entries per producer | 8 |

Producer handles carry slot plus generation. Transaction ID zero, duplicate
IDs among live or unread transactions, stale handles, exhausted quota,
exhausted ingress/transaction/delivery
capacity, registration during drain, and submission during shutdown all have
distinct typed results. Every accepted transaction owns one delivery
reservation before the router invokes the world submit port.

The first contract intentionally routes only `RelocateCrate`. A retryable
feature queue result leaves the FIFO head in place. A terminal submit rejection
uses the already-reserved result slot. Once the world accepts a command, the
router retains the transaction until one matching final outcome is delivered
and polled. Non-relocation, unknown, never-submitted, duplicate-final, or
identity-mismatched outcomes are returned to the composition as explicit
handback; they are never discarded.

Polling a terminal result releases its transaction ID. M3 has no lossy
transport and therefore retains no retry tombstone. S9 must define bounded
idempotency before a remote client may retry a consumed transaction.

### M3-A acceptance evidence

- [x] Wire the router to the sole operational `Simulation` owner and prove
  exact result delivery with both producers active.
- [x] Exercise every feature queue to full, verify typed admission rejection,
  drain it, and reuse the full capacity without changed authority.
- [x] Verify queue/reservation occupancy, high-water, and reject/drop counters
  in the shared headless diagnostics export.
- [x] Prove no authority outcome is lost during interleaved host, producer,
  district-worker, and feature traffic.

## M3-B: Cold Product and Startup Admission

The root build selects `-Dproduct=headless` before any client dependency is
resolved. The cold graph resolves only the engine/kernel/feature sources,
`zflecs`/Flecs, the JoltC/Jolt physics package, and necessary macOS system
libraries. Visual dependencies remain lazy and unreachable from this branch.

The installed tree is an allowlist, not a blacklist after copying the normal
client install:

```text
bin/incinerator_headless
etc/incinerator/headless/config.example.json
share/incinerator/headless/content.json
```

The product boundary is checked at four levels:

1. allowed source imports;
2. build-graph dependency resolution from an extracted shaderless tree and
   isolated package/cache roots;
3. final Mach-O linkage and forbidden symbol/string markers;
4. exact installed-file membership from an unrelated working directory.

SDL, Metal/GPU, renderer, editor, ImGui/zgui, zmath, zmesh, zstbi, shader
tools/artifacts, `assets`, and cooked visual content must be absent at every
level. macOS is the only accepted target; a Linux or Windows request fails
explicitly and creates no portability obligation.

Startup reads bounded files and completes this order before constructing
`Simulation`:

1. parse exact CLI options and reject missing/duplicate/relative product input
   paths as defined by the host contract;
2. read at most 64 KiB of configuration and validate exact schema V1;
3. read at most 16 KiB of logical content manifest and validate its exact
   catalog/district/hash cohort;
4. require the configuration and manifest content digests to match;
5. validate the absolute save root, restricted slot identifier, startup
   policy, clock, drain, and fixed producer limits;
6. recover a stale candidate without promoting it;
7. according to startup policy, either construct fresh state or load, validate,
   and restore the committed save;
8. acquire the process's sole world only after every applicable cold preflight
   succeeds.

The V1 world cohort is namespace `9001`, at most 128 crates, one player
character, one vehicle, and exactly 64 NPC capacity in the supplied example.
The logical manifest identifies only the S6/S8 two-district authority cohort;
it does not install render meshes, textures, shaders, or GPU metadata.

### M3-B acceptance evidence

- [x] Make the installed binary's production entry point consume the V1
  configuration and logical manifest rather than the earlier conformance
  scenario.
- [x] Prove malformed, unknown-field, oversized, incompatible, missing, and
  mutually mismatched startup inputs fail before Flecs/Jolt acquisition.
- [x] Run Debug and ReleaseFast cold builds with visual package caches absent,
  then verify the installed tree and Mach-O from `/tmp`.
- [x] Record the exact resolved and linked dependency inventory in M3
  acceptance evidence.

## M3-C: Operational Lifecycle

### Owner-thread loop

The server-shaped host has one owner loop and one fixed schedule. At each
sample it observes the stop flag and scheduler decision, optionally admits or
pumps external work, runs only the granted authoritative ticks, routes every
produced completion, polls producer-owned results, and exports bounded
diagnostics. It does not add a second physics step, wall-clock delta, renderer
callback, or background world mutation.

Virtual mode grants bounded batches until exactly `virtual_ticks` complete.
Real-time mode computes due ticks from elapsed nanoseconds at rational 120 Hz:

- grant at most `max_catch_up_ticks` (V1: 8) per sample;
- at `soft_lag_ticks` (V1: 8), stop admitting/pumping new producer ingress so
  existing authority can catch up;
- at `hard_lag_ticks` (V1: 120), initiate an orderly non-success stop;
- never skip or synthesize an authoritative simulation tick.

Clock reversal, counter/range exhaustion, an immutable runtime fault, worker
contract failure, or tick error is terminal for that process. Diagnostics may
still be emitted, but the live state is not eligible to overwrite a prior
healthy save.

### Signal and shutdown contract

The macOS `SIGINT`/`SIGTERM` handler only stores one atomic flag. The owner
thread converts that flag into lifecycle state. Shutdown then:

1. transitions the external router from `accepting` to `draining`;
2. refuses registration and new transactions;
3. pumps accepted ingress and ticks the world for at most
   `drain_tick_budget` (V1: 256);
4. routes all final relocation outcomes and requires producers to poll their
   reserved results;
5. requires router, feature queues, district worker, and outputs to be
   quiescent;
6. checks that the world has no immutable first fault;
7. creates canonical Snapshot V7 bytes and wraps them in the exact S5 envelope;
8. commits through candidate write, `F_FULLFSYNC`, atomic rename, and directory
   `F_FULLFSYNC`;
9. destroys the one simulation and all native owners in exact reverse order.

A drain-budget exhaustion, unread producer result, unmatched handback,
non-quiescent worker, snapshot failure, pre-rename storage failure, or faulted
world returns failure and preserves the previous committed slot. A successful
rename followed by a directory-sync warning is surfaced as committed with a
warning because reporting it as uncommitted would permit an unsafe retry
assumption.

### M3-C acceptance evidence

- [x] Implement and test the complete owner loop over config, content, router,
  scheduler, signal guard, simulation, diagnostics, and save slots.
- [x] Prove `fresh`, `restore_required`, and `fresh_or_restore` behavior in
  separate installed processes.
- [x] Send real `SIGTERM`/`SIGINT` to an installed process and verify bounded
  drain, durable commit, clean native ownership, and fresh-process restore.
- [x] Inject a runtime/tick/storage/drain failure and prove the previous healthy
  committed slot remains authoritative.
- [x] Prove repeated start/stop/restore cycles never overlap two Flecs worlds or
  leak entities, bodies, controllers, worker jobs, transactions, or results.

## M3-D: Soak, Budgets, and Independent Review

The M3 soak is a versioned ReleaseFast virtual-time workload, not an informal
overnight run. Its routine cohort must exceed the S8 16,384-tick scale run and
exercise both external producers, saturation and recovery, crate relocation
completion ownership, district load/cancel/unload, S7 carry ownership, S8 NPC
population, snapshots, graceful stop, restore, and injected failure recovery.
A separately invokable long cohort may increase duration without changing the
scenario schema.

The measurement report must include at least:

- exact build/world/content/config/scenario cohorts;
- requested and completed ticks plus fixed-tick throughput/percentiles;
- allocator live/peak bytes and three fresh-process absolute max-RSS
  observations (not paired baseline deltas);
- entity, rigid-body, CharacterVirtual controller, vehicle, district-worker,
  and presentation-free final counts;
- every feature and router queue capacity, peak, rejection/drop count, and
  final occupancy/reservation;
- producer registrations, accepted/retried/rejected/completed transactions,
  handbacks, and unread final results;
- snapshot/envelope sizes, canonical re-save equality, durable restart count,
  and committed-save disposition;
- signal/drain/fault injection results and final ownership cleanup.

All numeric ceilings belong in the M3 performance baseline after three
representative fresh-process ReleaseFast trials. Exact capacities, completion
counts, cohort identities, canonical bytes, fault dispositions, and final-zero
ownership are deterministic gates. Wall-clock and RSS values are
machine-specific characterization ceilings, not portable promises.

### M3-D acceptance evidence

- [x] Implement the routine and opt-in long soak with a versioned report.
- [x] Establish measured budgets from fresh-process ReleaseFast trials and
  check them automatically.
- [x] Run full Debug, ReleaseFast, source-package, cold-product, installed
  lifecycle, and aggregate Apple Silicon macOS gates.
- [x] Complete independent architecture, correctness/security, build-boundary,
  and evidence reviews; close every actionable P0/P1/P2 finding.

## Future S9 Handoff Inventory

M3 deliberately leaves S9 with an inventory, not a transport framework:

| Future concern | Proven M3 input | Still required in S9 |
|---|---|---|
| Authoritative ingress | Bounded generational producer registration, quotas, transaction ownership, exact completion delivery | Protocol framing, authentication/authorization, input sequence/ack policy, remote abuse controls |
| World authority | One fixed-tick process, feature command boundaries, persistent IDs, immutable first fault | Server deployment model, connection ownership, replication rules |
| State transfer | Snapshot V7, content/build/world cohorts, renderer-free logical state | Versioned network snapshot/delta schema, join/reconnect state, bandwidth budgets |
| Reproduction | Same-cohort accepted-command replay and first-divergence diagnostics | Capture of admitted network ingress and ordering under loss/reorder/duplication |
| Interest ownership | Two districts, exact residency tickets, persistent cross-district interaction/NPC ownership | Client subscriptions, visibility rules, migration/hand-off policy at product scale |
| Persistence | One local durable slot, atomic replace, exact-cohort restore | Service ownership, concurrent writers, database/distributed durability, migration/backup policy |
| Platform | Native Apple Silicon macOS operational product | Explicit server/client deployment platform decisions, including any Linux port |
| Security | Bounded parsing/capacity and fail-closed local admission | Internet threat model, secrets, identity, encryption, privilege separation, anti-cheat, audit and incident operations |

## Acceptance Boundary

M3 is complete only when the installed cold product, bounded producers,
operational lifecycle, failure recovery, routine soak, measured budgets, full
macOS matrix, and independent review all pass. Source modules or isolated unit
tests alone do not close the phase.

## Explicit Nonclaims

M3 does not implement a network transport, wire protocol, client, replication,
prediction, reconciliation, interest distribution, account system,
authentication, authorization, distributed database, cloud save, schema
migration, hot world replacement, multi-world process, Linux/SteamOS/Windows
build, cross-platform physics determinism, orchestration platform, remote
telemetry service, or MMO operations. Multiplayer/S9 and all secondary
platforms remain future work after an explicit product decision.
