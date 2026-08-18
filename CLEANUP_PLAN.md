# Incinerator Engine Greenfield Cleanup Plan

**Status:** Complete

**Started:** 2026-07-13

**Completed:** 2026-07-13

**Scope:** Consolidate and simplify the completed S0–S8/M3 foundation before
another gameplay or networking phase.

**Current product contract:** Apple Silicon macOS only

**Related roadmap:** [`OVERHAUL_PLAN.md`](OVERHAUL_PLAN.md)

## Purpose

The pre-multiplayer program proved the engine's feature architecture,
fixed-tick authority, persistence, diagnostics, content streaming, and cold
headless boundary. This cleanup converts those accumulated vertical slices
into a smaller and clearer greenfield baseline.

The work is complete only when obsolete compatibility and deferred-platform
surface is removed, product code is separated from validation code, ownership
is explicit, game policy no longer masquerades as reusable engine policy, and
the complete macOS evidence matrix passes again.

## Non-Negotiable Decisions

1. **Greenfield means current cohort only.** No migration readers, deprecated
   aliases, legacy content fingerprints, compatibility constructors, or old
   command-line/build aliases are retained without a current consumer.
2. **Schema names are not compatibility shims.** At the 2026-07-13 cleanup
   closeout, `SnapshotV7` and feature `V1` records were the only accepted
   schemas. Later greenfield slices intentionally advance the current snapshot
   cohort without retaining migration readers; see `OVERHAUL_PLAN.md` for the
   current value.
3. **Apple Silicon macOS is the only maintained platform.** Linux, SteamOS,
   Windows, Intel macOS, mobile, web, and consoles have no current build,
   shader, CI, packaging, API-stability, or abstraction requirement.
   Vendored dependency-internal OS conditionals may remain when the top-level
   graph rejects unsupported targets before resolving them; they create no
   engine support promise.
4. **The engine and game remain separate products.** Reusable contracts own
   shapes, limits, validation, and capabilities. The sandbox/game owns
   installed coordinates, district recipes, route topology, and game content.
5. **The normal client is not an acceptance harness.** Scripted scenarios,
   failure injection, and diagnostic probes belong to a separately named
   validation composition and must be absent from the normal installed client.
6. **Ownership stays concrete.** Refactoring must not introduce a service
   locator, universal mutable context, generic command bus, dynamic plugin ABI,
   microservices, multiple physics worlds, or speculative backend portability.
7. **Historical evidence stays historical.** Phase acceptance and baseline
   records are not rewritten to imply present-day measurements. They receive a
   banner and point to the current readiness record.
8. **No license is added.** Licensing and public distribution remain an owner
   decision; the repository currently grants no license.
9. **At cleanup closeout, multiplayer remained deferred.** S9 transport,
   replication, prediction, accounts, distributed persistence, anti-cheat, and
   MMO operations were not part of cleanup. Later multiplayer work is tracked
   by the living roadmap rather than retroactively folded into this record.

## Audit Findings Register

