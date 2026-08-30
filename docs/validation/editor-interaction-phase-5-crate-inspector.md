# Editor Interaction Phase 5: Selection-driven Crate Inspector

**Status:** Complete and accepted by the product owner on 2026-08-29

**Date:** 2026-08-23

**Plan:**
[Editor Interaction and Agent Control Plan](../../EDITOR_INTERACTION_AND_AGENT_CONTROL_PLAN.md)

## Outcome

The former crate-specific authoring window is now the conventional
selection-driven **Inspector**. Selecting the persistent runtime crate through
the World Outliner or Free Camera viewport automatically reveals and focuses
the panel. It shows the shared identity, concrete kind and owner,
availability/authorability, current authoring revision, published authority
position, fixed dimensions, and active dynamic-box collider status. Dimensions
and collider evidence are deliberately read-only. A deliberate manual close is
respected until selection changes and the crate is selected again.

The Inspector owns one editor-local XYZ position draft. Every axis has a
color-coded installed-world-range slider, an adjacent exact numeric input in
meters, and consistent three-decimal precision. The sliders use the installed
four-district X/Z footprint and one district span for exploratory Y movement.
That range is only a presentation hint: finite exact values outside it remain
valid inputs to the concrete crate owner's existing typed validation.

A small transparent translate-only gizmo appears over the selected crate in
Free Camera. Its three projected world axes are the only colored axes on the
selection and update the same draft as the numeric controls. The gizmo receives
no authoring request sink, so dragging or releasing it is structurally
incapable of moving authority or saving. Only **Apply Position** emits the
existing revisioned relocate request with the crate's current rotation and
zero-velocity policy.

Selection, draft state, transaction state, the last correlated result, and
world-snapshot state remain at the top level. Transaction/history internals and
authored-change evidence are collapsed by default. Persistence uses the exact
term **Save World Snapshot** and identifies the fixed slot plus the configured
`--save-root` directory boundary.

## Ownership and transaction review

- The shared Phase 4 selection remains the only editor selection. The
  Inspector consumes it and does not add a private object picker.
- `AuthoringCrateView` gained immutable half extents and the closed
  `active_dynamic_box` status; it still exposes no Flecs entity, Jolt body,
  renderer handle, storage owner, or filesystem path.
- The game composition owns the concrete slider hint derived from its installed
  district policy. It is not a generic property range or engine CVar.
- Sliders, exact inputs, and gizmo motion all update one `State.position`
  draft. A dirty draft remains stable while ordinary crate physics continues.
- Revert is editor-local. Apply, undo, redo, and snapshot save remain explicit
  typed owner requests. No direct transform mutation path was added.
- A rejected or failed relocation preserves the dirty draft and typed result;
  an applied result clears it and resumes following the newly published pose.
- Snapshot saving is disabled during a dirty draft, an authoring transaction,
  or a persistence operation. The existing persistence owner still performs
  final quiescence validation and durable commit.

## Automated acceptance

The Phase 5-focused tests cover:

- clean draft following and dirty stability under natural physics;
- selection replacement and selection loss;
- correlated apply refresh and rejection preservation;
- shared slider/exact axis draft updates;
- non-finite draft rejection and finite exact values beyond slider hints;
- gizmo displacement updating only the local draft;
- independent gizmo drop acceptance proving no request is emitted until Apply,
  followed by exactly one relocate request with the draft pose, retained
  rotation, and zero-velocity policy;
- Escape cancellation restoring the complete position and dirty state retained
  at drag start without opening the system menu or requesting authority;
- exact gizmo-handle hit regions claiming the initiating mouse press before
  Free Camera world selection, while ordinary scene clicks remain unclaimed;
- one-shot Inspector reveal/focus on a new crate selection while respecting a
  manual close until the selection changes;
- camera projection and world-meter axis scaling;
- capture-scoped axis projection proving perspective redraw cannot reinterpret
  cumulative input and the handle remains coincident with the pointer;
- dirty/pending deferral of undo, redo, and world-snapshot save;
- alphabetical Panels ordering after the Inspector rename; and
- the inherited typed owner tests for revisioned apply, stale revision,
  owner-busy rejection, undo/redo, persistence, replay, and incident evidence.

Commands completed successfully:

```sh
zig build test-editor-gizmo -Deditor=true --summary all
zig build test -Deditor=true
zig build test -Deditor=false
zig build test-sandbox-developer-host -Deditor=true
zig build test-mouse-capture-macos -Deditor=true
zig build smoke-installed-s5-authoring-macos -Deditor=true
```

The editor-enabled aggregate also retains the architecture, source-package,
content-cohort, installed-product, headless-boundary, and native input gates.
The focused editor/developer-host root now links the real ImGui editor adapter
and runs its transitive tool tests. It completed **43/43 build steps and
125/125 tests**. The editor-enabled aggregate completed **305/305 steps and
1110/1110 tests**. The editor-disabled aggregate completed **302/302 steps and
1049/1051 tests**, with the editor-only pointer-claim and integrated Escape
workflow cases intentionally skipped.
The focused native input gate reported:

