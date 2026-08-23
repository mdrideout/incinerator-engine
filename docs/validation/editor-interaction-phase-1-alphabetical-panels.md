# Editor Interaction Phase 1: Alphabetical Panels Validation

**Status:** Accepted

**Date:** 2026-08-22

**Plan:**
[Editor Interaction and Agent Control Plan](../../EDITOR_INTERACTION_AND_AGENT_CONTROL_PLAN.md)

## Scope

Phase 1 changes only the presentation order of the editor's Panels menu.
It deliberately preserves:

- stable `ToolId` values;
- the statically registered tool cohort;
- registry order;
- default dock/tab construction;
- layout masks and presets;
- startup panel IDs and focus;
- panel enabled state and toggle behavior; and
- panel purpose tooltips.

No combat, camera, input, selection, authoring, asset, endpoint, CLI, or MCP
behavior is part of this phase.

## Implementation evidence

`src/editor/editor.zig` now contains an explicit alphabetical
`panel_menu_order` used only while drawing the Panels menu. Each ordered
`ToolId` resolves back to the corresponding tool in the unchanged editor-owned
registry.

The displayed order is:

1. Camera
2. Crate Authoring
3. Diagnostics
4. Event Log
5. Gameplay Inspector
6. Incident Capture
7. Interaction
8. Navigation Lab
9. Neural Input / Output
10. Physics Debug & Profiler
11. Population Lab
12. Render Lab
13. Stats

The editor aggregate includes an exhaustive test proving that the menu contains
every registered tool exactly once and that adjacent display names are strictly
alphabetical. Adding or removing a registered tool without updating the menu
order fails the test.

## Architecture, dead-code, and documentation review

- The implementation remains inside the graphical editor owner.
- No new imports, backend access, allocation, runtime discovery, or generic
  registration mechanism was introduced.
- Dock construction still iterates `default_tools` in its original order.
- Panel toggle and focus behavior still operate on the registered `Tool` value.
- The earlier registry uniqueness/completeness test remains in force.
- No compatibility path or superseded menu renderer remains.
- The root plan records implementation and product-owner acceptance.

## Automated evidence

Focused ED1 contract gate:

```sh
zig build test-editor-workspace test-sandbox-invocation -Deditor=true --summary all
```

Result: `7/7` steps and `7/7` focused tests passed.

Full editor-enabled aggregate:

```sh
zig build test -Deditor=true -j1 --summary all
```

Result: `305/305` steps and `1022/1022` tests passed. This aggregate compiles
and executes the graphical editor tests, including the new exhaustive Panels
menu order test. The installed validation product reported canonical cooked
content, MSL shaders, Metal GPU driver, and `editor: true`.

Full editor-disabled aggregate:

```sh
zig build test -Deditor=false -j1 --summary all
```

Result: `302/302` steps and `1022/1022` tests passed. The installed validation
product reported canonical cooked content, MSL shaders, Metal GPU driver, and
`editor: false`; headless and product/validation binary boundaries passed.

## Accepted native product-owner review

1. Launch the normal native editor-enabled product.
2. Open `Panels` and verify the exact alphabetical list recorded above.
3. Hover several entries and verify each tooltip still identifies the correct
   stable ID and purpose.
4. Toggle every panel off and back on. Verify the correct panel opens and gains
   focus when enabled.
5. Reapply Gameplay, Navigation, Population, Rendering, Incident, Minimal, and
   All workspace layouts. Verify panel placement and tab order did not change.
6. Verify Neural Input / Output remains available in the menu but is not
   silently enabled by layouts that intentionally exclude the paused panel.
7. Resize the native window and verify the menu remains usable and the current
   top status strip, docks, bottom panels, and status footer do not regress.

The product owner accepted this review on 2026-08-22 and authorized Phase 2.
No corrective work was requested.
