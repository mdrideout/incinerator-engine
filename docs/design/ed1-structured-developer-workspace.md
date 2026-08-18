# ED1 Structured Developer Workspace

**Status:** Implemented and accepted; see the
[validation record](../validation/ed1-structured-developer-workspace.md)

**Recorded:** 2026-08-17

**Platform:** Apple Silicon macOS

**UI stack:** Dear ImGui through zgui and the engine-owned SDL3 GPU backend

**Roadmap:** [`OVERHAUL_PLAN.md`](../../OVERHAUL_PLAN.md)

**Governing decision:**
[ADR-003: Editor Architecture and Tool System](../adr/003-editor-architecture.md)

**Active product direction:** Deterministic rendering

**Paused adjacent work:**
[Neural Rendering Product-Track Pause](neural-rendering-pause.md)

## Decision

ED1 replaces the current collection of independently positioned overlay
windows with one structured developer workspace. Dear ImGui remains the right
tool for this engine: it is already integrated with SDL3 GPU/Metal, is a mature
game-development debug UI, supports docking, and preserves the compile-time
editor exclusion and immediate-mode inspection model that the engine needs.

The problem is composition, not the UI library. The editor needs one owned
workspace shell, one descriptive panel registry, deliberate layout presets,
and a visible time identity shared with incident evidence. ED1 does not build a
custom retained-mode UI toolkit, turn the editor into gameplay authority, or
move the game renderer into an editor-owned scene graph.

ED1 is the immediate implementation phase before DR1. It makes the existing
diagnostics, incident capture, navigation, population, authoring, and rendering
controls legible enough for human and LLM-guided visual acceptance of later
product slices.

## Product problem

The current tool-first boundary is sound, but its presentation has degraded as
the tool count grew:

- every tool opens a separate top-level window and chooses its own initial
  position and size;
- important panels overlap the product view and one another;
- there is no stable left/right/bottom workspace convention;
- panel names are visible, but their purpose, source data, mutation boundary,
  and example values are not described in one place;
- startup cannot request a known diagnostic layout or exact open/focused panel
  set;
- screenshots do not carry a single persistent wall-clock/tick/frame readout
  that can be aligned directly with incident NDJSON; and
- layout behavior is stored implicitly in ImGui state instead of being
  addressable by stable engine-owned identities.

This makes the UI harder for a human to learn and harder for a fresh LLM agent
to configure before reproducing or screenshotting an anomaly.

## Ownership and separation of concerns

### Editor workspace owner

The visual developer host continues to own one `Editor` value. ED1 adds only
workspace presentation state:

- active layout preset;
- open/closed state for each statically registered panel;
- requested focused panel;
- one-time docking layout application; and
- visibility of the workspace guide and ImGui demo.

The workspace does not retain `App`, `Simulation`, ECS entities, Jolt handles,
renderer resources, or incident writers. Tools still receive one-frame
immutable projections and fixed typed request buffers.

### Panel registry

Every panel publishes immutable metadata under a stable `ToolId`:

- display name and category;
- default dock region;
- one-sentence purpose;
- the source data it reads;
- whether it can emit typed requests;
- representative data examples; and
- the audit identity fields relevant to the panel.

This is executable metadata, not a parallel prose list. The Panels menu,
workspace guide, startup parser, layout presets, and registry tests all consume
the same descriptors.

### Startup configuration

LLM and scripted visual-debug sessions use explicit command-line options:

```text
--editor-layout=<gameplay|navigation|population|rendering|incident|minimal|all>
--editor-panels=<tool-id,tool-id,...>
--editor-focus=<tool-id>
--editor-guide
```

`--editor-layout` selects a deterministic open-panel cohort and dock
arrangement. `--editor-panels` replaces that cohort with an exact set.
`--editor-focus` selects the visible tab to bring forward after docking.
`--editor-guide` opens the registry documentation beside live data. Tool IDs
are stable snake-case names shown in the guide and startup errors reject
unknown names. These options alter developer presentation only.

The default interactive layout is `gameplay`. ImGui may continue to persist
human drag/resize preferences during ordinary use, while an explicit startup
layout always reapplies its declared arrangement so automated screenshots do
not depend on a previous run's local `.ini` state.

