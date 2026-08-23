# ED1 Structured Developer Workspace Validation

**Status:** Implementation and automated/native acceptance complete

**Recorded:** 2026-08-17

**Plan:**
[ED1 Structured Developer Workspace](../design/ed1-structured-developer-workspace.md)

**Decision:**
[ADR-003: Editor Architecture and Tool System](../adr/003-editor-architecture.md)

**Platform:** Apple Silicon macOS / Metal

## Result

ED1 replaces per-tool initial placement with one editor-owned dockspace while
preserving the existing immutable frame projections and bounded typed request
buffers. The central product scene remains renderer-owned and visible through
the passthrough dock node. The left, right, and bottom regions organize twelve
statically registered panels; the paused neural panel remains registered for
retained evidence but is excluded from every deterministic preset.

A 2026-08-22 post-acceptance usability correction retained the same ownership
model while adding a thirteenth bottom-region `event_log` panel. It also moved
the formerly floating product/incident readouts into one reserved responsive
top strip and restored the stable native window title.

The same executable registry now supplies stable panel IDs, categories,
default regions, purpose, read boundary, request boundary, examples, and audit
fields to panel dispatch, startup parsing, the Panels menu, the Workspace
Guide, and completeness tests. No runtime discovery, reflection layer,
gameplay-authority path, platform multi-viewport, or editor-owned scene
viewport was introduced.

## Phase ledger

| Phase | Status | Evidence |
|---|---|---|
| ED1-A — persistent contract | Accepted | Plan, amended ADR-003, roadmap entry |
| ED1-B — registry and workspace shell | Accepted | Static descriptors, dock builder, central passthrough, registry tests |
| ED1-C — LLM-addressable startup and guide | Accepted | Preset/exact-panel/focus parser, generated guide, native launches |
| ED1-D — audit-aligned time | Accepted | One host-acquired wall timestamp and visible UTC/wall/tick/frame status bar |
| ED1-E — dependency cohort | Accepted | Exact SDL 3.4.14 and zgui pins; editor-on/off aggregate gates |
| ED1-F — native acceptance and cleanup | Accepted | Four Metal layout launches, incident-inclusive capture review, full regression matrix |

## Exact dependency cohort

| Component | Before | ED1 pin |
|---|---|---|
| Zig | `0.16.0` | `0.16.0` exact |
| SDL wrapper / SDL | `0.5.2+3.4.12` | `0.5.3+3.4.14`, commit `fb2d799c4778832a34ccb3739e40dded700684bd` |
| zgui | 2026-05-12 development commit | commit `0b468ccdc30d85f7fe72308791f2583344b62103` |
| Jolt / JoltC | `5.5.0` | unchanged |

The engine still selects zgui with no upstream backend and compiles its owned
SDL3 GPU adapter against the same SDL 3.4.14 headers as the renderer. The
upgrade required no old-cohort fallback or dual integration path. Incident
manifests now record SDL `3.4.14`; the accepted replay/protocol/snapshot and
content cohorts did not change.

## Registry and startup contract

At ED1 acceptance the renderer-neutral `src/editor/workspace.zig` owned twelve
`ToolId` values. The later `event_log` split brings the current registry to
thirteen while preserving the same seven task presets, exact panel masks,
focus validation, and incident-compatible UTC formatting. Unknown
layouts/panels, duplicate options/panels, empty panel
sets, and focus on a closed panel fail explicitly. Product and validation mode
parsers recognize editor options but delegate their meaning to this separate
owner, so developer presentation cannot select a product mode.

Supported startup controls:

```text
--editor-layout=<gameplay|navigation|population|rendering|incident|minimal|all>
--editor-panels=<tool-id,tool-id,...>
--editor-focus=<tool-id>
--editor-guide
```

An exact panel cohort without an explicit focus does not retain an unrelated
preset focus. Selecting a preset interactively restores its declared cohort
and focus. The `all` preset deliberately means all active deterministic tools,
not the paused neural panel.

## Automated evidence

Focused contract gate:

```sh
zig build test-editor-workspace test-sandbox-invocation -Deditor=true --summary all
```

