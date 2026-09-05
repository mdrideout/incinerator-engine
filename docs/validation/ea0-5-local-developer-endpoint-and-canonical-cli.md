# EA0.5 Local Developer Endpoint and Canonical CLI Validation

**Status:** Complete and accepted by the product owner on 2026-08-30

**Date:** 2026-08-30

**Program:**
[Editor Interaction and Agent Control Plan](../../EDITOR_INTERACTION_AND_AGENT_CONTROL_PLAN.md)

**Roadmap:**
[Engine Authoring Foundation](../design/engine-authoring-foundation.md)

**Decision:**
[ADR-029: Engine, Game, and Authoring Ownership Boundary](../adr/029-engine-game-authoring-boundary.md)

**Historical prerequisite:**
[EA0 validation ledger](ea0-ownership-identity-transaction-boundary.md)

## Acceptance Boundary

EA0.5 is the separately authorized schedule amendment that implements the
developer transport and canonical client deliberately excluded from EA0. EA0
defined and validated endpoint lifecycle, discovery, run identity, protocol
cohort, and schema identity values, but it created no socket or CLI. This phase
does not rewrite that historical boundary.

The implementation, machine-verifiable closeout, human usability walkthrough,
and product-owner stop review are complete. EA0.5 is accepted. On 2026-08-30
the product owner eliminated the planned MCP adapter and authorized Phase 7 to
make the canonical CLI and repository-owned agent skill first-class. At this
historical checkpoint EA1 had not started; the current EA1-A candidate is
recorded separately in
[its validation ledger](ea1-a-practical-textures-and-materials.md).

## Acceptance Ledger

| Gate | Status | Evidence |
|---|---|---|
| Schedule amendment and ownership | Complete | Product owner authorized EA0.5 ahead of EA1 on 2026-08-29; engine runtime owns generic endpoint identity/lifecycle values, while the concrete sandbox protocol, Unix transport, reusable client, and CLI are game-tooling adapters; the graphical composition owns producer-local correlation and existing editor, game-authoring, persistence, presentation, and incident owners retain policy |
| Endpoint lifecycle and discovery | Complete | Developer-only Unix-domain socket, absolute atomic discovery, run identity, protocol cohort, schema IDs/digest, explicit lifecycle/failure, owner-safe multi-run publication, validated crash-stale cleanup, and private local permissions are implemented and tested |
| Framed typed protocol | Complete | Protocol cohort 1 uses directionally bounded framed JSON and a manually registered schema catalog for query, editor control, authoring, persistence, and measurement; malformed frames and incompatible discovery/protocol values reject explicitly |
| Reusable client and canonical CLI | Complete | Installed `incinerator-dev` uses the same discovery, framing, schema IDs, and concrete request/response unions; grammar, client, real-socket integration, and installed live-product evidence cover every declared command |
| World/content distinction | Complete | `world list` exposes live stable world instances; `content list` returns only durable `AssetId` entries and is truthfully empty until EA1 creates them; the runtime crate is never reported as content |
| Selection and camera owner routing | Complete | CLI requests enter the graphical main-thread editor selection and viewport owners; no transport thread mutates ImGui, SDL capture, camera, or gameplay state directly |
| Revisioned crate authoring | Complete | Stable target, expected revision, owner admission, terminal transaction inspection, typed stale edit and stale history-lineage rejection, undo, and redo route through the existing crate authoring authority; per-producer result correlation is retained |
| Persistence | Complete | `save-world` admits through the existing persistence owner and `save result` reports a retained correlated result; installed S5 native write-and-separate-cold-verifier gates prove canonical restoration |
| Correlated frame evidence | Complete | `capture-frame` enters the existing incident screenshot path; the final installed run materialized 112 artifacts and `capture inspect` correlated the complete anomaly with authority tick 4431 and presentation frame 36907 |
| Editor-disabled/headless boundary | Complete | Server composition remains conditional on explicit editor/developer products; the CLI is a separate client product; the editor-off aggregate and installed editor-free cold verifier pass |
| Focused automated gates | Complete | Final `zig build`, endpoint, protocol/client/CLI/transport/integration, sandbox developer host, and EA0 ownership gates pass |
| Full aggregate/save/replay/incident gates | Complete for EA0.5 | Editor-on/off aggregates, installed native S5 authoring/save cold-verifier smokes, current-run incident inspection, and the aggregate replay/incident regressions pass |
| Installed native Metal endpoint journey | Complete | Final run `2026-08-30T03-35-14.391Z_solo_e03eb8dd` exercised discovery/query, selection, camera, authoring, stale edit/history rejection, undo/redo, complete frame capture, committed save, and clean endpoint retirement |
| LLM-agent workflow | Complete | The canonical installed CLI alone discovered the run, found a real target, inspected, selected, changed camera and crate state, observed terminal results, reverted/reapplied, captured evidence, saved, and verified shutdown without private process state |
| Human usability workflow | Complete | The product owner confirmed the CLI/editor workflow and the corrected Character/Free Camera, selection, gizmo, Escape, capture, and rendering behavior. The final finding—yellow selection bounds surviving a Free Camera→Character transition—was repaired by one shared editor-world-affordance projection that hides bounds, gizmo, and hit regions together while retaining semantic selection and inactive draft state |
| Architecture/security/dead-code/doc review | Complete | No material EA0.5 ownership, security, dead-code, or documentation blocker remains; transport lifecycle races and unbounded allocations found during review were repaired and regression-covered |
| Repository-wide macOS readiness | Inherited failure, outside EA0.5 | `test-macos-readiness` reaches S3 then fails `S3StreamingSmokeEvidenceMissing` because the historical S3 smoke still expects one resident scene/2,528 bytes while the accepted S15 product admits four scenes/10,112 bytes; focused and aggregate EA0.5 gates remain green |
| Product-owner checkpoint | Complete | The product owner accepted EA0.5 on 2026-08-30 after the final editor-affordance correction and validation |

