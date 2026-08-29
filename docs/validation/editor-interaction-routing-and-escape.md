# Editor Input Routing and Escape Validation

**Status:** Implementation and automated/native Metal validation complete;
product-owner interaction review pending

**Date:** 2026-08-29

**Decision:**
[ADR-030: Editor Input Routing and Interaction Capture](../adr/030-editor-input-routing-and-interaction-capture.md)

## Outcome

Editor input now follows one explicit priority resolver rather than treating
ImGui capture, viewport mode, gameplay pointer lock, and Escape as unrelated
booleans. The concrete event winner consumes the event. Completed-frame ImGui
capture remains useful, but a newly pressed gizmo handle is claimed from its
last-drawn bounded hit region before Free Camera can turn the same press into a
selection ray.

Escape is cancel/back, not process exit. Its implemented order is:

1. cancel an active crate gizmo and restore its retained start state;
2. cancel active Free Camera RMB look;
3. release Character SDL relative mouse capture;
4. close an open system menu; or
5. open the system menu.

The editor performs the gizmo/menu claims synchronously while processing the
same SDL event. The platform input owner performs Free Camera and Character
capture cleanup, then invokes the editor's bounded system-menu adapter only if
the higher owners declined. Once open, the menu immediately reports keyboard
and mouse capture, including before its first rendered frame. This prevents
later events in the same pump from leaking into gameplay.

The menu offers Resume and explicit Quit. It clears local held actions but does
not change simulation pause or authority. Main-window close and SDL platform
quit remain direct lifecycle events. Editor-disabled products have no ImGui
menu and consume otherwise-unowned Escape without converting it into quit;
their window/platform lifecycle remains the exit surface.

## Gizmo lifecycle and authority boundary

At mouse-down the crate gizmo retains the full position draft and its dirty
state. Motion edits only the shared local Inspector draft. Mouse release ends
capture and leaves that draft unapplied. Escape restores exactly the retained
draft: it does not discard numeric edits made before the current drag.

The Inspector and tests share one relocate-request constructor. A drag/drop
test proves its request mailbox remains empty through release. A separate Apply
step emits exactly one typed relocate request containing the selected persistent
ID, draft position, retained authority rotation, and zero-velocity policy.

## Automated acceptance layers

The layers remain independently runnable so a failure identifies its owner:

```sh
# Independently focused gizmo lifecycle and Escape ownership.
zig build test-editor-gizmo -Deditor=true --summary all
zig build test-editor-escape -Deditor=true --summary all

# Complete editor/tool state and routing, plus host adapter compilation.
zig build test-sandbox-developer-host -Deditor=true --summary all

# Full editor-enabled and editor-disabled closure.
zig build test -Deditor=true --summary all
zig build test -Deditor=false --summary all

# Real SDL window and queued mouse/key events.
zig build test-mouse-capture-macos -Deditor=true --summary all

# Installed deterministic renderer and typed S5 authority path.
zig build smoke-installed-s5-authoring-macos -Deditor=true --summary all
```

The focused tests assert:

- begin/update/drop edits only the local draft;
- drop emits no authoring request;
- Apply emits one exact relocate request;
- cancel restores position and clean/dirty state retained at begin;
- gizmo Escape is reserved before menu fallback;
- free-cursor Escape opens the menu and menu Escape resumes;
- Character capture Escape releases SDL relative mode;
- Free Camera look Escape ends RMB navigation without opening the menu;
- a composition with no menu surface consumes free Escape without quitting;
- none of those cancel/back paths quits; and
- an explicit lifecycle request does quit.

The native acceptance success label is intentionally
`free_escape_menu=true`, replacing the misleading historical
`free_escape_quit=true` label.

## Validation results

- Repository skill validation: `Skill is valid!`
- Independently filtered gizmo and Escape targets: **46/46 shared build steps;
  15/15 tests passed** — 9 gizmo tests and 6 Escape tests
- Focused editor/host: **43/43 steps; 124/124 tests passed**
- Editor-enabled aggregate: **305/305 steps; 1109/1109 tests passed**
- Editor-disabled aggregate: **302/302 steps; 1049/1051 tests passed**, with
  the editor-only pointer-claim and integrated Escape workflow cases skipped
- Native SDL: **7/7 steps**, zero mouse-lock failures
- Installed S5 Metal: **87/87 steps**, exact save verification and clean
  shutdown

```text
MOUSE_CAPTURE_ACCEPTANCE_PASS first_click_consumed=true relative=true outside_scene_suppressed=true captured_click=true escape_release=true free_camera=true free_navigation=true free_look_escape=true selection_suppressed=true character_restore=true free_escape_menu=true menu_escape_resume=true menu_absent_escape_safe=true explicit_quit=true failures=0
```

```text
GPU Device created: metal
Editor initialized with 14 tools
S5_AUTHORING_SMOKE_RESULT rendered_frames=4 hidden_frames=1 edit_revision=1 undo_revision=2 redo_revision=3 save_status=committed save_sequence=2 gpu_driver=metal
S5_AUTHORING_SMOKE_SHUTDOWN status=clean
S5_AUTHORING_SAVE_VERIFIED id=1:1 tick=11 payload=3467 envelope=3659 canonical=true editor_free=true
```

## Human checks that remain

Automation can prove ownership and state effects, but the product owner should
still confirm:

1. Gizmo motion feels continuous and numeric fields track it promptly.
2. Escape during a clean drag restores the live start pose with no menu flash.
3. Escape during a drag that began from an already dirty draft preserves that
   earlier draft exactly.
4. Free Camera RMB+WASD stops on Escape without selecting, firing, or opening
   the menu.
5. A subsequent free Escape opens a centered, legible menu over the still
   visible renderer; gameplay visibly continues.
6. Escape/Resume closes the menu and explicit Quit exits.
7. Character click-capture and first-Escape release remain unchanged.