| ID | Finding | Priority | Cleanup owner | Status |
|---|---|---:|---|---|
| C-F001 | Normal graphical product and visual/fault acceptance harness are the same executable | P1 | C3 | Resolved |
| C-F002 | Top-level `App` coordinates and implements too many independent host responsibilities | P1 | Follow-up F1 | Accepted follow-up after product/editor boundaries |
| C-F003 | Reusable district contracts own concrete sandbox coordinates, collision, and route policy | P1 | C5 | Resolved |
| C-F004 | Editor/tool state is process-global and retains host pointers | P1 | C4 | Resolved |
| C-F005 | Cold and visual Flecs builds enable unused HTTP/REST/script/metrics/module/pipeline addons | P1 | C2 | Resolved |
| C-F006 | Replay/cooker retain a legacy single-bundle content identity | P1 | C1 | Resolved |
| C-F007 | Current documents mix V4/V5, unbounded pre-M3 behavior, and future-M3 claims with the V7/M3 tree | P1 | C0 | Resolved |
| C-F008 | Active build retains deferred-platform and duplicated simulation-graph policy | P1 | C2 | Resolved |
| C-F009 | Fixed queues and frame mailboxes duplicate one proven bounded mechanic | P2 | C6 / Follow-up F2 | Queue resolved; mailbox follow-up accepted |
| C-F010 | Simulation, physics, feature roots, and build/app composition mix multiple physical responsibilities | P2 | Follow-up F1/F3 | Accepted follow-up |
| C-F011 | Dead aliases/helpers, ambiguous district aggregates, old render paths, game-owned GLBs, and phase-only measurement programs remain | P2 | C1 | Resolved |
| C-F012 | Replay cohort metadata has multiple sources and imports concrete physics policy | P2 | C6 | Resolved |
| C-F013 | ImGui frame setup hard-codes Retina display scale to `1.0` | P2 | C4 | Resolved |
| C-F014 | Target guard validates the selected triple but current docs promise rejection of non-native-host cross builds | P2 | C2/C7 | Resolved with host and target checks |
| C-F015 | Generated cohort options are centralized, but not every duplicated dependency-affecting setting is automatically compared to its real build input | P1 | C6/C7 | Resolved by passing cohort settings into dependency builds |
| C-F016 | Moving the sandbox recipe changed the canonical content cohort without refreshing checked-in cold config/readiness values | P1 | C5/C7 | Resolved with fresh config and cook-to-cold verifier |
| C-F017 | README still presents default-graph conformance-host aliases as if they were the cold operational product workflow | P2 | C0/C2 | Resolved |
| C-F018 | Bundle decoding accepts nonzero reserved/padding bytes, allowing multiple accepted wire identities for one logical payload after digest recomputation | P2 | C7 | Resolved with canonical-byte rejection tests |
| C-F019 | Navigation edge bounds use default limits instead of the caller's narrower admitted-node limit | P2 | C7 | Resolved |
| C-F020 | Offline catalog cooking compares static boxes but not the complete canonical navigation fragment before publication | P2 | C7 | Resolved with full shape and route validation |
| C-F021 | Cold build retains an unreferenced `test-headless-product` alias of its canonical `test` step | P2 | C1/C7 | Resolved |
| C-F022 | Visual zmath graph enables cross-platform determinism despite the macOS-only, non-lockstep product policy | P2 | C2/C7 | Resolved by using the native single-platform math path |
| C-F023 | Normal client binary still retains product-reachable runtime branches for validation bootstrap profiles | P1 | C3/C7 | Resolved with validation-only conditional state, compile-time shared branches, and expanded direct-binary markers |
| C-F024 | The target guard accepts Apple-Silicon macOS queries with an incompatible ABI or non-Mach-O object format | P2 | C2/C7 | Resolved with exact native OS, architecture, ABI, and object-format checks plus negative tests |
| C-F025 | The package manifest's minimum version does not enforce the repository's exact Zig 0.16.0 compatibility cohort | P1 | C2/C7 | Resolved with an exact build-time Zig version guard |
| C-F026 | Optional ImPlot wiring remains in the active editor graph without a current consumer | P2 | C1/C2 | Resolved by removing the unused dependency surface and explicitly disabling the wrapper option |
| C-F027 | Unused input helpers, rendering facades, engine exports, and test-only timing APIs remain live or public | P2 | C1 | Resolved by deleting the unconsumed surface instead of preserving aliases |
| C-F028 | The standalone cold shell scanner and canonical Zig linkage scanner enforce different prohibited marker sets | P2 | C2/C7 | Resolved by aligning scenario, fault-injection, and storage-injection marker coverage |
| C-F029 | A hidden unconsumed Claude command still documents the removed Raylib/zphysics prototype and contains broken repository links | P2 | C0/C1/C7 | Resolved by deleting the stale command under the greenfield dead-surface policy |

No P0 architectural or correctness finding was identified. The thin kernel,
feature dependency direction, one-world authority, typed feature APIs, and
cold-product isolation remain accepted strengths and must not regress during
cleanup.

## Phase C0 — Truth, Inventory, and Guardrails

**Outcome:** One persistent cleanup ledger defines the current product,
greenfield policy, accepted architecture, scope, and verification contract.