## Implemented Surface

The implementation remains explicit and capability-specific:

- `src/engine/contracts/developer_endpoint.zig` owns stable endpoint lifecycle,
  schema, discovery, path, and run-identity values.
- `src/hosts/sandbox_developer_protocol.zig` owns the manually registered
  sandbox protocol, framed wire envelope, concrete request/response unions,
  schema descriptions, and deterministic schema digest.
- `src/adapters/transport/macos_developer_endpoint.zig` is the concrete
  sandbox-aware game-tooling transport adapter. It owns only the local
  Unix-domain socket, discovery publication, byte framing, and one outstanding
  request/response handoff; its directory name does not make it a
  protocol-neutral engine-tooling module.
- `src/hosts/developer_endpoint_client.zig` owns discovery validation and the
  reusable typed local client.
- `tools/incinerator_dev.zig` owns the canonical JSON CLI grammar.
- `src/main.zig` owns the graphical composition adapter: endpoint producer
  state, live world/content projection, request translation, and
  transaction/save/capture correlation. It pumps the editor-only server on the
  graphical main thread and routes requests through the existing selection,
  viewport, authoring, persistence, and incident-capture owners.
- `src/hosts/sandbox_developer_host.zig` remains the graphical diagnostics and
  incident owner. It exposes only the correlated-frame and authored-evidence
  seams consumed by the composition adapter.
- `src/hosts/incident_capture.zig` publishes endpoint discovery in the live
  manifest and materializes correlated developer frame evidence.
- `build.zig` installs `incinerator-dev` for editor-enabled builds and declares
  the focused protocol, client, CLI, transport, and integration gates.

The schema catalog has five concrete classes:

1. **Query:** describe endpoint, list schemas, list world instances, list
   durable content, and inspect a stable target.
2. **Editor control:** select or clear selection; inspect/set Character or Free
   Camera; set an exact free-camera pose; focus a stable target.
3. **Authoring:** relocate the persistent crate with an expected revision,
   inspect the correlated transaction, undo, and redo.
4. **Persistence:** request a world-snapshot save and inspect its correlated
   result.
5. **Measurement:** request a rendered frame through the incident capture
   owner and inspect its correlated result.

## Ownership and Security Review

The endpoint is local developer infrastructure, not a remote administration
service:

- the developer directory is mode `0700`; discovery and socket files are mode
  `0600`;
- discovery is atomically replaced and contains an absolute endpoint path;
- the transport thread owns socket bytes only, while the graphical main thread
  dispatches typed requests to the existing owners;
- request and response sizes, schema IDs, run identity, protocol cohort,
  transaction IDs, expected revisions, and correlation IDs are validated;
