# Vehicle Lab single Apply

Vehicle Lab now presents one Apply button. It compares the admitted definition
with the draft using the existing reconfiguration classifier and submits one
typed apply or rebuild request. The authority still validates target, revisions,
layout, collision and drivetrain state. No CLI or replay protocol changed.

The panel explains the operation before submission and reports whether an
accepted change rebuilt physics. Rebuild is no longer a separate button.
Commit Admitted Car remains the explicit persistence action.

Interaction ownership is unchanged: the visible ImGui button owns press/release
and emits one request. Scalar drags remain draft edits; Escape restores the
active drag's starting value. Existing focus loss, panel closure and selection
cleanup remain in place. A pending transaction disables submission. A rejected
transaction retains the draft and reports the reason; it is not automatically
retried or silently forced through a rebuild.

Validation adds a renderer-free editor test for a steering-rate-only Apply and
a mixed rate/maximum-lock Apply. It checks one request, correct action, target,
both revisions and candidate values. The native queued-SDL/Metal journey now
uses Apply for both mass reconstruction and live torque, checking the selected
action and exactly one instance revision increment for reconstruction.

Commands:

```sh
zig build test-sandbox-developer-host test-vehicle-feature -Deditor=true --summary all
zig build test-editor-pointer-macos -Deditor=true --summary all
```

The first command passed 163/163 tests. The native command remains
unrun for this change: its existing acceptance creates and raises a visible
window and warps the mouse, conflicting with the requested background testing
workflow. No foreground test was launched. The stronger-steering experiment's
previously recorded handling failures are independent and remain unresolved.