- [x] Record the audit findings and cleanup sequence in this document.
- [x] Preserve the S0–S8/M3 roadmap as historical delivery evidence.
- [x] Reconcile current README, ADR, roadmap, and readiness claims.
- [x] Label phase acceptance and performance documents as historical records.
- [x] Record the final source/module/product inventory after cleanup.
- [x] Record every deliberate deferral and remaining follow-up explicitly.

### C0 acceptance

- [x] At cleanup closure, no current document called Snapshot V4/V5 the active
  schema; the then-active composition was `SnapshotV7`. This is historical
  cleanup evidence, not a claim about the later S11 cohort.
- [x] No current document says feature authority queues remain unbounded or
  that M3 is future work.
- [x] ADR status accurately distinguishes accepted, implemented, validated,
  superseded, and historical decisions.
- [x] Historical measurements and past cross-platform results are preserved as
  dated evidence, not current support claims.

## Phase C1 — Remove Greenfield Legacy and Dead Surface

**Outcome:** Only the current catalog, persistence, command, rendering, and
host APIs remain.

- [x] Remove the replay `single_bundle` content cohort and its codec,
  fingerprint, tests, and legacy zero-dependency cooker digest.
- [x] Remove ambiguous single-district aggregate state/ticket APIs now that the
  fixed two-slot coordinate-aware contract is authoritative.
- [x] Remove deprecated/source-compatible aliases, old build aliases, dead
  public helpers, unused rendering paths, and stale commented build code.
- [x] Remove tracked game-owned demo GLBs from the engine repository after
  confirming no build/package/runtime consumer.
- [x] Remove or archive historical phase measurement programs that have no
  current acceptance role; preserve their recorded Markdown/JSON evidence.
- [x] Keep strict rejection of every non-current save, replay, bundle, catalog,
  and configuration cohort; do not replace removed readers with migrations.

### C1 acceptance

- [x] Repository search finds no legacy cohort/alias path named by this phase.
- [x] Every remaining public helper has a current non-test consumer or is an
  intentional public engine contract.
- [x] Source/package membership contains no game-owned demo art.
- [x] Historical records still identify how their measurements were produced,
  even when a retired measurement executable is no longer maintained.

## Phase C2 — Minimize the Active Build and Dependency Boundary

**Outcome:** The active build expresses one Apple Silicon macOS product cohort,
and the cold authority links only the dependency capabilities it uses.

- [x] Remove or quarantine active Linux/Windows/SteamOS target, shader,
  packaging, and help paths. They may be redesigned when a second platform is
  explicitly selected.
- [x] Retain only necessary upstream portability conditionals inside vendored
  dependencies, documenting that they are outside the engine platform contract.
- [x] Configure Flecs with the minimum addons consumed by the engine; remove
  HTTP, REST, script, metrics, and other unused surfaces.
- [x] Share the core simulation/Flecs/Jolt module graph between client and cold
  headless products without resolving visual dependencies in the cold branch.
- [x] Split focused build helpers where this reduces duplicated policy while
  retaining the early cold-headless product selection.
- [x] Add automated linkage/symbol guards for prohibited visual, validation,
  networking, and unused Flecs surfaces.

### C2 acceptance

- [x] The supported target is rejected unless it is native Apple Silicon
  macOS, with an actionable error.
- [x] The normal client and cold authority contain no deferred-platform policy
  that constrains current architecture.
- [x] The cold installed tree remains exactly the approved binary,
  configuration, and logical-content manifest.
- [x] Cold-product resolution, imports, strings/symbols, linkage, and package
  membership contain no SDL/GPU/editor/shader/visual-content dependency.

## Phase C3 — Separate Product and Validation Compositions

**Outcome:** The installed client contains normal sandbox behavior only; a
separately named validation executable owns visual smokes and fault scenarios.

- [x] Compile the shared graphical host as two separately named executable
  compositions: normal client and visual validation, with distinct reachable
  mode surfaces.
- [x] Move scripted S0–S8 scenarios, lifecycle probes, initialization
  failpoints, and deliberate application/diagnostic faults into the validation
  composition.
- [x] Restrict normal client command-line options to supported user/developer
  workflows.
- [x] Compile validation constructors and test seams out of normal client and
  cold authority products.