- request frames are limited to 4 KiB, response frames to 1 MiB, and discovery
  documents to 4 KiB. These limits are grounded in measured maxima of 501 B,
  736,957 B at the configured 1,091-world-entry capacity, and 609 B
  respectively; they reject invalid envelopes without changing any valid
  cohort-1 wire shape or its schema digest;
- a private advisory discovery lock serializes publication; an older process
  cannot overwrite a newer run, and startup removes only an exact canonical
  dead Unix-socket path nominated by a valid prior discovery document;
- no TCP listener, shell execution, filesystem browser, source-path identity,
  arbitrary object/property path, raw pointer, generic command bus, CVar
  registry, or multiplayer administration surface exists; and
- authoring, save, and capture replies report admission separately from
  terminal completion. The client must poll the transaction/save/capture result
  and then re-inspect state when applicable; selection and camera responses are
  synchronous.

## Automated Results

These commands pass on the final implementation:

| Command | Result |
|---|---|
| `zig build -Deditor=true -Dincident-capture=true -j1` | Pass; 79/79 steps; graphical product and installed CLI compile |
| `zig build test-developer-endpoint -Deditor=true -j1` | Pass; 65/65 steps and 35/35 tests across protocol, reusable client, CLI grammar, macOS transport lifecycle, real local-socket integration, and graphical-App dispatch |
| `zig build test-sandbox-developer-host test-editor-gizmo -Deditor=true` | Pass; 46/46 shared steps and 147/147 focused tests covering routing, draft/drop/cancel, mode/visibility cleanup, and stale hit-region removal |
| `zig build test -Deditor=true -j1` | Pass; 318/318 steps and 1,245/1,245 tests |
| `zig build test -Deditor=false -j1` | Pass; 313/313 steps and 1,105/1,107 tests, with the two endpoint-dependent cases skipped as designed |
| `zig build verify-ea0-ownership test-ea0-ownership -Deditor=true -j1` | Pass; 6/6 steps and 5/5 tests; EA0 four-owner dependency boundary and explicit adapter classification remain executable |
| `zig build smoke-installed-s5-authoring-macos -Deditor=true -j1` | Pass; 90/90 steps; native Metal edit/undo/redo revisions 1/2/3, committed save, and canonical editor-free cold restore |
| `zig build smoke-installed-s5-save-macos -Deditor=true -j1` | Pass; 85/85 steps; canonical active, waiting, and content-unloaded restart cases |
| `zig build inspect-incident -- <final-run>` | Pass; complete anomaly, 112 artifacts, zero artifact failures |
| `zig build test-mouse-capture-macos -Deditor=true` | Pass; native SDL Character/Free Camera, Escape, menu, selection-suppression, and explicit-quit routing |
| `zig build smoke-installed-s1-macos -Deditor=true` | Pass; 86/86 steps, 160/160 ready Metal frames, and clean ImGui/renderer teardown after the final interaction correction |

The ordinary graphical product treats `--save-root` as a write destination and
starts a fresh world on relaunch; graphical auto-restore is not part of EA0.5.
The installed S5 gates prove the accepted separate-process cold-verifier
architecture. The final live run did not enable accepted-ingress replay capture,
so its `replay/accepted-ingress.icrp` is intentionally absent; replay coverage
comes from the passing aggregate regressions rather than that frame-capture run.

## Final Installed Native Journey

The final journey used the freshly installed editor and CLI on the native Metal
renderer:

- run ID: `started_wall_unix_ms=1788060914264`,
  `nonce=1788060914264010000`;
- endpoint: `/tmp/incinerator-dev-18d077ed8f776d10.sock`, protocol cohort 1,
  five registered schemas, unchanged schema digest
  `10ed0950fdfb8ed3c5db346303867a8bc94e990fc942b824b5e9938421af6798`;
- world query: 16 live entries; `persistent-entity:1:1` was the authorable crate;
  durable content was correctly empty;
- camera: Character inspection, switch to Free Camera, exact pose, and stable
  target focus all round-tripped through the viewport owner;
- authoring: transaction 1 moved the crate at revision 0→1; transaction 2
  rejected stale revision 0; stale undo was rejected before allocating a
  transaction; transaction 3 undid revision 1→2; transaction 4 redid 2→3;
- capture: capture 1 completed at authority tick 4431 / presentation frame
  36907 in
  `/Users/matt/Library/Logs/Incinerator/runs/2026-08-30T03-35-14.391Z_solo_e03eb8dd/anomalies/anomaly-0001`;
