# ADR-030: Editor Input Routing and Interaction Capture

**Status:** Accepted

**Date:** 2026-08-29

**Platform:** Apple Silicon macOS only

**Related plan:**
[Editor Interaction and Agent Control](../../EDITOR_INTERACTION_AND_AGENT_CONTROL_PLAN.md)

## Context

The structured editor, explicit Character/Free Camera modes, shared selection,
World Outliner, Inspector, and crate gizmo established the right high-level
owners. Human review nevertheless exposed three recurring integration errors:

1. A transparent full-size ImGui Scene Viewport still caused its dock host to
   paint over the renderer and made central input ownership unreliable.
2. A gizmo-handle press was sent to ImGui, but previous-frame capture did not
   yet claim it; the same press also became a Free Camera selection miss and
   cleared the selected crate.
3. Escape was special-cased in the platform input pump: it released captured
   Character mouse input but otherwise requested immediate process exit. An
   active editor interaction or Free Camera therefore could not consume Escape
   as cancel/back.

The old native acceptance even labeled `free_escape_quit=true` as a success.
That proved the implementation was stable, not that the behavior was correct.
Input correctness requires an explicit interaction lifecycle and priority
contract rather than independent capture booleans interpreted after the fact.

## Decision

### Independent state axes

The visual host keeps these concerns independent:

| Concern | Examples | Effect |
|---|---|---|
| Viewport mode | Character, Free Camera | Camera and gameplay/editor routing |
| Gameplay pointer lock | captured, released | SDL relative mouse ownership |
| Active interaction | none, gizmo drag, Free Camera look | Exclusive transient event stream |
| System menu | closed, open | Local input/modal presentation |
| Simulation state | running, paused | Fixed-tick advancement |
| Diagnostic recording | recording, frozen | Evidence collection only |
| Selection | none, stable semantic identity | Outliner/Inspector/viewport correlation |
| Authoring | clean, draft, pending transaction | Preview and typed authority mutation |

No transition in one axis silently changes another unless a named composition
rule says so. Free Camera does not imply pause or authoring authority. Opening
the system menu clears local held actions but does not claim multiplayer or
authority pause semantics.

### Event routing

SDL remains the physical input owner. Every event is first forwarded to the
owned optional editor adapter, then resolved in priority order:

1. application/OS lifecycle events that cannot be suppressed;
2. an already active modal interaction;
3. an already active pointer or text capture;
4. visible editor UI under the concrete event position;
5. viewport interaction for the published scene rectangle and current mode;
6. gameplay input; and
7. application fallback.

The first semantic owner consumes the event. Lower layers cannot also act.
ImGui `WantCaptureKeyboard` and `WantCaptureMouse` remain useful completed-frame
state, but are not sufficient to arbitrate a new press delivered before the
next ImGui frame. Tools with projected handles retain only their exact
last-drawn hit regions so the event pump can make a synchronous bounded claim.

### Capture lifecycle

One transient interaction owns a device/event stream at a time. Capture has
explicit begin, update, complete, cancel, and forced-end behavior:

- begin retains the values needed to restore the interaction start;
- update changes only the interaction's preview/draft or declared live session;
- pointer release completes exactly once;
- Escape cancels and restores the interaction start;
- focus loss, minimization, hidden/closed tooling, invalidated selection, or
  incompatible viewport-mode change forcibly ends capture; and
- physical keys/buttons held across a routing transition stay suppressed until
  their matching release.

This is a fixed priority resolver with one explicit active interaction, not a
generic stack of callbacks. A future nested tool may add a closed nested state
only after a real workflow demonstrates the need.

For the crate gizmo, cancel restores the complete draft position and dirty
state retained at mouse-down. It does not discard edits made before that drag.
The camera projection, world axis, projected screen direction, and pointer
origin are also retained at mouse-down. Each absolute pointer position is
projected back onto that fixed world axis; a cumulative pointer delta is never
reinterpreted using a scale derived from the already-moving preview. Drop ends
gizmo capture. Under the current Phase 5 contract it leaves an unapplied draft;
`Apply Position` emits exactly one revisioned typed relocation request. A later
accepted live-transform phase may commit on drop, but must still use one
capture-scoped transaction and one Undo record.

### Escape and application lifecycle

Escape is the semantic cancel/back action:

1. cancel an active gizmo or other modal edit;
2. end active Free Camera RMB look;
3. release Character gameplay mouse capture;
4. close an open system menu; or
5. open the system menu.

Each accepted action consumes the key. Escape never directly requests process
exit. The application exits only after an explicit system-menu Quit request,
main-window close, or platform quit event. The graphical developer host owns
the optional editor menu presentation through its owned `Editor`; the
application host remains the only owner that converts a typed quit request into
process lifecycle state.

The system menu captures local input and clears latched gameplay actions. It
does not automatically pause authority. Solo pause and network menu behavior
remain separate product decisions.

### Renderer composition

The deterministic renderer owns the central scene. The passthrough central dock
node stays empty. ImGui may draw bounded toolbars, gizmos, menus, and status
surfaces whose input rectangles match their visible affordances; it may not
install a transparent full-scene window or dock host over the product view.

### Automated acceptance

Every changed interaction supplies the applicable independent gates:

- pure begin/update/drop/cancel state tests;
- editor/viewport/gameplay fallthrough tests;
- native SDL queued-event acceptance for capture and Escape priority;
- typed request/authority tests proving exact transaction and revision counts;
- installed Metal smoke proving normal scene submission and clean teardown; and
- negative assertions for selection loss, gameplay leakage, accidental quit,
  duplicate transaction, stale held input, and scene occlusion.

Acceptance labels describe intended behavior. When product intent changes, the
old label is replaced rather than retained as a misleading compatibility claim.

## Consequences

- Active tools can cancel reliably without application fallback firing.
- UI, viewport, gameplay, and lifecycle actions cannot all observe one event.
- Conventional cancel/menu behavior does not require a generic input framework.
- The editor-disabled composition retains the same physical input boundary and
  explicit main-window/platform quit behavior without importing ImGui.
- Some subjective interaction qualities still require human review, but event
  ownership, cancellation, authority effects, and process lifecycle are
  deterministic automated claims.

## References

- [ADR-003: Editor Architecture and Tool System](003-editor-architecture.md)
- [ADR-029: Engine, Game, and Authoring Ownership Boundary](029-engine-game-authoring-boundary.md)
- [Phase 3 viewport-mode validation](../validation/editor-interaction-phase-3-viewport-modes.md)
- [Phase 5 crate Inspector validation](../validation/editor-interaction-phase-5-crate-inspector.md)
- [Incinerator editor-interaction skill](../../skills/incinerator-editor-interaction/SKILL.md)