Result: `7/7` steps and `7/7` focused tests passed before the final aggregate;
the editor implementation also includes registry uniqueness/completeness,
instance ownership, exact visibility/focus, no-stale-focus, and shortcut
routing tests.

Full editor-enabled gate:

```sh
zig build test -Deditor=true -j1 --summary all
```

Result: `288/288` steps and `991/991` tests passed, including build, install,
validation-boundary, content, replay, architecture, source-package, and native
linkage gates.

Full editor-disabled gate:

```sh
zig build test -Deditor=false -j1 --summary all
```

Result: `285/285` steps and `991/991` tests passed. The installed product
reported `editor: false`; headless source/final-binary boundaries and product /
validation separation passed.

## Native Metal evidence

The installed validation product launched and shut down cleanly under four
startup configurations:

1. gameplay preset focused on `gameplay_inspector`;
2. navigation preset focused on `navigation_lab` with the guide open;
3. incident preset focused on `incident_capture`; and
4. exact `diagnostics,incident_capture` panels focused on `diagnostics`.

Each run presented 120/120 frames at the requested virtual 120 Hz, reported
zero unavailable swapchain frames, advanced 64 fixed ticks, used the Metal
driver, and completed clean teardown.

A full installed incident journey launched with:

```sh
zig build run -- --incident-journey-window \
  --editor-layout=incident \
  --editor-focus=incident_capture \
  --editor-guide
```

It completed 2,088 simulation ticks and 9,907 frames with vehicle, district,
player, NPC, and resize journey checks satisfied. The preserved run is:

```text
/Users/matt/Library/Logs/Incinerator/runs/2026-08-17T23-18-43.628Z_solo_a05e32a6
```

The run is valid but partial because the scripted journey submitted four flags
faster than the late visual queue could retain every requested image. It is
used here only as graphical workspace/correlation evidence, not as a claim of
healthy incident-recorder capacity. It has zero dropped typed records, zero
writer failures, zero suspicious retained images, and a semantically matching
2,028-tick accepted-ingress replay.

The editor-inclusive human frame indexed at presentation frame `903` and
authority tick `65` visibly contains:

- the incident preset's left Gameplay Inspector;
- the right Workspace Guide generated from registry metadata;
- bottom Stats, Diagnostics, and Incident Capture tabs;
- the unobscured product scene in the passthrough center; and
- the persistent UTC / `wall_unix_ms` / tick / frame / layout status line.

The index captures that frame at monotonic time `3983191263607416`; the flag
marker provides wall time `1787008725597` at
`3983192181382416`, placing the image 917 ms before the flag. The visible
status identity and the indexed tick/frame therefore align with the same
incident evidence vocabulary.

## Acceptance split

| Concern | Automated or agent-reviewed result | Product-owner check |
|---|---|---|
| Registry completeness and unique IDs | Passed | None required |
| Presets, exact panels, focus, and parser failures | Passed | None required |
| Docked composition and central scene passthrough | Metal capture reviewed | Optional preference pass |
| UTC/wall/tick/frame screenshot identity | Metal capture and index correlated | Optional legibility preference |
| F1/F2 and ImGui capture routing | Existing event/capture regressions passed | Physical-key confirmation optional |
| Resize and renderer lifecycle | Installed incident journey passed | None required |
| Editor-disabled/headless isolation | Passed | None required |
| Panel drag, resize, and saved human arrangement | ImGui-owned behavior retained | Product owner may tune locally |

The product owner's next normal run is a usability preference pass rather than
an unresolved ownership or correctness gate. Any unreadable panel width,
undesired preset composition, or shortcut issue should be flagged through the
existing incident workflow and can be adjusted without reopening ED1's
architecture.

Phase 3 of the later Editor Interaction and Agent Control program supersedes
ED1's former `F3` input-passthrough shortcut with explicit Character/Free
Camera viewport modes. ED1's accepted docking and compile-time editor boundary
remain unchanged.

## Deferred by design

- custom retained UI frameworks and web dashboards;
- ImGui platform multi-viewports;
- an editor-owned offscreen scene viewport;
- runtime panel discovery or a plugin manager;
- secondary-platform editor work; and
- any neural-rendering continuation, capture, training, inference, or
  promotion.
