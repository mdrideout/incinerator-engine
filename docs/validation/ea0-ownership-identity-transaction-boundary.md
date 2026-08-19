# EA0 Ownership, Identity, and Transaction Boundary Validation

**Status:** Automated and native acceptance complete; product-owner manual
checkpoint pending

**Date:** 2026-08-19

**Design:**
[EA0 ownership, identity, and transaction boundary](../design/ea0-ownership-identity-transaction-boundary.md)

## Acceptance Ledger

| Gate | Status | Evidence |
|---|---|---|
| Stable asset/target identity contracts | Complete | Validated nominal `AssetId`, `RunId`, `AuthoringTarget`, and digest tests in both full aggregates |
| Revisioned authoring transaction contract | Complete | Nonzero transaction/revision, source/scope, stale/invalid/scope rejection, and strict authored-change tests |
| Crate relocation vertical proof | Complete | Shared request metadata, typed outcome, exact undo/redo, save/restart, replay, and immutable editor-view coverage |
| Authored-change diagnostic envelope | Complete | Accepted/rejected correlation, typed crate values, compact diagnostics, JSON export, incident serialization, and per-transaction deduplication tests |
| Developer endpoint lifecycle/discovery contract | Complete | Validated immutable lifecycle/schema/discovery values; editor-enabled discovery is declared and editor-disabled discovery is disabled; no transport exists |
| Four-owner dependency enforcement | Complete | `EA0_OWNERSHIP_PASS owners=4 manifest=explicit tooling=backend_neutral runtime_content=cooked_only` plus four negative tests |
| Runtime cooked/source-content separation | Complete | EA0 source verifier, S15 cooking/catalog, installed content, headless manifest, and relocation gates pass |
| Editor enabled aggregate | Complete | 305/305 steps; 1022/1022 tests |
| Editor disabled aggregate | Complete | 302/302 steps; 1022/1022 tests |
| Headless product and linkage | Complete | Source, final-binary, logical-manifest, and linkage gates pass in both aggregates and `verify-s15` |
| Save, replay, and incident regression | Complete | S4 replay, S5 save, five-profile incident capture/inspect/replay, and replay cohort 19 pass |
| Native Metal regression | Complete | Installed crate-authoring, save, replay, S14 combat, S11/S13 cadence, and complete S15 Metal journeys pass |
| Architecture/dead-code/doc-drift audit | Complete | Explicit ownership manifest, backend-neutral views, no unused compatibility path, current cohort/docs, formatting, diff, and local-link audit pass |
| Product-owner manual checkpoint | Pending | Crate authoring and editor regression walkthrough |

## Implemented Evidence

### Executable ownership

- `tools/ea0_ownership_boundary.zig` is the single explicit manifest for the
  four owners. It checks dependency direction, rejects backend and mutable
  authority access from host-neutral tooling, and rejects source-asset access
  from runtime content.
- `zig build verify-ea0-ownership test-ea0-ownership --summary all` passed all
  6 steps and all 4 negative tests.
- The verifier exposed an existing transitive tooling leak: Camera and Stats
  panels borrowed the concrete camera and SDL-backed frame timer. The host now
  publishes immutable `CameraView` and `FrameTimingView` projections once per
  frame. The panels no longer hold those concrete owners.

### Identity, transaction, and crate vertical

- Engine-runtime contracts now provide validated path-independent asset
  identity, run identity, stable typed authoring targets, nonzero transaction
  and revision values, explicit source and scope, disposition/rejection
  metadata, durable identity/digest metadata, and authored-change correlation.
- Crate relocation remains feature-owned and typed. It carries the shared
  metadata through the existing tick-owned authority path without introducing
  arbitrary fields, reflection, or a generic mutation framework.
- Accepted, rejected, undo, and redo outcomes retain exact before, requested,
  and committed crate pose/velocity values with SHA-256 digests. Save and
  replay encode the source/scope contract and use replay cohort 19 without a
  compatibility reader.
- The editor panel exposes run, source, scope, transaction, expected and
  committed revisions, timing, disposition, typed rejection, and exact typed
  values. Compact diagnostics and automatic JSON export expose the same
  immutable evidence.
- Schema-5 incident timelines emit one `authored_change` record for each
  run/transaction pair, including stable identity, revisions, timing, outcome,
  typed crate values, and digests. The manifest and LLM handoff advertise the
  capability.

### Developer endpoint boundary