### Time identity

The workspace status bar shows, on every visible editor frame:

- UTC wall time with milliseconds;
- `wall_unix_ms`;
- authority tick;
- presentation frame; and
- the active layout preset.

`wall_unix_ms`, tick, and frame use the same meanings as incident evidence.
This is correlation identity, not a new telemetry stream and not simulation
time authority.

## Workspace composition

The main SDL window remains the only platform window. ED1 enables ImGui docking
but not multi-viewport platform windows.

```text
┌ Main menu: Workspace · Panels · View · Help ───────────────────────┐
│ left dock              central product view       right dock      │
│ gameplay/navigation    passthrough scene          render/details  │
│ population selection                              authoring       │
├ bottom dock: diagnostics · stats · incident capture ─────────────┤
│ UTC | wall_unix_ms | tick | frame | layout                         │
└────────────────────────────────────────────────────────────────────┘
```

The central dock node is passthrough: the existing deterministic product scene
remains rendered by the product renderer and visible in the uncovered center.
ED1 deliberately does not introduce an offscreen editor viewport texture or
change camera projection ownership. If DR1 later demonstrates that a true
editor-owned scene viewport is necessary, it receives a separate bounded plan.

Default regions are conventions, not new subsystem boundaries:

- **left:** gameplay, navigation, and population inspection;
- **right:** camera, rendering, physics visualization, interaction, and
  authoring detail;
- **bottom:** statistics, diagnostics, and incident capture;
- **guide:** panel metadata and launch examples; and
- **paused:** neural-rendering UI remains retained but closed and is not
  included in deterministic presets while the product track is paused.

The product HUD and short incident-capture status remain intentionally visible
product feedback. They are not general editor windows and are not converted
into authority or a second workspace.

## Dependency cohort

ED1 upgrades only dependencies on its critical path, as one tested cohort:

- SDL wrapper `0.5.2+3.4.12` → `0.5.3+3.4.14` at the exact
  `castholm/SDL` release commit;
- zgui from the 2026-05-12 Zig 0.16 commit to the exact current 2026-08-07
  Zig 0.16 `main` commit; and
- the engine-owned zgui SDL3 GPU adapter continues compiling against the same
  selected SDL headers as the renderer.

Both candidates declare Zig 0.16 support. ED1 does not upgrade Jolt, Flecs,
GameNetworkingSockets, math, mesh, or image wrappers without a demonstrated
compatibility need. Exact pins remain mandatory.

Upstream references:

- [SDL 3.4.14](https://github.com/libsdl-org/SDL/releases/tag/release-3.4.14)
- [castholm/SDL v0.5.3+3.4.14](https://github.com/castholm/SDL/releases/tag/v0.5.3%2B3.4.14)
- [zig-gamedev/zgui](https://github.com/zig-gamedev/zgui)

## Implementation phases

### ED1-A — Persist the workspace contract

- Record this plan and make it the immediate roadmap phase.
- Amend ADR-003 with the accepted docking, metadata, startup, and timestamp
  decisions.
- Keep DR1 as the next deterministic-rendering product slice after ED1.

Exit: the why, ownership, sequence, and non-goals exist before code changes.

### ED1-B — Structured registry and workspace shell

- Extend tool descriptors with stable command names, category, region,
  purpose, data-source/request-boundary text, examples, and audit fields.
- Enable ImGui docking without enabling platform multi-viewports.
- Add one full-work-area shell with central scene passthrough and a persistent
  bottom status bar.
- Remove tool-owned initial-position policy; the workspace owns placement.
- Build deterministic gameplay, navigation, population, rendering, incident,
  minimal, and all-deterministic layouts through the existing zgui docking
  API.

Exit: panels no longer form an accidental pile of overlay boxes and registry
tests prove every `ToolId` has complete metadata exactly once.

### ED1-C — LLM-addressable startup and panel guide

- Parse the four editor startup options independently from product mode.
- Apply exact panel masks and focus only after validating stable tool IDs.
- Render a searchable/scannable workspace guide from registry metadata,
  including example launch commands and representative data values.
- Show command IDs in the Panels menu and use descriptions as hover help.

Exit: a fresh agent can choose a layout and visible live-data tabs before
launch without editing code or inheriting local ImGui state.

### ED1-D — Audit-aligned time and screenshot readability

- Add the UTC/`wall_unix_ms`/tick/frame/layout status line.
- Use one immutable per-frame timestamp value across the workspace draw.
- Keep time acquisition in the developer host; tools do not call platform
  clocks independently.
- Verify the readout remains visible in editor-inclusive screenshots and uses
  the incident schema's names and units.

Exit: a screenshot can be correlated directly with incident files and live
panel values.

### ED1-E — Tested dependency upgrade

- Update the exact SDL and zgui pins.
- Rebuild the engine-owned zgui SDL3 GPU adapter against SDL 3.4.14.
- Resolve source/API changes without adding fallback code for the old cohort.
- Update README, ADR-003, manifest evidence, and any exact-version incident
  metadata together.

Exit: one exact Zig 0.16/SDL/zgui cohort passes editor-enabled and
editor-disabled builds.

### ED1-F — Native acceptance and cleanup

- Add pure tests for descriptor completeness, IDs, presets, parser behavior,
  exact panel overrides, focus validation, and timestamp formatting.
- Run focused editor/invocation tests, the aggregate editor suite, the
  editor-disabled suite, install/package verification, and cold headless
  reachability checks.
- Launch the native Metal product under at least gameplay, navigation,
  incident, and exact-panel configurations; verify docking, focus, input
  capture, hide/show, resize, and scene passthrough.
- Capture an editor-inclusive incident screenshot and confirm its displayed
  wall/tick/frame identity can be located in the incident records.
- Remove superseded per-tool placement code and update the roadmap and
  validation ledger.

Exit: ED1 is accepted with one clear workspace owner, no gameplay-authority
regression, and no old layout compatibility path.

## Acceptance criteria

- The default editor opens as one recognizable workspace with stable left,
  right, bottom, and central regions.
- The central deterministic scene remains playable and visible; panels do not
  silently change simulation, camera, collision, or rendering authority.
- Every registered panel has a unique stable command ID, complete description,
  source/request metadata, examples, audit fields, category, and default
  region.
- Every documented preset produces a deterministic panel cohort and layout.
- Exact `--editor-panels` and `--editor-focus` startup requests are validated
  and applied; unknown values fail with specific errors.
- The workspace guide is generated from the same registry used for dispatch
  and startup parsing.
- UTC, `wall_unix_ms`, authority tick, and presentation frame remain visible
  and use incident-compatible meanings.
- Editor input capture, F1 visibility, F2 demo, F3 passthrough, incident
  shortcuts, and normal gameplay controls remain correct.
- SDL 3.4.14 and the selected current zgui commit form one exact tested cohort.
- Editor-disabled and cold headless products do not link ImGui, editor, SDL GPU
  UI code, or the workspace shell.
- No neural-rendering implementation, UI expansion, capture, training,
  inference, or promotion is introduced.

## Explicit non-goals

- replacing Dear ImGui with Qt, SwiftUI, web UI, RmlUi, or a custom toolkit;
- ImGui multi-viewport platform windows;
- an editor-owned offscreen game viewport or scene graph;
- a generic window manager, reflection system, plugin loader, or runtime tool
  discovery;
- direct ECS/Jolt mutation, raw authority handles, or editor-only gameplay
  semantics;
- remote browser dashboards, streaming telemetry services, or LLM API calls;
- changing incident storage schemas solely for workspace layout;
- resuming or expanding neural rendering; or
- Windows, Linux, or SteamOS editor abstraction and testing.

## Validation record

Implementation creates
`docs/validation/ed1-structured-developer-workspace.md` and records:

- exact dependency pins and migration notes;
- registry/preset/startup parser evidence;
- editor-enabled, editor-disabled, install, package, and headless results;
- native Metal layout screenshots stored outside incident run folders;
- one incident correlation example using wall time, tick, and frame; and
- an automated-versus-human acceptance table.