- [x] Run installed graphical acceptance through the separately named
  validation artifact.

### C3 acceptance

- [x] Product linkage/string guards reject validation markers and fault seams.
- [x] The normal client still runs the interactive sandbox and optional editor.
- [x] Existing installed visual behavior is reproduced by the validation
  executable without weakening exact-artifact testing.
- [x] Headless authority remains independent of both graphical roots.

## Phase C4 — Make Host and Editor Ownership Explicit

**Outcome:** The top-level app coordinates cohesive owners instead of
implementing every host concern, and editor/tool state is instance-owned.

- [x] Replace process-global editor visibility, tool registry, histories, and
  drafts with an owned `Editor` and owned tool state.
- [x] Stop retaining a renderer pointer in editor tool globals; pass immutable
  per-frame values or narrow typed requests.
- [x] Statically compose the current sandbox tools into the owned editor with
  no process-global registry; moving registration into a separately licensed
  game host is follow-up F1.
- [x] Derive ImGui framebuffer/display scale from the SDL window instead of
  hard-coding `1.0`, with a safe finite positive fallback.
- [x] Preserve explicit construction and reverse-order destruction; do not
  introduce hidden global access.

### C4 acceptance

- [x] Two sequential editor/application lifecycles do not retain stale state or
  pointers.
- [x] Editor-disabled builds do not resolve editor implementation dependencies.
- [x] Editor changes reach authority only through the same typed feature/host
  requests used outside the UI.
- [x] Failure initialization and teardown tests cover each new owner boundary.
- [x] Retina/window pixel-density changes update ImGui scale without changing
  simulation or input authority.

## Phase C5 — Separate Engine Structure from Sandbox Content Policy

**Outcome:** District contracts are reusable structural contracts; the sandbox
owns its concrete installed world recipe.

- [x] Keep district coordinates/types, limits, tickets, payload structures,
  validation rules, checksums, and loader/navigation capabilities in reusable
  engine/feature contracts.
- [x] Move west/east installed coordinates, procedural collision fixtures,
  exact route topology, and game-specific cohort policy into a sandbox-owned
  content recipe/provider.
- [x] Make cook, load, restore, replay, and hostile preflight consume one narrow
  canonical-content provider/catalog boundary.
- [x] Persist semantic content identity and checksum only; never backend handles
  or borrowed provider memory.

### C5 acceptance

- [x] Reusable district contracts contain no installed sandbox coordinates or
  exact west/east route recipe.
- [x] Changing sandbox logical content does not require changing a reusable
  district contract.
- [x] Cooked admission, live streaming, save restore, and replay agree on one
  canonical logical build and reject a mismatch before partial activation.
- [x] The source package and cold product include only the content policy each
  product deliberately owns.

## Phase C6 — Deduplicate Proven Mechanics Without Generalizing

**Outcome:** Repeated mechanics and cohort/build policy with demonstrated
consumers have one source of truth while vertical feature ownership remains
intact. Pure physical decomposition is separated from required cleanup so a
large file move cannot masquerade as architectural progress.

- [x] Extract a small kernel bounded ring primitive used behind feature-owned
  command/outcome semantics.
- [x] Centralize the current replay/simulation cohort metadata so schema,
  dependency, build, and physics settings have one source of truth.
- [x] Preserve feature-specific admission errors, outcome reservations,
  rejection counters, and diagnostics around the shared ring mechanics.
- [x] Verify the generated dependency/replay cohort against the pinned
  manifests automatically.

### C6 acceptance

- [x] Queue wrappers preserve domain-specific typed errors, reservations,
  counters, and diagnostics; there is no generic command bus.
- [x] One physics world and one simulation authority owner remain explicit.
- [x] Snapshot/replay modules do not invent a second state authority.
- [x] Architecture dependency checks still prevent feature-private imports,
  backend leakage, and renderer-to-authority mutation.

### Recorded physical-decomposition follow-ups

These are real cleanup findings, but are not closeout blockers for this pass.
The product/validation split, owned editor, sandbox recipe boundary, shared
build graph, queue primitive, and generated cohort remove the active policy and
ownership hazards. Performing the following high-churn moves simultaneously
would add broad merge/regression risk without changing runtime behavior:

