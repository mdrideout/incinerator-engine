# Open-World Spatial Diagnostics and Playability Correction

**Status:** Complete
**Platform:** Apple Silicon macOS
**Governing decision:** [ADR-022](../adr/022-open-world-spatial-objects-and-handling-characterization.md)

## Human-test findings addressed

- Drop rejection outside the two authored districts came from a false
  residency policy, not an invalid position.
- “District ownership” was ambiguous because it mixed streamed content
  residency with feature-owned dynamic-object lifetime.
- NPC displacement could look stuck without exposing its current destination
  or progress, encouraging false exception handling.
- The default 1280×720 window, camera distance, and clustered spawn placement
  made the sandbox harder to read.
- Vehicle friction and stability lacked repeatable measurements.

## Implemented product changes

- Default window: 1600×900.
- Character camera: 9 m follow distance; vehicle camera: 12 m.
- Default character: `(-5, 0, 5)`.
- Default vehicle: `(-1, 2, -3)`.
- Default carryable: `(-1, 0.5, 6)`.
- Initial NPC: west navigation node 2 `(7, 0, 3)`, patrolling to west node 0
  `(-4, 0, 3)`. Both endpoints are valid in the initially resident cohort.
- Carryable world lifetime is independent of district residency.
- Physics bounds visualization includes active district cell outlines and
  centers. Existing NPC route/perception overlays now include the immediate
  navigation target; red means potentially stalled.
- Gameplay Inspector and incident state streams expose NPC navigation status,
  target, no-progress ticks, and last-progress tick.
- Vehicle dynamics use explicit tire curves and the automated report in
  [vehicle-dynamics.md](../validation/vehicle-dynamics.md).

## Diagnostic interpretation

District `(0,0)` owns the half-open coordinate `[-8,8)` on X/Z for indexing;
district `(1,0)` owns `[8,24)` on X. An active outline means its cooked
collision/navigation/presentation cohort is resident. It does not mean an
object outside the outline is invalid.

NPC navigation is destination based over the currently cooked graph. A pushed
NPC retains its semantic goal and rebuilds/rebases route intent as ownership
changes. `potentially_stalled` only means it had an active target and moved
less than 2 mm horizontally for 120 consecutive authority ticks. External
motion counts as progress; waiting for inactive content and dormancy are
separate states.

## Acceptance

- Interaction unit regression drops at `(40,0,40)` and retains one live body.
- S7 real-Jolt/headless and installed smoke semantics prove a spatial object
  survives district unload and restore without hiding or body suspension.
- NPC progress has a pure 120-tick non-fatal threshold regression.
- Physics debug extraction includes active district bounds plus NPC target and
  existing route/perception geometry.
- Vehicle dynamics gates and full editor-enabled test graph pass.