- save: request 1 committed `sandbox` with `atomic replace and sync complete`;
  `/tmp/incinerator-ea05-final.jsjUL8/sandbox.isav` is mode `0600` and 21,220
  bytes; and
- shutdown: discovery retained the exact stopped run identity, removed its
  endpoint path and schema digest, and the socket file was gone.

## Native and Human/Agent Checklist

Build and start the installed editor with an existing absolute save root:

```sh
mkdir -p /tmp/incinerator-ea05-saves
zig build -Deditor=true -Dincident-capture=true
./zig-out/bin/incinerator_engine --save-root=/tmp/incinerator-ea05-saves
```

From a second terminal:

1. Run `./zig-out/bin/incinerator-dev discovery`, `describe`, and `schema list`.
   Confirm the discovery document is available, identifies the current run,
   and advertises the same cohort and schema digest as `describe`.
2. Run `world list` and `content list`. Confirm the crate appears only in the
   world response, durable content is empty, and a real target string can be
   copied from the world result instead of guessed.
3. Inspect that target and record its authoring revision. Select it from the
   CLI and confirm the Outliner, Inspector, viewport highlight, and gizmo show
   the same selection.
4. Inspect camera state, change to Free Camera, set a repeatable pose or focus
   the crate, and confirm character input/mouse capture does not continue to
   own the viewport.
5. Submit `crate set-position` with the observed revision. Treat the first
   response as admission only; poll `transaction inspect`, re-inspect the
   crate, and confirm the terminal result, new position, and revision agree
   with ImGui and authored-change diagnostics.
6. Resubmit with the stale revision. Confirm both CLI and UI expose the same
   typed stale-revision rejection and the accepted position remains unchanged.
7. Undo and redo using the current revision, polling and re-inspecting after
   each transaction. Confirm each producer receives only its own correlated
   result.
8. Request a frame, poll `capture inspect`, and open the returned artifact.
   Confirm it belongs to the current run/anomaly directory and reports the
   tick/frame that produced the visible evidence.
9. Request `save-world` and poll `save result` to a terminal disposition. A
   committed result proves that the graphical producer wrote the fixed durable
   slot. The accepted S5 restore architecture uses a separate fresh
   SDL/editor/GPU-free verifier with matching world/content expectations; do
   not claim that this EA0.5 ordinary-product slot was cold-verified unless such
   a compatible verifier actually consumes it.
10. Stop the product and verify discovery reports a stopped/unavailable run;
    the client must not attach to a stale socket. An ordinary graphical relaunch
    with the same `--save-root` starts a fresh world and new endpoint run rather
    than loading the committed slot. Repeat discovery with an explicit absolute
    `--discovery` path.
11. Confirm normal Character play, Free Camera navigation, gizmo capture,
    Escape routing, rendering, incident capture, and save behavior remain
    unchanged throughout the workflow. A CLI or UI mode change to Character
    must retain semantic selection/Inspector state while hiding the yellow
    bounds, gizmo, and hit claims; returning to Free Camera must reproject them
    without a new transaction.

## Product-Owner Acceptance

The product owner completed the human checkpoint and accepted EA0.5 on
2026-08-30. Human review found one final composition error: after selecting the
crate in Free Camera and switching to Character, the renderer retained the
yellow selection bounds after the ImGui gizmo disappeared. The repair did not
clear semantic selection or the Inspector draft. Instead, one explicit
editor-visible/Free-Camera policy now controls renderer bounds, ImGui handles,
and synchronous handle claims together. Mode change, editor hiding, focus
loss, and minimization also end active capture and discard stale projected hit
regions. Returning to Free Camera reprojects current state without allocating
a selection or authoring transaction.

The final corrected tree passed the focused, editor-enabled, editor-disabled,
validation, native SDL, and installed Metal gates recorded above. The inherited
pre-S15 `test-macos-readiness` expectation remains outside EA0.5 and does not
change this acceptance.

## Phase 7 Boundary

EA0.5 acceptance removed Phase 7's prerequisite blocker. The product owner then
made a separate 2026-08-30 decision: local coding agents always have shell
access, so MCP adds no required capability and is eliminated. Phase 7 extends
the accepted `incinerator-dev` product with a machine-readable operation
catalog, explicit terminal/next guidance, and a repository-owned skill. It adds
no endpoint command, second protocol, or second mutation authority.
