# Editor Interaction and Agent Control Plan

**Status:** Phases 1-7 accepted; the Phase 8 / EA1-A read-only Content Browser
and agent-discovery slice is an implementation/machine acceptance candidate
with product-owner review pending; EA1-B mutation workflows remain gated

**Date:** 2026-08-23

**Platform:** Apple Silicon macOS only

**Depends on:**

- [ADR-029: Engine, Game, and Authoring Ownership Boundary](docs/adr/029-engine-game-authoring-boundary.md)
- [Engine Authoring Foundation](docs/design/engine-authoring-foundation.md)
- [EA0 Ownership, Identity, and Transaction Boundary](docs/design/ea0-ownership-identity-transaction-boundary.md)
- [ED1 Structured Developer Workspace](docs/design/ed1-structured-developer-workspace.md)
- [S14 Ranged Combat](docs/design/s14-ranged-combat.md)

**Related validation:**

- [EA0 validation ledger](docs/validation/ea0-ownership-identity-transaction-boundary.md)
- [EA0.5 validation ledger](docs/validation/ea0-5-local-developer-endpoint-and-canonical-cli.md)
- [Phase 7 CLI agent-contract validation](docs/validation/editor-interaction-phase-7-cli-agent-contract.md)
- [ED1 validation ledger](docs/validation/ed1-structured-developer-workspace.md)
- [S14 validation ledger](docs/validation/s14-ranged-combat.md)

---

## 1. Outcome

Turn the current developer workspace and crate relocation proof into a clear,
conventional editor interaction workflow without creating a generic scene
framework or property system.

The completed program must let a human:

1. Find panels predictably.
2. Play as the character with deliberate mouse capture.
3. Switch to an independent free editor camera without continuing to drive the
   character.
4. Select a live world object either in the viewport or an outliner and see the
   same unmistakable selection in both places.
5. Inspect and relocate the test crate using exploratory controls and exact
   numeric entry through the existing revisioned authoring authority.
6. Understand the difference between a runtime world instance, a reusable
   content asset, a live session edit, and a saved world snapshot.

The completed program must also let a local LLM agent:

1. Discover the running editor and its available typed schemas.
2. List real content assets separately from live world instances.
3. Inspect stable identities and current revisions.
4. Select an object, change the free camera, and relocate the crate through the
   same owner requests used by ImGui.
5. Poll the correlated result, inspect the resulting state, capture a rendered
   frame, revert the change, and save the world snapshot when requested.

The program is divided into sequential phases with a review after every phase.
No phase begins until the preceding phase passes its architecture, dead-code,
documentation-drift, automated, native Metal, and human review gates.

---

## 2. Planning Baseline and Findings

### 2.1 Panels

At plan creation, the Panels menu was rendered in tool-registry order. That
order is useful to the
workspace because it also participates in default docking and tab behavior, but
it is not alphabetical and is harder for a human to scan.

The menu presentation should be sorted independently. The stable `ToolId`
values, tool registry, layout masks, default focus, and dock construction order
must not change merely to alphabetize one menu.

### 2.2 Ranged combat

At plan creation, the authoritative handgun admitted the last shot, left the
magazine at zero, and required a later explicit reload action. Input and
presentation correctly did not own that rule.

Automatic empty-magazine reload must therefore be a deterministic ranged-combat
state transition shared by solo, listen, and dedicated placements. It must not
be a HUD refill, a synthetic keyboard event, or client-only convenience.

For this plan, **never empty** means:

- when the final round is admitted and reserve ammunition remains, the weapon
  immediately enters its normal timed reload state;
- the HUD may truthfully display zero magazine rounds during that timed reload;
- the player is never left equipped, idle, and waiting for a manual reload; and
- when both magazine and reserve are zero, the weapon remains genuinely empty.

Infinite ammunition or an instantaneous refill is not part of this plan.

### 2.3 Camera and input

The current product has a character-follow camera and a gameplay-relative mouse
lock. Releasing the lock makes the cursor available, but it does not create an
independent editor camera. The product camera continues to follow the controlled
character or vehicle every presentation frame.

The missing concept is an explicit editor viewport mode. Mouse capture state is
an implementation detail within Character mode, not the mode itself.

Viewport mode also must remain independent of simulation state:

| Concern | Values | Owner | Effect |
|---|---|---|---|
| Viewport interaction | `character`, `free_camera` | Engine tooling/visual host | Camera and input routing |
| Gameplay mouse lock | captured, released | SDL input adapter | Relative mouse ownership |
| Simulation state | running, paused | Game authority/host | Fixed-tick advancement |
| Event recording | recording, frozen | Diagnostics | Trace collection only |

Switching to Free Camera does not pause gameplay. Freezing the casual gameplay
trace does not pause gameplay either. A true gameplay pause remains a separate
future product decision unless explicitly added to this program.

### 2.4 Crate, world instances, and assets

The current crate is one persistent runtime physics test object. It has a stable
`PersistentId`, live physics state, an authoring revision, and a typed relocation
transaction. It is not an imported model, a reusable source definition, or a
cooked `AssetId`.

A conventional editor separates three surfaces:

1. **Content Browser** — reusable imported/authored definitions such as scenes,
   meshes, materials, textures, and later archetypes.
2. **World Outliner** — instances currently present in the loaded world.
3. **Inspector/Details** — typed properties and operations for the current
   selection.

