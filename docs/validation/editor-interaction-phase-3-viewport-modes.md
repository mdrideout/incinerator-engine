# Editor Interaction Phase 3: Explicit Character and Free Camera Modes

**Status:** Accepted by product owner on 2026-08-22 after corrective rendering
repair and interaction retest

**Date:** 2026-08-22

**Plan:**
[Editor Interaction and Agent Control Plan](../../EDITOR_INTERACTION_AND_AGENT_CONTROL_PLAN.md)

## Outcome

The editor now exposes two explicit viewport interaction modes instead of one
ambiguous global input-passthrough switch:

- **Character** preserves the existing controlled-character/vehicle follow
  camera. Only a left click inside the published scene rectangle acquires SDL
  relative mouse mode, and that acquisition click is consumed rather than
  becoming a handgun shot.
- **Free Camera** immediately releases SDL relative mouse mode, clears held
  gameplay actions, keeps the cursor available, suppresses character and
  vehicle controls, and navigates an independent presentation camera with
  RMB+WASD, Q/E, Shift, and the mouse wheel.

Switching modes does not pause authority. The free camera is visual-host state;
it is absent from gameplay authority, session protocol, replication, replay,
incident input replay, persistence, and world snapshots.

## Ownership and implementation

- `src/editor/viewport.zig` defines the small `Mode` enum, immutable
  free-camera projection, exact window-space scene rectangle, focus target,
  and fixed semantic request slots. It is a renderer-neutral tooling contract,
  not a generic property or command framework.
- `src/viewport_controller.zig` owns the visual-host mode and independent
  camera. The first Free Camera entry copies the current product view; later
  entries restore the retained free pose. `Start From Product View` is the
  explicit reset operation.
- `src/input.zig` remains the only SDL relative-mouse owner. It consumes the
  acquisition click, releases capture on Free Camera entry, separates physical
  input from gameplay-visible input, and emits typed navigation/speed requests
  only while a scene-owned right drag is active.
- `src/main.zig` composes typed viewport requests and chooses the active camera
  for deterministic presentation. Character movement continues to use the
  product camera's facing; Free Camera input never enters the gameplay action
  latch.
- `src/editor/editor.zig` publishes the exact central scene rectangle, provides
  the top scene toolbar and contextual guide, and shows the current mode and
  pointer state in the product/status surfaces. `F3` toggles the same explicit
  mode contract from either captured or cursor-visible state.
- `src/camera.zig` supplies finite-validated local flight, existing pitch/yaw
  rules, smooth wheel speed adjustment, and focus framing.

The old `Input Passthrough` menu and shortcut semantics were removed. There is
now one control for viewport input ownership rather than two overlapping
policies.

## Deliberate Phase 4 boundary at Phase 3 acceptance

At Phase 3 acceptance, Free Camera left clicks were already removed from
firearm and all other gameplay input, including clicks outside the scene or
through ImGui, but did not yet pick world objects. Shared viewport picking,
explicit cross-tool selection, highlighting, and the World Outliner remained
the Phase 4 boundary. Phase 4 has since implemented that boundary; see the
[Phase 4 validation ledger](editor-interaction-phase-4-selection-world-outliner.md).

`Frame Inspector Selection` and the Free Camera-only `F` shortcut were live in
this phase for the then-existing Gameplay Inspector selection. This provided a
real typed frame-selection consumer without pre-implementing Phase 4's
selection union or CPU picking path.

## Corrective human-review repair

The first product-owner walkthrough found that the initial implementation
docked a transparent `Scene Viewport` window into the pass-through central dock
node. The window requested no background, but the ImGui dock host still painted
the occupied node. That produced a dark veil over the renderer and also made
the overlay/input ownership arrangement unreliable.

The corrected implementation keeps the central dock node empty. It reads that
node's exact rectangle from ImGui, publishes only the portion below the toolbar
as the scene input rectangle, and draws the toolbar as one independent
interactive overlay. There is no full-size ImGui window over the scene and no
central dock-host background to dim it.

A fresh editor-inclusive native Metal incident smoke captured the corrected
frame at:

```text
/Users/matt/Library/Logs/Incinerator/runs/2026-08-22T21-51-50.139Z_solo_9deb251d/anomalies/anomaly-0001/screenshot-human-flag.ppm
```

The capture shows the deterministic scene at normal brightness, the compact
toolbar at the top of the central region, and the left, right, and bottom dock
panels remaining opaque and separate. The same run completed at 540 authority
ticks with a clean ImGui shutdown, zero screenshot misses, and zero screenshot
fence failures. Product-owner interaction review remains pending until the
repaired toolbar and physical Free Camera controls are exercised manually.