- Engine contracts define only immutable endpoint lifecycle, schema identity,
  bounded absolute discovery path, protocol cohort, and run identity.
- Editor-enabled runs declare discoverability; editor-disabled runs report the
  endpoint disabled. EA0 does not create a socket, transport, CLI, shell
  evaluator, remote control path, or multiplayer administration surface.

## Automated and Native Results

| Command | Result |
|---|---|
| `zig build verify-ea0-ownership test-ea0-ownership --summary all` | 6/6 steps; 4/4 tests; ownership pass |
| `zig build test -Deditor=true --summary all` | 305/305 steps; 1022/1022 tests |
| `zig build test -Deditor=false --summary all` | 302/302 steps; 1022/1022 tests |
| `zig build verify-s15 -Deditor=true --summary all` | 305/305 steps; 395/395 tests; full S15 automated/native gate |
| `zig build smoke-installed-s5-authoring-macos -Deditor=true` | Native Metal edit/undo/redo/save passed; revisions 1/2/3; 4 rendered and 1 hidden frame |
| `zig build smoke-installed-s5-save-macos -Deditor=true` | Native installed save/restart/restore passed |
| `zig build smoke-installed-s4-replay-macos -Deditor=true` | Native installed semantic replay passed with cohort 19 |
| `zig build verify-incident-hardening -Deditor=true` | All five installed Metal capture/inspect/replay profiles passed |
| `zig build smoke-installed-s14-macos -Deditor=true` | 240 Hz and 80 Hz native Metal handgun hit/kill/death-draw/replacement journeys passed |
| `zig build verify-mp2 -Deditor=true` | 49/49 steps; 3/3 tests; current four-district relevance/fault proof passed |
| `zig build smoke-installed-content` | 27/27 installed-content steps passed |
| `zig build verify-installed-validation` | 83/83 installed validation-product steps passed |
| `zig build verify-s11-dedicated` | Two graphical clients, real GNS, NPC damage/death/replacement passed |

The native authoring smoke reported
`S5_AUTHORING_SMOKE_RESULT rendered_frames=4 hidden_frames=1 edit_revision=1
undo_revision=2 redo_revision=3 save_status=committed ... gpu_driver=metal`.
The ranged-combat regression reported accepted hits, kill, death draw, and
replacement with `gpu_driver=metal` at both rates.

## Closeout Findings and Repairs

The complete regression matrix exposed stale validation assumptions rather
than EA0 gameplay failures. They were repaired on the current accepted S15
cohort:

1. Standalone S4/S5 tools assumed three static boxes per district while recipe
   8 declares two. They now derive body counts from the shared sandbox
   contract.
2. The incident journey treated hostile death and replacement as one timeout
   and waited inside every valid replacement safety window. The phases now
   have separate deadlines and move to a valid observation point after death.
3. S14 smoke selected one stable NPC but could credit an intervening actor's
   hit/kill. It now correlates the replicated target entity and generation.
4. The MP2 loopback expected a historical one-district peer view. It now checks
   the declared product relevance budget and current four-district population.
5. The S11 dedicated server used a legacy 1,400-tick lifetime and the attacker
   could lose the replacement target. It now uses the declared 4,800-tick
   scenario and pursues the nearest living NPC until the required death.
6. A cold, highly parallel S15 run exposed a session-authority test that spun
   only 32 ticks without yielding to the asynchronous authored-population
   bootstrap. It now uses the existing 256-tick fixture-settle window and
   yields between ticks. The focused suite passes 46/46 steps and 156/156
   tests; the repeated full S15 gate passes 305/305 with 395/395 tests.

Architecture review found no new actionable ownership violation after the
immutable Camera/Stats projection repair. Dead-code review found no compatibility
reader or superseded transaction path to retain. Documentation now names replay
cohort 19 and distinguishes EA0 candidate completion from product-owner
acceptance. No generic CVar, property bag, service locator, universal command
bus, scripting runtime, endpoint transport, or EA1 capability was introduced.

## Human Review Target

The manual checkpoint should verify only preserved behavior and the concrete
crate workflow:

1. launch the installed editor-enabled Metal product;
2. open Crate Authoring;
3. select the available crate;
4. change position and apply;
5. verify the crate moves once and continues normal physics;
6. undo and redo;
7. save, exit, relaunch through the supported restore workflow, and verify the
   committed state;
8. confirm ordinary play, rendering, input capture, and other editor panels
   behave as before.

No material, vehicle, lighting, map, endpoint, or scripting review belongs to
EA0.