```text
MOUSE_CAPTURE_ACCEPTANCE_PASS first_click_consumed=true relative=true outside_scene_suppressed=true captured_click=true escape_release=true free_camera=true free_navigation=true free_look_escape=true selection_suppressed=true character_restore=true free_escape_menu=true menu_escape_resume=true menu_absent_escape_safe=true explicit_quit=true failures=0
```

## Native Metal validation

The installed S1 smoke completed on Apple Silicon macOS with the real Metal
renderer and the 14-tool ImGui editor. This proves the Inspector and transparent
gizmo compile, initialize, render over the existing product view, submit, and
tear down without changing the deterministic renderer or optional-editor
boundary.

```text
GPU Device created: metal
Editor initialized with 14 tools
S1_VISUAL_SMOKE_RESULT ready_frames=160 unavailable_frames=0 attempted_frames=160 character_frames=159 character_moved=true jump_observed=true ticks=124 alpha_min=0.000000 alpha_max=0.750000 virtual_render_hz=80 gpu_driver=metal
S1_VISUAL_SMOKE_SHUTDOWN status=clean
```

The installed S5 authoring smoke also passed after the pointer-routing repair,
covering editor initialization, revisioned edit, undo, redo, durable save,
Metal submission, and clean shutdown:

```text
S5_AUTHORING_SMOKE_RESULT rendered_frames=4 hidden_frames=1 edit_revision=1 undo_revision=2 redo_revision=3 save_status=committed save_sequence=2 gpu_driver=metal
S5_AUTHORING_SMOKE_SHUTDOWN status=clean
```

## Human-incident repair

Schema-5 anomaly `2026-08-23T04-54-51.955Z_solo_a1da265d` showed the crate
selection changing to `none` immediately after a direct gizmo-handle press.
The pointer event reached ImGui, but previous-frame backend capture did not yet
claim the same press, so Free Camera also queued it as a world-selection ray.
The ray began at the handle endpoint outside the crate bounds, missed, and
cleared the shared selection, Inspector, highlight, and gizmo.

The crate tool now retains only the three exact handle rectangles drawn in the
last completed editor frame. A left-button press inside one of those rectangles
is synchronously reserved by editor event routing before Free Camera can queue
world selection. ImGui still receives the event and remains the sole drag/draft
owner. Empty scene clicks, disabled/hidden Inspector state, Character mode, and
all other pointer input keep their existing routes. Handle claims are cleared
whenever the gizmo is not drawn, so no scene-sized or stale generic input
capture surface was added.

The original semantic replay continues to report the pre-existing
`tick=3255 category=npc` divergence, more than ten seconds after the UI flag.
That limits whole-cohort replay claims but is outside the anomaly window and is
unaffected by this editor-only repair.

The visual usability and no-occlusion checks were completed through the
product-owner gate below.

## Escape-routing repair

The original Phase 5 implementation had no capture-scoped cancel path. Raw
Escape bypassed the editor after Character mouse release and requested process
exit whenever the pointer was free. That made Free Camera manipulation unsafe
and made the older `free_escape_quit=true` acceptance label affirm the wrong
product behavior.

[ADR-030](../adr/030-editor-input-routing-and-interaction-capture.md) now fixes
the priority contract. A concrete gizmo drag owns Escape first and restores the
position plus dirty state retained at mouse-down. Free Camera RMB look and
Character SDL relative capture are the next owners. Only after all three
decline the event may the owned editor system menu open. An open menu consumes
Escape as Resume; process exit requires its explicit Quit request, main-window
close, or platform quit. The menu clears local held actions but does not pause
the fixed-tick simulation.

The dedicated validation record is
[Editor Input Routing and Escape](editor-interaction-routing-and-escape.md).

## Perspective drag-tracking repair

Human review found that a long red-axis drag became progressively more
sensitive and stopped tracking the mouse linearly. The gizmo was correctly
using the mouse-down position as its world-space origin, but it recomputed the
axis direction and pixels-per-meter conversion from the already-moving preview
on every frame. Under perspective, moving on X can also change camera depth,
so the same cumulative mouse delta was repeatedly divided by a changing scale.

The active drag now retains its mouse-down camera projection, world axis,
projected screen direction, and pointer origin. Every absolute pointer position
is projected back onto that fixed world axis. Redrawing still projects the
gizmo from the current draft position, so the visible handle follows the
pointer one-for-one even though world meters per screen pixel legitimately vary
with perspective. Drop, Escape, focus cleanup, selection invalidation, and mode
changes clear the retained mapping with the rest of gizmo capture state.

