# Editor Interaction Phase 4: Selection Foundation and World Outliner

**Status:** Accepted by product owner on 2026-08-23 after automated, native
Metal, and interaction review

**Date:** 2026-08-23

**Plan:**
[Editor Interaction and Agent Control Plan](../../EDITOR_INTERACTION_AND_AGENT_CONTROL_PLAN.md)

## Outcome

The editor now has one typed, editor-local world selection shared by the World
Outliner, Free Camera viewport picking, Gameplay Inspector, event history,
camera framing, crate authoring selection, render diagnostics, and incident
capture.

The new **World Outliner** appears in the left dock across deterministic
workspace presets. It lists the persistent crate and currently projected local
player, remote players, NPCs, vehicles, and carryables. It supports dynamically
resized text search, concrete type filters, deterministic label/identity order,
explicit stable identities, owner/capability labels, selection reveal, and a
Clear Selection action.

In Free Camera, a left click inside the exact published scene rectangle creates
a CPU camera ray using the rendered camera FOV/aspect and current logical window
coordinates. The nearest intersected immutable world AABB wins. A miss clears
selection. Character mode and all ImGui-owned coordinates remain excluded.

The selected object receives an unlit yellow AABB in ordinary deterministic
output. The originally accepted passive red/green/blue axis marker was removed
when Phase 5 introduced the interactive crate translate gizmo, avoiding two
different axis displays on one selection. The yellow visualization is submitted
directly through the renderer debug path and is not recorded as gameplay,
authority, physics, save/replay, replication, or neural-renderer input.

## Ownership and contracts

- `src/editor/selection.zig` is renderer-neutral. Its closed identity union is
  persistent entity, gameplay entity/incarnation, or durable content asset. It
  contains no ECS ID, physics body, renderer handle, pointer, source path, or
  property path.
- Each selection entry carries a semantic label, concrete object kind, game
  owner, availability, inspectability, authorability, and optional immutable
  world bounds. Non-asset world entries require valid finite bounds.
- `src/main.zig` owns the active controller and the dynamically sized current
  entry projection. It builds entries from already extracted presentation
  records, never by querying Flecs or Jolt from an editor tool.
- The Outliner and Gameplay Inspector emit the same typed latest-semantic
  request. Selecting the crate correlates that selection with the existing
  revisioned crate-authoring controller; selecting anything else clears the
  crate-authoring selection.
- Missing or unavailable identities clear safely during per-frame
  reconciliation. No compatibility selection state remains in Gameplay
  Inspector.
- Incident `render_state` records include selected object kind, identity kind,
  namespace, local value, and incarnation. Incident anomaly entity correlation
  uses the selected gameplay identity when applicable and does not mislabel a
  selected crate as the local player.

## Automated acceptance

The Phase 4 tests cover:

- invalid persistent, gameplay, and asset identities;
- finite positive world bounds and closed capabilities;
- deterministic case-insensitive label then stable-identity ordering;
- text/type filtering and duplicate identity detection;
- shared selection synchronization and stale disappearance;
- ray construction at screen center and corners using rendered aspect;
- nearest hit, miss/clear behavior, and behind-camera rejection;
- exact scene rectangle edges and panel-coordinate exclusion;
- one-shot Free Camera selection clicks that never become firearm input;
- editor-enabled and editor-disabled composition closure; and
- host-neutral editor contracts through the standalone developer-host root.

Commands completed successfully:

```sh
zig build test-sandbox-developer-host -Deditor=true
zig build test-sandbox-developer-host test-mouse-capture-macos check-validation -Deditor=true
zig build test -Deditor=true
zig build test -Deditor=false
```

The native input acceptance remained green:

```text
MOUSE_CAPTURE_ACCEPTANCE_PASS first_click_consumed=true relative=true outside_scene_suppressed=true captured_click=true escape_release=true free_camera=true free_navigation=true selection_suppressed=true character_restore=true free_escape_quit=true failures=0
```

That line is retained as historical Phase 4 evidence. ADR-030 intentionally
replaced the final free-Escape behavior and acceptance label on 2026-08-29; see
[Editor Input Routing and Escape](editor-interaction-routing-and-escape.md) for
the current contract and output.

## Native Metal validation

`zig build smoke-installed-s1-macos -Deditor=true` completed on Apple Silicon
with the real Metal renderer and the 14-tool ImGui editor:

```text
GPU Device created: metal
Editor initialized with 14 tools
S1_VISUAL_SMOKE_RESULT ready_frames=160 unavailable_frames=0 attempted_frames=160 character_frames=159 character_moved=true jump_observed=true ticks=124 alpha_min=0.000000 alpha_max=0.750000 virtual_render_hz=80 gpu_driver=metal
S1_VISUAL_SMOKE_SHUTDOWN status=clean
```

This proves the new selection projection and highlight draw path compile,
initialize, render, submit, and tear down on native Metal. The interaction and
visual clarity of selection remain the product-owner gate below.

## Architecture, dead-code, and documentation review

- There is one active editor selection owner. Gameplay Inspector's former
  private default-to-local selection was removed.
- Selection is not persisted or replicated and cannot mutate game authority.
- Viewport picking consumes only immutable extracted bounds and camera values.
- Search storage grows through the allocator instead of imposing a content or
  label cap.
- World entry storage grows to the actual extracted cohort rather than adding
  a new arbitrary selection capacity.
- The World Outliner descriptor, alphabetical Panels menu, preset masks,
  workspace guide, README controls, root phase ledger, and incident schema are
  updated together.
- No Phase 5 Inspector, transform slider, gizmo, or draft authoring behavior was
  added.

## Accepted product-owner interaction review

Run:

```sh
zig build run -Deditor=true
```

Then test:

1. Open **World Outliner** in the left dock. Search for `crate`, then use the
   type filter to switch among Crate, Local Player, NPC, Vehicle, and Carryable.
   Confirm entries show semantic type, stable identity, owner, and either
   `AUTHORABLE` or `READ-ONLY`.
2. Select the crate row. Confirm the row is selected and the rendered crate has
   a bright yellow bounding box. In the Phase 5 editor, the only colored axes
   are the interactive translate gizmo.
3. Press **Clear Selection**. Confirm both row selection and highlight clear.
4. Enter **Free Camera**. Left-click the crate in the scene. Confirm the same
   highlight appears and the Outliner reveals/selects the crate row. Press `F`
   or **Frame Selection** and confirm the camera frames the crate.
5. Select the local player, an NPC, vehicle, and carryable from the Outliner and
   by viewport click. Confirm Gameplay Inspector follows gameplay selections
   and shows no stale entity for the crate.
6. Move around with RMB+WASD and click partially overlapping objects from
   several angles. Confirm the nearest intersected bounds win.
7. Left-click empty scene space. Confirm selection clears.
8. Click the top toolbar, menus, left/right panels, bottom diagnostics tabs,
   status bar, and footer. Confirm selection never changes through UI.
9. Switch to Character mode and click/fire normally. Confirm Character clicks
   do not select and Free Camera selection clicks never fire the handgun.
10. Despawn or stream away a selected supported gameplay object if convenient.
    Confirm the highlight and selection clear safely on the next projection.

The product owner confirmed the World Outliner, shared selection, viewport
picking, selection highlight, framing, and UI click exclusion worked, then
authorized this Phase 4 record to close. Phase 5 had not started at that
checkpoint; it is now accepted under the
[Phase 5 validation record](editor-interaction-phase-5-crate-inspector.md).