The viewport and World Outliner share one editor selection. Selection causes a
visible highlight and the Inspector shows the applicable owner-written fields.
This structure is consistent with the official editor layouts and selection
workflows documented by
[Unreal Engine](https://dev.epicgames.com/documentation/en-us/unreal-engine/unreal-engine-interface),
[Unity](https://docs.unity3d.com/Manual/SceneViewNavigation.html), and
[Godot](https://docs.godotengine.org/en/stable/getting_started/introduction/first_look_at_the_editor.html).

The engine is currently missing the shared selection projection, viewport
picking, selection highlight, World Outliner, selection-driven inspector, and
free-camera transform workflow needed to provide that structure.

### 2.5 Agent control

EA0 defines and validates the lifecycle/discovery contract for a future local
developer endpoint. It deliberately did not create a socket, transport, CLI,
agent skill, shell evaluator, or remote service. At this plan's creation, the
accepted roadmap deferred endpoint transport and the canonical
`incinerator-dev` client until EA2.

Moving local agent control before EA1 was therefore accepted as an explicit
schedule change, not an unnoticed extension of EA0. On 2026-08-29 the product
owner authorized **EA0.5 — Local Developer Control** after the human editor
interaction foundation was accepted.

---

## 3. Ownership and Architecture Rules

| Capability | Primary owner | Allowed behavior | Forbidden shortcut |
|---|---|---|---|
| Panel menu ordering | Engine tooling | Sort visible descriptors | Reorder stable IDs or docking to sort one menu |
| Automatic reload | Game/runtime ranged-combat feature | Deterministic authority state transition | HUD refill or client-generated fake input |
| Viewport mode | Engine tooling composed by visual host | Route editor versus character input | Store editor camera in gameplay authority |
| Mouse lock | SDL input adapter | Capture/release the product window | Let ImGui or game code call SDL through a tool panel |
| Selection transport | Engine tooling | Carry stable, explicit selection variants | Generic `any` object or raw pointer selection |
| Viewport picking | Visual host/tooling adapter | Pick immutable selectable bounds | Direct tool access to Jolt or Flecs |
| Crate inspection | Game tooling | Render crate-specific values and requests | Reflection-driven property panel |
| Crate relocation | Game/runtime authoring owner | Validate and apply typed revisioned transaction | Direct pose/body mutation from ImGui |
| Asset browsing | Engine tooling plus game content descriptions | Query stable content identities | Treat runtime entities or source paths as assets |
| Developer endpoint | Engine-runtime lifecycle contract plus game-tooling adapter | Local typed sandbox schema transport | Remote control or second state owner |
| CLI agent contract | Developer-only game-tooling client plus repository-owned skill | Describe and submit the same registered owner requests through the typed client | MCP, shell evaluation, raw memory, generic command strings, duplicated command manuals |

The following ADR-029 constraints remain mandatory throughout every phase:

- no generic CVar registry;
- no property bag;
- no reflection-driven ECS editing;
- no universal command bus;
- no service locator;
- no arbitrary code console;
- no direct ImGui or CLI access to Flecs, Jolt, SDL, renderer resources,
  storage internals, or the filesystem; and
- no silent promotion from preview to session authority or durable content.

---

## 4. Target Human Workflow

### 4.1 Character mode

The top viewport toolbar exposes a selected `Character` mode.

- The camera follows the controlled character or occupied vehicle.
- Clicking the scene viewport acquires relative gameplay mouse lock.
- The acquisition click is consumed as a mode transition and never fires the
  handgun.
- Once captured, mouse motion controls character camera look and left click
  fires when the handgun is equipped.
- `Esc` releases mouse lock but leaves Character mode selected.
- Losing focus, minimizing, closing, or switching to Free Camera also releases
  mouse lock and clears held gameplay input.

The contextual toolbar guide reads approximately:

```text
Character · click viewport to capture · Esc releases · 1 handgun · LMB fire · R tactical reload
```

### 4.2 Free Camera mode

Selecting `Free Camera` is an immediate editor interaction transition.

- Gameplay-relative mouse lock is released.
- Latched character/vehicle actions are cleared.
- The camera stops following the controlled entity.
- The cursor remains available for ImGui and viewport selection.
- Left click selects the nearest selectable object under the cursor.
- Clicking empty viewport space clears selection.
- RMB drag plus WASD moves and looks through the scene.
- Q/E moves vertically, Shift accelerates, and the wheel adjusts camera speed.
- `F` frames the selected object.
- Gameplay actions such as fire, melee, collect/drop, enter/exit, jump, brake,
  and vehicle steering are suppressed.

The contextual toolbar guide reads approximately:

```text
Free Camera · RMB+WASD fly · Q/E vertical · Shift fast · wheel speed · LMB select · F frame
```

Free-camera position, yaw, pitch, speed, and last focus target are editor-local
presentation state. They do not enter authority snapshots, replication, world
saves, or replay. Switching back to Character resumes normal character/vehicle
follow. Returning to Free Camera restores the previous free-camera pose unless
the user explicitly requests `Frame Selected` or `Start From Product View`.

Semantic selection and an inactive Inspector draft persist across that mode
change. Character mode hides all editor-world decorations and manipulators;
returning to a visible Free Camera reprojects the yellow selection bounds and
applicable gizmo from the retained state without creating a selection or
authority transaction.

### 4.3 World selection and crate editing

1. Switch to Free Camera.
2. Select `Crate 1` in the World Outliner or click the crate in the viewport.
3. See the same row selected in the Outliner, a visible highlight around the
   crate, and crate details in the Inspector.
4. Scrub an X/Y/Z value or type an exact position in meters.
5. See a dirty draft and a preview gizmo without directly moving authority.
6. Apply the draft as one revision-checked session transaction.
7. Observe the correlated applied/rejected result and committed revision.
8. Undo, redo, or revert through typed owner operations.
9. Save a restorable world snapshot separately from the live edit.

---

## 5. Target Agent Workflow

The human ImGui workflow remains primary for people. The CLI is the sole local
agent-control product and uses machine-readable output. Local coding agents are
expected to have shell access, so this program adds no MCP adapter or second
client protocol.

An agent begins every session from the installed client itself:

```text
incinerator-dev agent bootstrap
incinerator-dev agent catalog
```

The bootstrap records endpoint lifecycle, current run identity, protocol and
agent-contract revisions, catalog digest, and safe next operation IDs. The
catalog is the authoritative installed description of commands, parameters,
units, effects, prerequisites, typed rejections, and completion models. The
repository-owned CLI skill teaches workflow judgment without copying that
catalog.

Every mutating result must report:

- run identity;
- source (`local_developer_client`);
- schema identity;
- stable target;
- transaction ID;
- expected and committed revision;
- edit scope;
- disposition and typed rejection;
- authority tick and presentation frame when applicable; and
- owner-specific requested and committed values.

`capture-frame` must return a concrete artifact path plus the presentation
frame and authority tick represented by the capture. It is not proof of an
authority mutation by itself; the correlated typed inspection and outcome are
the authority evidence.

---

## 6. Phase Sequence

### Phase 0 — Plan, terminology, and roadmap amendment review

**Status:** Accepted. The product owner explicitly authorized EA0.5 before EA1
on 2026-08-29. This is a schedule amendment; it does not rewrite EA0 history.

**Purpose:** Accept the program boundaries before implementation.

#### Deliverables

- Review and accept this plan.
- Decide whether EA0.5 local developer control is authorized before EA1 or
  remains deferred to EA2.
- If moved forward, amend the Engine Authoring Foundation sequence and status
  language without rewriting EA0 history.
- Adopt the terms `Character`, `Free Camera`, `World Outliner`, `Inspector`,
  `Content Browser`, `world instance`, `asset`, `session edit`, and `world
  snapshot` consistently.
- Confirm that free-camera mode does not pause gameplay.
- Confirm that automatic reload means timed reload with reserve, not infinite
  ammunition.
- Confirm that the existing crate phase authors position only.

#### Crate-dimensions decision

Crate dimensions are fixed today. This base plan displays fixed dimensions as
read-only evidence and does not add fake visual scale. If product-owned crate
resizing is desired, authorize a later dedicated typed resize slice covering:

- collider/body reconstruction;
- visual dimensions;
- stable identity retention;
- authority lifecycle and velocity policy;
- save and replay versioning;
- optimistic revision handling; and
- exact undo/redo.

That slice must not be implied by adding an Inspector scale widget.

#### Review gate

- Product owner accepts terminology, phase order, automatic-reload semantics,
  pause separation, endpoint schedule, and crate-dimensions scope.

---

### Phase 1 — Alphabetical Panels menu

**Status:** Accepted by the product owner on 2026-08-22

**Purpose:** Make panel discovery predictable without disturbing workspace
identity or layouts.

#### Implementation

- Add one explicit alphabetical presentation order based on visible panel
  names.
- Look up registered tools by stable `ToolId` when drawing the menu.
- Preserve registry order, enum values, startup panel IDs, layout masks,
  default focus, dock regions, and dock tab order.
- Retain tool purpose tooltips.
- Add an exhaustive test proving:
  - each registered panel appears once;
  - no unregistered ID appears;
  - names are ascending under the selected case-insensitive comparison; and
  - the menu order remains complete when a panel is added.

#### Automated acceptance

- Focused workspace/editor tests pass.
- Editor-enabled and editor-disabled aggregate tests pass.
- Existing startup parsing and layout tests remain unchanged.

#### Native and human acceptance

- Open Panels and verify all visible names are alphabetical.
- Toggle every panel and verify the expected panel opens and focuses.
- Reapply Gameplay, Navigation, Population, Rendering, Incident, Minimal, and
  All layouts and confirm dock placement is unchanged.

#### Stop review

- Architecture, dead-code, documentation-drift, automated, native Metal, and
  human review complete before Phase 2.

---

### Phase 2 — Authoritative automatic reload

**Status:** Accepted by the product owner on 2026-08-22

**Validation:**
[Phase 2 authoritative automatic reload](docs/validation/editor-interaction-phase-2-authoritative-automatic-reload.md)

**Purpose:** Prevent the handgun from remaining idle with an empty magazine
when reserve ammunition is available.

#### Implementation

- Change the ranged-combat feature so the last admitted shot atomically:
  - consumes the final magazine round;
  - preserves the admitted shot disposition;
  - enters `reloading` when reserve is nonzero; and
  - sets the ordinary authoritative reload-completion tick.
- Preserve manual `R` reload when the magazine is partially filled.
- Preserve `already_full`, `no_reserve`, `reloading`, cooldown, holstered,
  invalid-context, death-reset, and reload-cancellation behavior.
- Project the resulting weapon mode, zero magazine, reserve count, and reload
  deadline through the existing result, replication, HUD, diagnostics, and
  incident paths.
- Remove validation logic whose only purpose was to force an extra empty shot
  and manual reload before continuing.
- Do not synthesize an extra client request or consume a second action sequence.

#### Automated acceptance

- Feature test: last round with reserve admits the shot and starts reload.
- Feature test: reload completes at the exact authored deadline and transfers
  `min(capacity, reserve)` rounds.
- Feature test: last round without reserve remains equipped and empty.
- Feature test: manual tactical reload still works.
- Feature test: holster/death behavior remains exact.
- Solo/local session test observes the transition and completion.
- Network authority/client tests observe identical replicated state.
- S14 smoke and incident evidence validate the new accepted sequence.
- Editor-enabled and editor-disabled aggregate tests pass.

#### Native and human acceptance

- Equip with `1` and fire until the magazine reaches zero.
- Verify the final shot lands and reload begins without pressing `R`.
- Verify the HUD shows reloading and then the expected magazine/reserve counts.
- Fire during reload and confirm no shot is admitted.
- Reload a partially used magazine with `R` and confirm tactical reload remains.
- Exhaust reserve in a focused validation setup and confirm the weapon can
  genuinely become empty.

#### Stop review

- Architecture, dead-code, documentation-drift, automated, native Metal, and
  human review complete before Phase 3.

---

### Phase 3 — Explicit Character and Free Camera modes

**Status:** Accepted by product owner on 2026-08-22

**Validation:**
[Phase 3 explicit Character and Free Camera modes](docs/validation/editor-interaction-phase-3-viewport-modes.md)

**Purpose:** Separate character play from editor navigation and make pointer
ownership visible and deterministic.

#### Contracts

- Add a small `ViewportMode` enum owned by engine tooling/visual composition.
- Add immutable mode and free-camera projections to the editor frame.
- Add fixed semantic editor requests for mode change, camera movement, speed
  adjustment, frame-selection, and start-from-product-view.
- Keep SDL calls in the input/host adapter.
- Keep free-camera state out of gameplay authority, persistence, replication,
  and replay.

#### Input routing

- Character mode:
  - click unoccupied viewport to acquire gameplay-relative mouse lock;
  - consume the acquisition click;
  - route captured mouse look and gameplay actions normally; and
  - let `Esc` release lock without changing mode.
- Free Camera mode:
  - release gameplay-relative mouse lock on entry;
  - clear action latches and suppress gameplay actions;
  - route navigation and selection only while the viewport owns input; and
  - never select through an ImGui panel or outside the scene rectangle.
- Focus loss, minimization, close, and mode transition all clear held input.
- Remove or subordinate the ambiguous global Input Passthrough behavior if the
  explicit modes make it redundant. Do not retain two controls that claim to
  own the same policy without distinct documented purposes.

#### Camera behavior

- Preserve the existing product follow camera unchanged in Character mode.
- Initialize the first free-camera pose from the current product view.
- Thereafter retain an independent free-camera pose.
- Provide RMB+WASD, Q/E, Shift, and wheel navigation.
- Clamp pitch and validate finite camera values using existing camera rules.
- Make `F` a Free Camera-only frame-selection action so it cannot conflict with
  Character-mode collect/drop.
- Show mode and contextual controls in the top viewport toolbar and status bar.

#### Automated acceptance

- Mode-transition tests prove entering Free Camera releases lock and clears
  gameplay actions.
- Input tests prove a selection click cannot fire the weapon.
- Input tests prove the capture-acquisition click cannot fire the weapon.
- Input tests prove free-camera keys do not move the character or vehicle.
- Camera tests prove free pose is independent of character follow.
- Camera tests prove switching back resumes product follow.
- Focus/minimize/restore tests preserve the existing suspension guarantees.
- Editor-enabled and editor-disabled aggregate tests pass.

#### Native and human acceptance

- Toggle modes repeatedly from the top toolbar.
- In Character mode, click the viewport, look, move, fire, and release with
  `Esc`.
- Enter Free Camera while captured and confirm the cursor is released at once.
- Fly away while the character remains controlled by authority but receives no
  local input.
- Use every displayed Free Camera control.
- Switch back and verify the camera resumes the controlled character/vehicle.
- Verify menus and panels remain usable in Free Camera.

#### Stop review

- Architecture, dead-code, documentation-drift, automated, native Metal, and
  human review complete before Phase 4.

---

### Phase 4 — Selection foundation and World Outliner

**Status:** Accepted by product owner on 2026-08-23

**Validation:**
[Phase 4 selection foundation and World Outliner](docs/validation/editor-interaction-phase-4-selection-world-outliner.md)

**Purpose:** Make world-object discovery and selection coherent before adding
more authoring labs.

#### Selection contract

- Add an explicit editor selection union sufficient for concrete current
  consumers, such as:
  - authorable persistent entity;
  - inspectable gameplay entity/incarnation; and
  - durable content asset.
- Do not add a universal object handle, arbitrary string property path, or raw
  backend identifier.
- Carry stable identity, semantic display label, concrete type, owner,
  availability, inspectability, authorability, and immutable world bounds.
- Define one editor-local active selection projection.
- When an authoring owner requires an authoritative/session selection request,
  correlate the editor selection with that owner's existing typed request.

#### World Outliner

- Add a `World Outliner` panel in the left region.
- List current selectable world instances, initially including the crate and
  other already-projected inspectable gameplay entities where stable identity
  is available.
- Support text search and concrete type filters.
- Sort by semantic label, then stable identity.
- Display type and stable identity without exposing raw ECS or physics handles.
- Clearly mark unavailable, read-only, and authorable entries.
- Clicking a row selects the corresponding viewport object.
- Viewport selection scrolls/reveals and selects the same row.
- Empty-space click and an explicit Clear Selection action clear selection.

#### Viewport picking

- Publish the exact interactive scene rectangle from the editor layout.
- Map pointer coordinates through the same camera projection and scene extent
  used to render the product view.
- Build a camera ray only for a left click inside that rectangle in Free Camera.
- Select the nearest hit from immutable selectable bounds.
- Use a simple CPU ray/bounds query for the first accepted implementation.
- Do not call Jolt or inspect Flecs from an editor tool.
- Preserve a path to later renderer semantic-ID picking only if real content
  density proves CPU bounds insufficient.

#### Selection visualization

- Render an unmistakable selection highlight in ordinary deterministic output.
- Use a simple yellow bounding box for the shared selection. Reserve colored
  axes for an actual interactive transform gizmo instead of displaying a
  second passive axis marker.
- Ensure the highlight is visible against the current crate and environment
  colors.
- Keep selection visualization presentation-only and excluded from gameplay,
  physics, authority, save, and replay.
- Include selected stable identity in incident/render-state diagnostics.

#### Automated acceptance

- Selection-contract validation rejects invalid stable identities.
- Picking tests cover nearest hit, miss/clear, behind-camera rejection, panel
  exclusion, and scene-rectangle coordinate mapping.
- Outliner tests cover ordering, filtering, selection synchronization, stale
  disappearance, and no duplicate entries.
- Boundary tests prove host-neutral tooling imports no backend owners.
- Editor-enabled and editor-disabled aggregate tests pass.

#### Native and human acceptance

- Find the crate through search in World Outliner.
- Select it in the Outliner and see the viewport highlight.
- Clear selection and select it directly in the viewport.
- Confirm the Outliner follows the viewport selection.
- Select overlapping candidates from several camera angles and verify the
  nearest visible candidate wins.
- Click panels, menus, the top toolbar, status bar, and bottom panels and verify
  no world selection changes.
- Stream/unstream or otherwise invalidate a selectable object in a supported
  validation setup and verify stale selection clears visibly and safely.

#### Stop review

- Architecture, dead-code, documentation-drift, automated, native Metal, and
  human review complete before Phase 5.

---

### Phase 5 — Selection-driven crate Inspector and transform controls

**Status:** Accepted by the product owner on 2026-08-29 after automated/native
acceptance and the manual Inspector/gizmo/Escape walkthrough

**Validation:**
[Phase 5 selection-driven crate Inspector](docs/validation/editor-interaction-phase-5-crate-inspector.md),
[editor routing and Escape addendum](docs/validation/editor-interaction-routing-and-escape.md)

**Purpose:** Turn the crate proof into a comprehensible typed editing workflow
without generalizing it into a universal object editor.

#### Inspector structure

- Keep or rename the current crate panel according to the accepted workspace
  terminology, but make it selection-driven.
- Reveal and focus the Inspector when an inspectable crate becomes the shared
  selection. Respect a manual close until the selection changes.
- Show sections for:
  - identity and object kind;
  - availability and authorability;
  - current authoring revision;
  - published authority/presentation pose as applicable;
  - fixed crate dimensions and collider status as read-only evidence;
  - position draft;
  - transaction state and result;
  - undo/redo history;
  - authored-change evidence; and
  - saved-world-snapshot state.
- Collapse detailed audit/evidence sections by default while keeping the
  current selection, draft, and last result visible without scrolling.

#### Position controls

- Present X, Y, and Z as separate axis-colored rows.
- Each row supplies:
  - a scrubbable or slider-style exploratory control;
  - an adjacent exact numeric input;
  - meter units; and
  - consistent precision.
- Derive any visible slider range from actual current world/district bounds.
- Treat that range only as a UI hint. Exact numeric entry may exceed it and is
  then validated by the concrete crate owner.
- Keep all controls bound to one editor-local draft.
- Provide `Revert Draft`, `Apply Position`, `Undo`, and `Redo` with clear enabled
  states.
- Preserve the rule that a dirty draft remains stable while natural crate
  physics continues.

#### Transform gizmo

- Add a translate-only gizmo for the selected authorable crate.
- Gizmo motion updates the same draft used by numeric controls.
- Gizmo dragging may provide a disposable presentation preview but does not
  mutate authority directly.
- Releasing the gizmo does not silently apply or save.
- `Apply Position` emits one existing typed relocate transaction with current
  expected revision and zero-velocity policy.
- Rejection preserves the draft and exposes the typed reason.
- Acceptance refreshes the published pose and revision.

#### Save terminology

- Continue to label the persistence action `Save World Snapshot`.
- Explain in-panel that it writes a restorable sandbox state into the selected
  save slot/root.
- Never label this operation `Save Asset`, `Commit Asset`, or `Cook Content`.

#### Automated acceptance

- Draft synchronization tests cover clean follow, dirty stability, applied
  refresh, rejection preservation, selection change, and selection loss.
- Control tests cover scrub input, exact input, non-finite rejection, and
  presentation-range overflow.
- Gizmo tests independently prove begin/update/drop, Escape restore, preservation
  of a pre-existing dirty draft, and the absence of any authority request before
  explicit Apply.
- Routing tests prove the active gizmo consumes Escape before the system menu,
  and the system menu consumes its closing Escape before application lifecycle.
- The native SDL gate proves Escape priority across Character capture, Free
  Camera RMB look, system-menu open/close, and explicit quit.
- Transaction tests cover apply, stale revision, owner busy, undo, redo, and
  save deferral while a transaction or dirty draft exists.
- Save/replay and incident evidence remain exact.
- Editor-enabled and editor-disabled aggregate tests pass.

#### Native and human acceptance

- Select the crate through both Outliner and viewport.
- Verify highlight, stable identity, revision, position, and fixed dimensions.
- Scrub each axis and type exact positive, negative, and fractional values.
- Move the translate gizmo and verify numeric fields follow.
- During one drag, press Escape and verify the exact pre-drag draft and dirty
  state return without moving authority or opening the system menu.
- With no active drag/look/capture, press Escape to open the system menu; press
  Escape again to resume, then reopen it and use Quit explicitly.
- Revert without applying and verify authority never moves.
- Apply a draft and verify the crate moves, the result is correlated, and the
  revision advances.
- Undo and redo the move.
- Create a stale-revision rejection through a focused validation path and
  verify the draft remains recoverable.
- Save the world snapshot, restart with the same save root/slot, and verify the
  committed crate position restores.

#### Stop review

- Architecture, dead-code, documentation-drift, automated, native Metal, and
  human review complete before Phase 6.

---

### Phase 6 — EA0.5 local endpoint and canonical CLI

**Status:** Complete and accepted by the product owner on 2026-08-30

**Purpose:** Give developers and LLM agents a live, typed, local control path
through the same ownership boundaries as ImGui.

**Precondition:** Phase 0 explicitly authorizes moving endpoint transport ahead
of EA2 and the roadmap amendment is accepted.

**Validation:**
[EA0.5 local developer endpoint and canonical CLI](docs/validation/ea0-5-local-developer-endpoint-and-canonical-cli.md)

#### Endpoint lifecycle

- Implement the existing developer-endpoint lifecycle states around a
  process-local Unix domain socket available only in explicit editor/developer
  products.
- Publish absolute endpoint path, run identity, protocol cohort, available
  schema IDs, and schema digest in the run/incident manifest.
- Remove the socket on orderly shutdown, serialize shared discovery ownership,
  retire only validated dead canonical sockets, and report failed/stale
  discovery explicitly.
- Keep editor-disabled and shipping/headless products endpoint-free unless a
  named validation product explicitly composes it.
- Admit only same-machine developer clients under the current macOS scope.

#### Protocol

- Use framed, versioned, machine-readable requests and responses.
- Register concrete schemas manually.
- Separate query, editor-control, authoring, persistence, and measurement
  operations.
- Require transaction IDs and expected revisions for applicable mutations.
- Preserve owner-specific typed validation and rejection.
- Correlate accepted/rejected operations with authored-change diagnostics and
  incident evidence.
- Do not add shell execution, filesystem browsing, raw pointers, arbitrary
  object/property paths, multiplayer administration, or remote listening.

#### Canonical CLI product

- Add an `incinerator-dev` macOS command-line product and reusable typed client
  library.
- Support at minimum:
  - endpoint discovery and `describe`;
  - schema discovery;
  - `world list`;
  - `content list`;
  - stable-target `inspect`;
  - editor `select` and clear selection;
  - camera inspect and Character/Free Camera mode change;
  - free-camera pose/focus controls needed for repeatable observation;
  - crate position apply with expected revision;
  - transaction outcome inspection;
  - undo and redo;
  - save-world request and result; and
  - correlated rendered frame capture.
- Make JSON output complete and stable within the declared protocol cohort.
- Human-readable output may format the same response but cannot hide fields
  needed for automation.

#### World versus content queries

- `world list` returns live instances with persistent/gameplay identity,
  semantic type, selection state, position/bounds, availability, and current
  revision when authorable.
- `content list` returns only real durable/cooked content entries and `AssetId`
  values that currently exist.
- The crate appears in `world list`, not `content list`.
- Source paths remain editor/importer concerns and are not exposed as runtime
  asset identity.

#### Seeing results

- Authoring, save, and capture submissions report admission/rejection
  separately from terminal completion. Selection and camera operations are
  synchronous.
- Transaction inspection reports the terminal owner result.
- A subsequent target inspection reports the resulting state and revision.
- Frame capture provides human-visible presentation evidence tied to a tick and
  presentation frame.
- Optional bounded measurement actions must use registered concrete schemas and
  existing diagnostic owners; they cannot execute arbitrary code.

#### Automated acceptance

- Endpoint lifecycle tests cover disabled, starting, available, stopping,
  stopped, failed, stale socket, and mismatched run identity.
- Framing/codec tests cover partial reads/writes, malformed frames, unknown
  cohort/schema, and orderly disconnect.
- CLI integration tests cover every declared command against a real local test
  host.
- UI and CLI crate transactions produce identical owner requests, outcomes,
  stale-revision rejection, revision advancement, and diagnostics.
- Multiple producers receive their own correlated outcomes without cross-talk.
- Editor-disabled products prove the endpoint and client server-side code are
  absent from the runtime composition.
- Full aggregates, save/replay, incident, installed-product, and native Metal
  gates pass.

#### Native and human/agent acceptance

- Start the editor and discover it from a second terminal without manually
  copying private process state.
- List the world and verify the crate is not misreported as an asset.
- Inspect and select the crate; verify ImGui and viewport update.
- Switch to Free Camera from CLI and verify mouse capture releases.
- Relocate the crate with the observed revision, inspect the result, and capture
  a frame showing the new position.
- Produce a stale-revision rejection and verify the UI and CLI report the same
  typed reason.
- Undo, inspect, capture again, and save the world snapshot.
- Stop the editor and verify discovery reports the endpoint unavailable rather
  than connecting to a stale run.

#### Stop review

- Architecture, security/scope, dead-code, documentation-drift, automated,
  installed-product, native Metal, human, and LLM-agent review complete before
  Phase 7.

---

### Phase 7 — First-class CLI agent contract and skill

**Status:** Accepted by the product owner on 2026-08-30 after implementation,
automated, installed Metal, clean-context agent, and comprehensive manual
agent review.

**Purpose:** Make the accepted `incinerator-dev` client self-describing and hard
for shell-capable coding agents to misuse, without introducing another protocol
or mutation path.

#### Implementation

- Add a separate, read-only, manually registered CLI operation catalog beside
  the fixed sandbox protocol. It describes operation IDs, command tokens,
  parameter types/units/sources, effect class, availability, completion model,
  polling path, terminal follow-up, typed rejection reasons, and valid examples.
- Keep the operation catalog descriptive only. Typed protocol commands and the
  reusable client remain the executable source of truth; do not infer a generic
  property system or command dispatcher.
- Add `agent bootstrap` for current discovery lifecycle, run identity, protocol
  cohort, schema identity, agent-contract revision/catalog digest, and safe next
  operation IDs.
- Add `agent catalog` as an offline-capable machine-readable description of the
  installed CLI.
- Wrap endpoint results with the stable operation ID, explicit `terminal`
  state, structured next operations, and the complete typed response. Admission
  remains visibly distinct from terminal completion.
- Preserve the typed JSON body for every result while returning a nonzero shell
  status for endpoint failures, rejected terminal transactions, failed results,
  and missing correlated results. Successful admissions and pending polls exit
  zero.
- Describe transaction `committed_position` as the pose applied at the
  authority tick and crate inspection as the dynamic body's current simulated
  pose; physics evolution after commit is not a transaction mismatch.
- Report canonical snapshot payload bytes for committed saves. The fixed
  sandbox slot truthfully reports no storage generation.
- Keep the agent catalog digest independent of the endpoint wire-schema digest;
  documentation metadata changes do not manufacture protocol incompatibility.
- Add the repository-owned `incinerator-developer-cli` skill. The skill owns
  workflow judgment and reads the installed catalog instead of duplicating it.
- Record the CLI skill trigger in `AGENTS.md` so project coding agents load it
  before inspection, authoring, persistence, or evidence workflows.
- Add no MCP dependency, shell evaluator, unrestricted file access, remote
  transport, raw engine object access, or multiplayer administration.

#### Required agent-contract coverage

- Every public CLI operation has one stable descriptor and valid example.
- Every endpoint command maps exhaustively to exactly one matching schema and
  agent operation.
- Every mutating operation declares presentation, session-authority, durable,
  or evidence effect.
- Every admitted operation declares its polling operation and emits the
  correlation ID needed to use it.
- Revisioned operations identify the inspection source for the expected
  revision and require terminal reinspection.
- The base skill covers discovery, current-run identity, world/content
  distinction, effect classification, typed failure, and handoff evidence.
- Conditional skill references cover authoring transactions and
  persistence/capture without loading those details for read-only queries.

#### Automated acceptance

- Catalog completeness and uniqueness are checked structurally, not by brittle
  prose snapshots.
- The command-union-to-descriptor switch is exhaustive and each descriptor's
  endpoint schema matches the typed command schema.
- Every catalog example parses through the canonical CLI grammar.
- Guidance tests distinguish synchronous, admitted, pending, accepted,
  rejected, committed, captured, and failed results.
- CLI status tests distinguish successful/pending operations from typed
  terminal failure without suppressing the JSON response.
- The installed `agent catalog` output parses as complete JSON without a live
  editor; `agent bootstrap` validates the current discovery document.
- The focused endpoint/client/CLI group, editor-enabled/disabled aggregates,
  installed-product, and native Metal gates pass.
- Editor-disabled and ordinary headless products acquire no CLI catalog, skill,
  endpoint, or mutable-authoring runtime dependency.

#### Human/agent acceptance

- From a clean agent context, load the repository skill, run bootstrap/catalog,
  and discover the live product without private repository knowledge.
- Find and inspect the crate; select it and establish a useful Free Camera view.
- Move it with the observed revision, follow structured next operations to a
  terminal result, and re-inspect the committed value/revision.
- Capture and inspect correlated visual evidence, undo the edit, and verify
  restoration.
- Request a durable save only when separately authorized and report exactly
  what the committed result proves.
- Confirm an unavailable/stale run stops the workflow rather than provoking
  guessed identities, flags, or retries.

#### Stop review

- Architecture, security/scope, dead-code, documentation-drift, automated,
  native Metal, human, and LLM-agent review complete before Phase 8.

---

### Phase 8 — EA1 real Content Browser integration

**Purpose:** Add conventional asset exploration when EA1 supplies meaningful
project-owned texture, material, and scene identities.

This phase is coordinated with EA1-A and EA1-B. It does not pull texture or
material implementation ahead of the accepted Engine Authoring Foundation
sequence.

EA1-A candidate status: the read-only catalog, Content Browser, Inspector,
separate asset selection, residency diagnostics, and CLI inspection are
implemented and machine-validated. Thumbnails/previews, live material
assignment/revert, and durable commit remain EA1-B.

#### Content Browser

- Add a `Content Browser` panel, normally docked in the bottom region or opened
  as a drawer without displacing the World Outliner/Inspector distinction.
- Query a read-only content catalog projection with stable `AssetId`.
- Support:
  - text search;
  - concrete type filters;
  - engine versus game ownership;
  - source/import/cook validity where editor-only data is available;
  - cooked digest and revision;
  - dependencies;
  - dimensions/format/color space/sampler for applicable textures;
  - material bindings;
  - residency and last-use diagnostics where applicable; and
  - thumbnails/previews after EA1 proves the required renderer/tool support.
- Keep imported source identity/provenance distinct from runtime cooked identity.
- Selecting an asset updates the Inspector with an asset-specific typed view.
- Selecting an asset does not replace world-instance selection unless a
  deliberate placement/assignment workflow requests it.

#### Agent parity

- Extend `content list` and asset inspection with the same fields presented in
  ImGui.
- Let agents inspect dependencies, cook state, and residency.
- Add only the typed material preview/assignment/commit operations authorized by
  EA1-B.
- Keep preview, session assignment, and durable asset commit visibly distinct.

#### Automated acceptance

- Catalog UI and CLI projections agree on stable identity and digest.
- Search/filter tests cover type, owner, name, and invalid content.
- Runtime entities never appear as assets.
- Source paths never become runtime identity.
- Asset selection and world selection remain distinct and deterministic.
- EA1 cook determinism, renderer residency, material assignment, commit,
  installed-product, and native Metal gates pass.

#### Native and human/agent acceptance

- Find a project-owned textured scene/object, material, and texture by name and
  type.
- Inspect identity, dependencies, dimensions, color space, sampler, cook digest,
  residency, and last use.
- Select the reusable asset, then separately select one placed/live instance and
  verify the distinction remains obvious.
- Perform the accepted EA1 preview, assignment, revert, and durable commit flow
  from ImGui and the agent path.
- Restart from installed cooked content and verify the committed result without
  runtime source-file discovery.

#### Stop review

- Complete the normal EA1-A/EA1-B architecture, dead-code,
  documentation-drift, automated, installed-product, native Metal, human, and
  LLM-agent acceptance before continuing to EA2.

---

## 7. Cross-Phase Automated Matrix

Every implementation phase must run the gates relevant to its changed owners.
The exact build invocations remain the current repository commands rather than
being duplicated here and allowed to drift.

| Gate | P1 | P2 | P3 | P4 | P5 | P6 | P7 | P8 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Focused unit/contract tests | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Editor-enabled aggregate | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Editor-disabled aggregate | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Solo authority regression | No | Yes | Yes | No | Yes | Yes | Yes | Yes |
| Listen/dedicated regression | No | Yes | No | No | No | Yes | Yes | As affected |
| Save/replay regression | No | As affected | No | No | Yes | Yes | Yes | Yes |
| Incident/diagnostic schema | No | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Architecture/import verifier | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Installed product | As affected | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Native Metal visual pass | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Human checkpoint | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| LLM-agent checkpoint | No | No | No | No | No | Yes | Yes | Yes |

No failing pre-existing gate may be dismissed as unrelated without recording
the exact failure, reproducing it on the baseline when possible, and obtaining
review agreement. New tests must exercise likely product behavior and concrete
contracts rather than speculative pathological cases.

---

## 8. Documentation and Evidence Requirements

Each phase must update only the documents it materially changes and must leave a
concise acceptance record containing:

- final implementation scope;
- files/owners changed;
- architecture review and forbidden-dependency result;
- dead-code and superseded-path result;
- documentation-drift result;
- focused and aggregate test results;
- installed/native Metal evidence where applicable;
- human test checklist and result;
- agent test transcript/result where applicable;
- known limitations grounded in observed behavior; and
- explicit statement that the next phase has or has not begun.

At minimum, accepted work is reflected in:

- this plan's status/history;
- `OVERHAUL_PLAN.md` phase ledger;
- the affected design document under `docs/design/`;
- a matching validation record under `docs/validation/`;
- ADR-029 or a new ADR only when an architectural decision actually changes;
  and
- README controls/workflow text where human operation changes.

The endpoint schedule amendment changes the Engine Authoring Foundation plan but
does not retroactively make socket/CLI transport part of EA0. If the underlying
ownership decision remains intact, ADR-029 needs only status/reference updates,
not a replacement decision.

---

## 9. Explicit Non-Goals

This program does not add:

- arbitrary runtime entity creation or deletion;
- a generic scene graph or prefab framework;
- broad map construction, duplication, multi-select, layers, snapping, or
  deterministic recooking before EA4;
- generic transform authoring for every runtime entity;
- crate resizing unless separately authorized under the Phase 0 decision;
- a string-to-any CVar/property system;
- reflection-driven inspectors;
- unrestricted console or scripting VM;
- remote developer control;
- multiplayer administration;
- production authentication/matchmaking/services;
- source-asset loading by the runtime renderer;
- thumbnails/previews invented before a real EA1 content consumer needs them;
- a second mutation authority or MCP adapter; or
- automatic gameplay pause when entering Free Camera.

Neural rendering remains paused and is not touched by this program.

---

## 10. Risks and Concrete Mitigations

### Selection accidentally fires or controls gameplay

Mitigation: explicit viewport mode, action-latch reset on transition, acquisition
click consumption, Free Camera gameplay suppression, and event-routing tests.

### Picking does not match the visible scene

Mitigation: publish one exact scene rectangle and use the same camera projection
and scene extent for rendering and ray construction. Test panel boundaries and
resized layouts.

### Selection becomes a generic object/property framework

Mitigation: explicit union variants and owner-written inspectors/requests only.
Do not accept arbitrary property paths or backend handles.

### Free camera corrupts gameplay/replay identity

Mitigation: keep free-camera and selection state entirely in developer
tooling/presentation. Do not persist or replicate it.

### Automatic reload diverges between placements

Mitigation: implement the transition in the shared ranged-combat authority rule
and validate solo, listen, dedicated, protocol, and presentation projections.

### Slider range becomes an undocumented gameplay limit

Mitigation: derive it from observed world bounds as a presentation hint and
allow exact entry outside the range for owner validation.

### CLI becomes a privileged bypass

Mitigation: reuse the same typed owner request path, source/revision/transaction
metadata, and result correlation. Keep transport local and developer-only.

### Runtime objects are confused with assets

Mitigation: separate `world list`/World Outliner from `content list`/Content
Browser, and display the identity kind explicitly.

### EA0 history is rewritten to absorb new scope

Mitigation: name and record EA0.5 as a schedule amendment. Preserve the accepted
fact that EA0 defined discovery contracts but no transport.

---

## 11. Program Completion Criteria

This plan is complete only when:

1. Panels are alphabetical without changing layout or stable tool identity.
2. The authority automatically begins a timed reload after the final round when
   reserve ammunition remains, consistently across placements.
3. Character and Free Camera are explicit, understandable, and safely routed.
4. Free Camera releases gameplay capture, cannot control the character, and
   supports conventional navigation and selection.
5. World Outliner and viewport share stable selection with a visible highlight.
6. The crate is clearly presented as a runtime world instance rather than an
   asset.
7. Crate position supports exploratory and exact input, translate gizmo,
   revisioned apply, rejection, undo/redo, and saved-world restoration.
8. The local CLI can discover, inspect, change, observe, capture, revert, and
   save through typed schemas with no private code knowledge.
9. The CLI publishes a first-class agent bootstrap/catalog, guided result
   model, and repository-owned skill without duplicating or bypassing owners.
10. EA1 Content Browser integration lists and inspects real project-owned assets
    without mixing them with live instances or runtime source paths.
11. Editor-disabled and shipping/runtime compositions do not acquire editor,
    endpoint, CLI-server, agent-contract, importer, or mutable-authoring
    dependencies.
12. Every phase has its own accepted architecture, dead-code,
    documentation-drift, automated, native Metal, human, and applicable agent
    evidence before the program advances.