`test-editor-gizmo` includes an angled-camera regression: it proves the live
perspective scale changes after moving the crate, then proves the red handle
remains on the pointer after both a long drag and one additional pixel. It also
proves a completed drag rejects further pointer updates.

## Architecture, dead-code, and documentation review

- No generic property editor, reflection, CVar registry, universal scene
  mutation, compatibility authoring path, or direct backend access was added.
- The old `inputFloat3` editing surface and expanded scrolling audit layout are
  removed rather than retained beside the Inspector.
- The gizmo is a bounded transparent input window around its visible handles,
  not a scene-sized ImGui overlay; it cannot dim or replace product rendering.
- The persistent crate is still described as a runtime world instance, never
  as a reusable content asset.
- README terminology, the alphabetical Panels menu, root phase ledger, and this
  validation record now agree on **Inspector**, **Apply Position**, and **Save
  World Snapshot**.
- Phase 5 itself added no endpoint, CLI, or MCP path. After this phase was
  accepted, the product owner separately authorized EA0.5 endpoint/CLI work;
  Phase 7 MCP work has not started.

## Product-owner interaction acceptance

The product owner completed and accepted this workflow on 2026-08-29. The
checklist is retained as the reproducible human evidence target:

Start with an existing absolute save root:

```sh
mkdir -p /tmp/incinerator-saves
zig build run -Deditor=true -- --save-root=/tmp/incinerator-saves
```

Then verify:

1. Open **World Outliner**, switch to **Free Camera**, search for `crate`, and
   select **Crate** first from the Outliner and then by clicking it in the
   viewport. Confirm **Inspector** automatically opens and focuses. Close it,
   confirm it stays closed while the same selection remains active, then clear
   and reselect the crate and confirm it opens again.
2. Confirm the Inspector follows both selection paths and shows the same stable
   identity as the Outliner, concrete `crate / game_runtime` ownership,
   `available / authorable`, revision, authority position, fixed size, and
   `active_dynamic_box` read-only collider.
3. Confirm the yellow selection bounds remain visible and the small red,
   green, and blue translate gizmo appears over the selected crate without
   darkening, covering, or resizing the rendered scene.
4. Move each XYZ slider. Then type positive, negative, fractional, and values
   outside the slider range in the adjacent exact inputs. Confirm every edit
   updates one yellow **Unapplied draft** state and the game/physics continue.
5. Move the pointer rapidly from the Inspector or empty scene directly onto
   each gizmo arrow and press-drag without pausing over it first. Move one axis
   up, release, then immediately grab another axis and move it sideways.
   Confirm the Inspector, yellow selection bounds, and handles never disappear;
   the corresponding numeric field follows on the next frame. Make one long
   red-axis drag, then make several equally sized small mouse movements. Confirm
   each movement produces a consistent on-screen gizmo increment without
   acceleration or increasing separation from the pointer. Release and wait:
   the highlighted authority crate must not relocate merely because the gizmo
   was released.
6. Start from a clean draft, begin a gizmo drag, and press Escape before release.
   Confirm the original clean position returns, the menu does not open, and no
   authority result appears. Make an unrelated numeric edit, begin another
   drag, press Escape, and confirm the earlier dirty draft is restored exactly.
7. Press **Revert Draft**. Confirm fields return to the current live authority
   position and no authority result/revision change is produced.
8. Create another draft and press **Apply Position**. Confirm exactly one
   pending transaction appears, the crate moves once, velocity is stopped, the
   last result becomes `applied`, and the authoring revision advances.
9. Press **Undo**, then **Redo**. Confirm each is a separately correlated owner
   transaction and the crate returns to the expected position.
10. While a draft is dirty, confirm Undo, Redo, and **Save World Snapshot** are
   disabled. While a transaction is pending, confirm all conflicting actions
   are disabled. A focused stale-revision harness may be used to confirm a
   rejection leaves the draft recoverable.
11. With a clean applied position, press **Save World Snapshot**. Confirm the
    state reports committed slot `sandbox`. Exit, rerun with the same
    `--save-root`, and confirm the committed crate position restores.
12. Clear or change selection. Confirm the crate fields/gizmo clear and a newly
    selected crate would start from its own authority pose rather than inherit
    the discarded draft.
13. Toggle Character/Free Camera and exercise normal character capture, look,
    movement, firing, menus, panels, World Outliner selection, and free-camera
   RMB+WASD. Confirm the transparent gizmo neither captures unrelated scene
   input nor regresses the product rendering area.
14. While holding RMB in Free Camera, press Escape and confirm only fly/look
    ends. With no active interaction, press Escape and confirm the system menu
    opens without pausing gameplay. Press Escape to Resume, reopen the menu,
    and confirm only the explicit **Quit** button exits.

Phase 5 is closed. Its stop review satisfied the precondition for the
separately authorized EA0.5 schedule amendment; Phase 7 remains blocked until
EA0.5 itself is accepted.