## Automated evidence

Focused editor/input/visual-host checks:

```sh
zig build test-mouse-capture-macos test-sandbox-developer-host \
  check-validation -Deditor=true --summary all
zig build check-validation -Deditor=false --summary all
```

The native SDL acceptance reports:

```text
MOUSE_CAPTURE_ACCEPTANCE_PASS first_click_consumed=true relative=true outside_scene_suppressed=true captured_click=true escape_release=true free_camera=true free_navigation=true selection_suppressed=true character_restore=true free_escape_quit=true failures=0
```

That line is the historical Phase 3 result. ADR-030 intentionally superseded
its final `free_escape_quit` behavior and label on 2026-08-29; current acceptance
is recorded in
[Editor Input Routing and Escape](editor-interaction-routing-and-escape.md).

Result: `52/52` focused steps and `64/64` graphical developer-host tests pass.
The suite includes the viewport contract, camera-controller, editor routing,
and existing owner tests. The native SDL process exits cleanly with zero mouse
lock failures. The editor-disabled validation product also compiles (`42/42`
steps), preserving the compile-time optional editor boundary.

Installed native Metal presentation:

```sh
zig build smoke-installed-s1-macos -Deditor=true --summary all
```

Result: `83/83` steps passed. The installed validation product rendered 160
ready frames with `gpu_driver=metal`, preserved character follow/movement/jump,
and shut down cleanly.

Complete repository aggregates:

```sh
zig build test -Deditor=true -j1 --summary all
zig build test -Deditor=false -j1 --summary all
```

Results:

- editor enabled: `305/305` steps and `1043/1043` tests passed;
- editor disabled: `302/302` steps and `1043/1043` tests passed; and
- installed verification reported the canonical content catalog, MSL shaders,
  Metal GPU driver, and the expected editor boundary in both configurations.

## Architecture, dead-code, and documentation review

- No free-camera field was added to a game feature, authority snapshot,
  protocol DTO, replay encoding, save schema, or content asset.
- ImGui emits only typed viewport requests and never calls SDL or mutates the
  camera directly.
- The input adapter does not reach gameplay authority; it projects raw input
  into either gameplay-visible state or fixed viewport requests.
- `Input Passthrough` state and UI are removed rather than retained as a second
  ownership switch.
- The independent free pose has one owner and one explicit initialization path.
- Focus loss and minimization reuse the physical release boundary and also end
  Free Camera right-drag ownership.
- README controls and the root phase ledger describe the new modes, no-pause
  behavior, and Phase 4 selection boundary.

## Accepted product-owner interaction review

Run:

```sh
zig build run -Deditor=true
```

Then test:

1. Confirm the central scene has a top toolbar with `Character [active]`,
   `Free Camera`, the contextual control guide, and a footer/status mode label.
2. In Character mode, click a panel and confirm it neither captures the mouse
   nor fires. Click the scene and confirm relative capture begins without a
   shot. Move/look/fire normally, then press `Esc` and confirm only capture is
   released.
3. Capture the mouse again and press `F3`. Confirm Free Camera becomes active
   and the cursor is released immediately. Repeat with the toolbar buttons.
4. Hold right mouse over the scene and use WASD, Q/E, mouse look, Shift, and
   wheel speed. Confirm the view flies independently.
5. While in Free Camera, press/click gameplay controls (`1`, left mouse, Q, E,
   F, Space, R, and WASD without a scene-owned right drag). Confirm the
   character/vehicle receives no local action. Ambient simulation continues;
   this mode is not pause.
6. Select an entity in Gameplay Inspector, enter Free Camera, and use `Frame
   Inspector Selection` or hover the scene and press `F`. Confirm the camera
   frames that entity. Use `Start From Product View`, then fly elsewhere.
7. Switch to Character and confirm the camera immediately resumes the current
   character or occupied vehicle. Return to Free Camera and confirm the prior
   free pose was retained unless `Start From Product View` was used.
8. Confirm all menus and panels remain usable with the Free Camera cursor. A
   left scene click must not fire; viewport object selection is intentionally
   the next phase.
9. Minimize/restore or change focus during both captured Character play and a
   Free Camera right drag. Confirm held movement/look does not remain latched.

The product owner confirmed the corrected rendering, explicit mode toggles,
capture/release behavior, and Free Camera navigation all worked, then
authorized Phase 4. This closes the Phase 3 stop review.