- **F1 — Host composition:** split `App` into cohesive district-stream,
  sandbox/save, and developer-session owners; move sandbox-specific tool
  registration out of the editor shell. Trigger when the next host concern
  changes `App` or when the separately licensed game host is extracted.
- **F2 — Frame mailboxes:** extract a shared mailbox only after the remaining
  request buffers prove identical lifetime, overflow, and counter semantics.
  They are bounded today and pose no authority-growth risk.
- **F3 — Physical modules:** split simulation snapshot/preflight, replay,
  diagnostics, Jolt body/character/vehicle/debug internals, and oversized
  feature roots along private responsibility boundaries. Trigger before the
  next feature materially edits two or more of those concerns.

Follow-ups must preserve typed feature APIs, one world, and one physics owner;
they are not permission to introduce a generic command bus, service locator,
or runtime-polymorphic physics backend.

## Current Source and Product Inventory

This is the supported post-cleanup shape. Repository history and historical
records may describe removed cohorts, products, and platform experiments; they
are not part of this inventory.

| Boundary | Current owner and contents |
|---|---|
| Kernel/contracts | `src/engine` owns scheduling, IDs, transforms, bounded ring mechanics, and backend-neutral capability contracts |
| Feature authority | `src/features` owns crate, character, vehicle, district, interaction, navigation, population, and NPC commands/state/outcomes without SDL, editor, renderer, or concrete Jolt imports |
| Simulation composition | `src/hosts/simulation.zig` and the shared build graph compose one Flecs world, one Jolt world, fixed-tick feature authority, persistence, replay, and diagnostics |
| Sandbox/game policy | `src/sandbox`, sandbox host modules, and the content catalog own the installed two-district recipe, route, population, controls, save, and replay composition |
| Visual adapters | SDL 3, Metal through SDL GPU, renderer/content presentation, and the optional owned editor exist only in the graphical branch |
| Normal client | `zig-out/bin/incinerator_engine` runs the interactive sandbox and install verification; it contains no scripted acceptance or injected-fault dispatch |
| Visual validation | `zig-out/libexec/incinerator/incinerator_validation` is installed only by validation/readiness steps and owns graphical scenarios, lifecycle probes, and deliberate faults |
| Cold authority | `zig-out/bin/incinerator_headless` is selected by `-Dproduct=headless`; its installed tree is the executable plus exact config and logical-content manifests, with no visual dependency |
| Non-graphical tools | Installed replay/save tools and build-only cook, verification, S7/S8 measurement, and M3 soak products exercise narrow contracts without becoming runtime services |
| Content | Self-authored conformance fixtures and cooked outputs remain; the engine repository contains no game-owned demo art or active `assets/models` tree |

The active dependency cohort is exact Zig 0.16.0, SDL 3.4.14, Jolt 5.5/JoltC,
and exact tested Zig wrappers. Only native Apple Silicon macOS is accepted by
the top-level build.

## Phase C7 — Revalidate, Review, and Establish the New Baseline

**Outcome:** The simplified tree has fresh Apple Silicon macOS evidence and no
remaining actionable cleanup regression.

- [x] Run formatting and whitespace checks.
- [x] Run Debug and `ReleaseFast` aggregate suites with the editor excluded.
- [x] Run editor-enabled compilation/tests and native macOS graphical readiness.
- [x] Run cold headless product, installed allowlist/linkage, lifecycle, and M3
  routine/long soak gates.
- [x] Run extracted source-package membership and cold/normal package tests.
- [x] Validate documentation links and update the current readiness record with
  fresh counts; do not alter historical phase measurements.
- [x] Complete independent architecture, correctness/security, build-boundary,
  and documentation-drift review.

### Required commands

The exact build-step names are documented in [`README.md`](README.md). The
final gate must cover these supported workflows even if step names change
during build cleanup:

```bash
zig build test -Deditor=false --summary all
zig build -Doptimize=ReleaseFast test -Deditor=false --summary all
zig build test -Deditor=true --summary all
zig build test-macos-readiness -Doptimize=ReleaseFast -Deditor=true
zig build -Dproduct=headless test --summary all
zig build -Dproduct=headless -Doptimize=ReleaseFast test --summary all
zig build -Dproduct=headless -Doptimize=ReleaseFast measure-m3 --summary none
zig build -Dproduct=headless -Doptimize=ReleaseFast measure-m3-long --summary none
tools/verify_source_package.sh
```

