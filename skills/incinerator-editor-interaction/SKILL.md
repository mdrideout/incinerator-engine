---
name: incinerator-editor-interaction
description: Design, implement, review, and validate Incinerator Engine editor interaction involving SDL input routing, ImGui capture, viewport modes, selection, gizmos, shortcuts, system menus, or renderer overlays. Use when changing how a human press, drag, release, cancel, focus transition, or UI action crosses editor, viewport, gameplay, and application owners.
---

# Incinerator Editor Interaction

Read [ADR-030](../../docs/adr/030-editor-input-routing-and-interaction-capture.md)
and the validation record for the affected phase before changing code. When a
reported symptom has an incident folder, also use the incident-diagnostics
skill; do not substitute this workflow for evidence reduction.

## Model the interaction before implementation

Write the concrete sequence from physical input through completion. Identify:

- the visible target and its exact hit region;
- the owner that may begin capture;
- state retained at capture start;
- update, release, Escape, focus-loss, mode-change, selection-loss, and
  panel-closure behavior;
- whether the result is presentation preview, session authority, or durable
  persistence; and
- the lower-priority actions that must not also observe the event.

Keep viewport mode, gameplay mouse lock, active interaction capture,
simulation pause, diagnostic recording, selection, and authoring transaction
state independent. Do not add another boolean that implicitly combines them.
When a named composition hides an interaction surface, preserve any state that
is meant to persist but remove every projected half together: renderer
decoration, ImGui affordance, and retained hit region. A later mode transition
must reproject from current semantic state rather than revive last-frame input
geometry.

## Route by current ownership

- Forward the raw event to ImGui, but do not use previous-frame
  `WantCapture*` as the sole decision for a new press.
- Resolve concrete synchronous claims before viewport picking, gameplay, or
  application fallback. Visible hit geometry and input geometry must agree.
- Once acquired, one interaction exclusively owns its event stream until
  release, cancel, or forced cleanup. Preserve enough start state to cancel
  exactly that interaction without discarding earlier edits.
- Treat Escape as a semantic cancel/back action. Offer it to the active
  interaction, active pointer capture, and open menu before opening the system
  menu. Never bind raw free-cursor Escape directly to process exit.
- Quit only through an explicit menu request, main-window close, or platform
  quit event. Optional editor code may request quit but may not own application
  lifecycle or call SDL directly.
- Focus loss and minimization forcibly end transient captures and clear held
  input. A captured physical hold stays suppressed until its matching release.

Prefer one explicit active-interaction state plus a fixed priority resolver.
Do not introduce a generic callback stack unless real nested interactions prove
that the closed routing states are insufficient.

## Preserve the renderer and conventional workflow

The central scene is renderer-owned. Keep the passthrough dock node empty; use
only bounded overlays whose visible affordances match their hit regions. Do
not place a transparent full-scene ImGui window over the product renderer.

Use conventional editor semantics before exposing backend terminology:

- World Outliner selects live instances.
- Content Browser selects reusable assets.
- Inspector follows the applicable selection and respects manual closure.
- Selection highlight, manipulators, and diagnostics have distinct visuals.
- Semantic selection may persist outside an editable viewport mode, but
  selection bounds and manipulators appear only when the shared editor-world
  affordance policy permits both.
- A live manipulation may preview continuously while still producing one
  bounded typed transaction and one undo record.

Do not let transaction safety force a control-panel-style workflow when a
disposable preview or capture-scoped transaction preserves the same ownership.

## Validate the complete path

Add the smallest applicable layers, keeping them independently runnable:

1. Pure state tests for begin/update/release/cancel and retained start state.
2. Editor/input routing tests proving the winning owner consumes the event and
   lower owners do not act.
3. Native SDL acceptance using real queued key, mouse, focus, and window
   events.
4. Installed Metal smoke proving the interaction coexists with the rendered
   scene and typed authority result.

Name acceptance output after intended product behavior. Include negative
assertions for selection clearing, gameplay action leakage, duplicate
transactions, accidental quit, stale held input, and renderer occlusion. Do
not preserve a behavior merely because an older test called it successful.

Human review remains appropriate for legibility, target size, responsiveness,
and visual feel. It is not a substitute for deterministic routing,
cancellation, transaction, and lifecycle tests.

## Handoff

Report the interaction sequence, ownership winner, cleanup paths, focused and
native commands, Metal result, and remaining subjective checks. Update control
help, the phase validation record, and any acceptance label whose meaning
changed.