### C7 acceptance

- [x] Every required gate passes from the final tree in the exact supported
  Zig 0.16.0 cohort.
- [x] Normal client, visual validation, source package, and cold authority have
  explicit and independently checked membership boundaries.
- [x] Fresh performance evidence remains within declared M3 ceilings or records
  and explains an intentionally accepted new baseline.
- [x] Independent review reports no unrecorded actionable P0/P1/P2 finding and
  accepts the explicit trigger-based physical-decomposition follow-ups.

## Explicit Deferrals

- S9 multiplayer and all networking/online-service work.
- Linux, SteamOS, Windows, Intel macOS, mobile, web, and console support.
- Cross-platform deterministic physics or lockstep.
- A general asset database, VFS, hot reload, CDN, patcher, or content migration
  framework.
- A generalized editor/plugin ABI, universal engine context, or runtime service
  locator.
- Multiple simultaneous Flecs/Jolt worlds or in-process world replacement.
- Engine licensing and public distribution.
- General navmesh, traffic, combat, behavior-tree, crowd, or MMO-scale systems.

## Progress Log

| Date | Phase | Result | Evidence |
|---|---|---|---|
| 2026-07-13 | Audit | No P0 architectural/correctness defect; concentrated cleanup debt identified above the kernel | Repository audit and passing pre-cleanup S0–S8/M3 matrix |
| 2026-07-13 | C0 | Current docs reconciled; ADR statuses corrected; phase designs, acceptance records, and baselines labeled historical; current inventory and deferrals recorded | README, roadmap, ADR, readiness, and repository link/whitespace sweeps |
| 2026-07-13 | C1 | Removed the single-bundle cohort, obsolete aliases/aggregates/helpers/render paths, S0–S3 measure sources, unconsumed demo GLBs, and the hidden stale prototype command while preserving strict current-cohort rejection and historical records | Source/package searches, tracked-hidden documentation sweep, and aggregate tests |
| 2026-07-13 | C2 | Reduced the top-level graph to native Apple Silicon macOS, one MSL/Metal shader path, minimal Flecs, and one shared visual/cold simulation graph with early target and linkage guards | Build-helper tests, cold-product boundary, and source/package gates |
| 2026-07-13 | C3 | Split the normal `incinerator_engine` client from the separately installed `incinerator_validation` scenario/fault host | Product/validation marker scanner and installed graphical steps |
| 2026-07-13 | C4 | Replaced process-global editor/tool state with an owned instance, narrow frame/event inputs, and SDL-derived Retina scale | Editor/editor-disabled tests and native lifecycle gates |
| 2026-07-13 | C5 | Moved installed coordinates, procedural collision, and route topology behind the sandbox district recipe while retaining structural district contracts | Cook/catalog/load/replay/save/preflight tests |
| 2026-07-13 | C6 | Shared bounded ring mechanics behind typed feature queues; generated replay/physics/Flecs cohort settings now feed the real dependency graph while exact revisions are checked against manifests | Queue saturation tests and dependency-cohort verifier |
| 2026-07-13 | C7 | Re-established the final macOS baseline and closed independent review with no unrecorded actionable P0/P1/P2 finding | Debug and ReleaseFast editor-excluded 169/169 steps and 589/589 tests each; Debug editor-enabled 172/172 and 589/589; native readiness 80/80; Debug and ReleaseFast cold 32/32 and 52/52 each; extracted source 98/98 and 196/196 plus cold 32/32 and 52/52; routine/long M3 ceilings pass; formatting, whitespace, tracked-hidden links, target/toolchain negatives, and product-boundary scans pass |

## Completion Rule

This plan becomes **Complete** only after C0–C7 acceptance is checked, the
current readiness record contains fresh final-tree evidence, and independent
review is clean. A deliberately deferred item is not incomplete work; any
non-deferred unchecked item must be either completed or moved to an explicit,
justified follow-up before closeout.
