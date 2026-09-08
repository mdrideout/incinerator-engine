# EA2 Vehicle Authoring

Status: implemented; automated and native evidence is recorded in the
[EA2 validation ledger](../validation/ea2-vehicle-authoring.md). Human driving-feel
review continues through the delivered authoring workflow.

The next implementation slice is [EA2-H controls and handling profiles](ea2-handling-profiles.md):
Space handbrake, measured grip/locking correction, and FWD/RWD/AWD baselines.
Its handling acceptance is separate from the completed authoring infrastructure.

Authorized by the product owner on 2026-09-07. This is the next vertical slice
under [ADR-029](../adr/029-engine-game-authoring-boundary.md) and the
[Engine Authoring Foundation](engine-authoring-foundation.md#ea2--vehicle-archetypes-and-live-developer-control).
See [research and baseline findings](ea2-vehicle-dynamics-research.md).

## Outcome

A person or local agent can select a game-owned vehicle archetype, understand
its handling parameters, edit a draft, measure it, apply it to a selected car,
drive it, revert it, commit the asset and recover the same authored definition
after restart. Every runtime instance identifies the exact admitted definition
that controls its simulation and presentation.

The first product car is an original road sedan tuned toward weighty urban
driving: visible suspension motion, progressive loss of grip and recoverable
slides. The current front-wheel-drive configuration supplies a comparison.
A second distinct layout proves archetype ownership and client admission;
adding that proof follows the first working car.

## Execution order

Complete and verify each piece before expanding the next. No dates, vehicle
count ceilings, or new resource budgets are imposed by this plan.

| Order | Work item | Working result required before moving on |
|---|---|---|
| EA2-0 | Correct tire units and establish trustworthy measurements | Actual Jolt curve inspection proves radians-to-degrees conversion; original and corrected reports retained; scenario completion is explicit |
| EA2-1 | Game-owned archetypes and admitted runtime definitions | A car spawns from a versioned asset; identity and definition survive save/replay and reach client presentation; A-F029's default-layout assumption is removed |
| EA2-2 | Authority-owned edit and reconfiguration | Inspect, apply, revert and typed rejection work through the feature tick boundary; failed edits leave state/revisions unchanged |
| EA2-3 | Vehicle Lab and canonical CLI | UI and CLI complete the same draft/measure/apply/revert/commit journey, with field metadata and durable restart evidence |
| EA2-4 | Tune and compare the authored cars | The sedan meets the driving brief; another archetype proves distinct dimensions and response; complete metrics and native evidence explain the tradeoffs |
| EA2-5 | Product acceptance and closure | Solo/listen/dedicated authority tests, prediction, installed assets, editor-off/headless builds, native interaction, diagnostics and current docs agree |

## EA2-0: establish the measurement foundation

The existing adapter passes radian lateral-slip coordinates into a degree-based
Jolt curve. Correct only that conversion first. Add a real-adapter test that
reads the installed curve and verifies the authored peak and slide coordinates
and coefficients. A test of a standalone conversion helper is insufficient.

Retain the recorded pre-change report as historical evidence. Re-run exactly
the same scenarios after the correction and report every metric. Do not tune
unrelated values to make the old comparative assertions pass. If an assertion
encodes the former tuning objective rather than a safety/correctness invariant,
document why it changes and retain the comparison in the report.

Promote the existing characterization code into a reusable, renderer-free
measurement runner. It accepts an immutable definition and explicit scenario
specification and emits machine-readable results plus a readable comparison.
Record definition digest, physics/build cohort, input schedule, surface,
initial state, timestep and units. A scenario that fails to reach its requested
condition reports an incomplete/rejected result, not a valid stopping distance
or recovery time. Existing scenario lengths describe an experiment; they are
not job timeouts or engine limits.

Keep the existing flat rig for controlled comparisons. Add curbs and bumps as
dedicated vehicle fixtures with matching render/collision geometry. Their
dimensions follow the maneuver and car; the industrial world's footprint does
not constrain characterization. This does not require general map authoring.

## EA2-1: content and runtime identity

### Owners

| Owner | Responsibility |
|---|---|
| Engine physics contract and Jolt adapter | Four-wheel construction, explicit reconfiguration/state contracts, tire/suspension/drivetrain evaluation and measurements |
| Vehicle feature | Instance identity, admitted definition, revision, driver occupancy, input conditioning, tick-boundary edits and outcomes |
| Engine/tooling contracts | Typed field descriptions, immutable draft/inspection values, validation and authoring request/result shapes |
| Game content under `game/vehicles` | Named archetypes, handling values, chassis/wheel meshes, material bindings, attachment conventions and measurement profiles |
| Game composition and tooling | Asset loading, Vehicle Lab/CLI adapters, durable file writes, selection and incident projections |

No UI, endpoint thread or disk adapter owns a second copy of authoritative
physics state. Use the crate authoring path's asynchronous feature admission
and the material path's durable asset pattern; do not turn either into a
universal property bus.

### Versioned vehicle definition

Use a typed `VehicleArchetypeId` backed by the existing durable asset identity
contract. Store an explicit format version, stable ID, label, asset revision,
canonical digest and typed dependencies. Keep definition parsing/validation
available to the headless product.

The definition contains:

- Chassis collision dimensions, mass, center-of-mass offset and explicit mass
  properties needed by the physical car.
- Four named wheel attachment transforms and wheel dimensions, preserving the
  existing +Y up, -Z forward, +X right convention.
- Front/rear axle suspension travel, spring frequency, damping and anti-roll
  settings; front/rear tire response and service-brake distribution.
- Engine torque/RPM/inertia values and the torque curve, automatic transmission
  ratios/timing, front/rear drive distribution and differential behavior.
- Steering lock, input rise/return behavior and speed response. Stateful input
  conditioning belongs to authority and is saved/replayed with the instance.
- Explicit stabilization settings. The pitch/roll limiter must be shown as an
  assist, with an unassisted setting available for characterization.
- Chassis and wheel visual asset references, material slots and visual origin/
  attachment transforms. Rendering resolves these from cooked content.

Represent variable-length curves and gear ratios using authored counts and
owned storage, not new fixture-sized arrays. Validate finite values, units,
ordered curve coordinates, usable gear ranges, layout and dependency kinds.
An authoring control's preferred range cannot silently become a schema cap.
PBR roughness and metallic values remain visual properties; tire grip is an
explicit physics value.

Do not use Jolt's implicit engine/gearbox defaults as the game definition.
Populate the backend from the admitted values. The Jolt dependency remains
pinned during this phase.

### Runtime application semantics

Separate the reusable archetype asset from a car instance. Each instance stores
its admitted archetype ID, revision, full simulation definition/digest and visual
binding identity. Spawning requires an explicit resolvable definition.

The default authoring workflow applies a candidate to the **selected instance**.
Other cars retain the definitions under which they were admitted. Committing
the reusable asset affects future spawns; it does not silently retune the fleet.
The lab displays the selected instance's revision alongside the asset revision.
This provides a direct comparison workflow and makes the scope of an edit clear.

Saving a world preserves the actual admitted definitions of its instances,
including uncommitted session tuning. Asset commit independently writes the
canonical game definition. Restore must not resolve an old save against whatever
the latest source file happens to contain. Deduplicate saved definitions only
where that is needed by the concrete representation; preserve exact identity
and value ownership first.

Clients must admit a matching definition before using its layout or presenting
its instances. Carry ID, revision and digest in the appropriate session state;
distribute immutable definition data through the existing reliable admission
path. A missing/mismatched definition requests the existing recovery path or
rejects explicitly. There is no default-layout substitution.

Update the disposable client predictor for the admitted response data and clear
obsolete prediction history when a definition changes. It remains a presentation
estimate; do not replace it with a second authoritative simulation. Measure
correction error for the authored cars before adding more prediction complexity.

## EA2-2: transactions and safe reconfiguration

Every edit carries producer/run identity, stable target, expected instance and
asset revisions, typed candidate value and transaction ID. Admission identifies
the pending operation; only the feature's tick result establishes success.
Inspection after completion must agree with the outcome.

Field metadata has three effect classes:

| Class | Examples | Rule |
|---|---|---|
| Presentation | Chassis/wheel material or compatible visual assignment | Draft preview is disposable; committed assignment retains exact asset dependencies |
| Live-safe authority | Input response; backend-supported engine/differential coefficients | Apply at the fixed tick; preserve current vehicle and driver state; expose only operations the adapter can perform safely |
| Rebuild required | Chassis mass/shape/COM, wheel layout, suspension or tire settings requiring immutable wheel reconstruction, gearbox topology | Explicit rebuild transaction with compatibility checks; do not masquerade as an in-place setter |

The pinned C wrapper's setters on *construction settings* are not evidence that
the same settings may be modified on a live wheel. Jolt keeps wheel settings
through a const reference. If live engine/differential updates require a missing
C binding, add a narrow typed adapter bridge to the supported C++ operation;
do not cast away const or expose a generic native mutation capability.

For rebuilds, preflight the candidate, its asset dependencies, the proposed
collision shape and the compatibility of current drivetrain state. Preserve
stable identity, chassis pose and velocities, occupancy, wheel motion and
supported powertrain/control state only when the adapter proves the transition.
An incompatible occupied, colliding or shifting state returns a specific
rejection with its reason. It must not silently eject the driver, reset velocity,
select another gear or move the vehicle to a new spawn.

Keep the old vehicle and revisions valid until the candidate can be published.
Reject allocation, validation and transition failures without a partial apply.
Reconfiguration state must distinguish authored values, logical motion and
backend contact/solver caches. Do not replay an opaque backend snapshot into a
different configuration and call that a safe rebuild.

Revert applies the saved definition through the same checks and creates a new
session revision. Undo/redo, where exposed, are exact owner transactions in the
current revision lineage; they do not rewind simulated motion. Durable commit
atomically writes only the requested archetype. Failed writes leave committed
asset values/revisions unchanged.

## EA2-3: Vehicle Lab, CLI and measurements

The lab presents the selected instance and its source archetype, revision/dirty
state, an editable draft, the affected-field classification, and pending/terminal
outcomes. Organize fields into chassis/layout, suspension, tires/brakes,
drivetrain, steering, assists and visuals. Show units, descriptions, current/
saved/candidate values and typed failures. Curve plots come from the same
canonical values used by physics.

Provide the complete journey: inspect, edit draft, preview compatible visuals,
measure candidate, apply to instance, explicit rebuild when required, revert,
commit archetype and inspect again. A slider drag updates the draft; it does not
stream physics mutations every rendered frame. A visual preview cannot imply
that the candidate handling is active.

The existing CLI gains manually registered vehicle operations and typed schema
metadata for that same journey. Exact syntax belongs in the executable catalog.
Preserve bootstrap/run guards, target discovery, optimistic revisions, terminal
polling and producer-specific results. Local editor/developer products submit to
their local authority. Remote-player clients gain no multiplayer administration
capability. Dedicated authority behavior is exercised through explicit validation
composition and the same feature commands.

Measurements run against an immutable candidate in an isolated headless physics
process using the matching build cohort. The canonical CLI/authoring host owns
the named measurement admission and result; the worker is a measurement product,
not another mutation endpoint. It never drives the player's current world,
blocks the render thread, accepts shell text or invents a completion timeout.
Retain the exact scenario input and output alongside the candidate digest.

Read the editor-interaction skill and ADR-030 before UI implementation. Model
press, drag, release, Escape and focus loss for every control. Keep simulation
pause independent of editor interaction. Dirty drafts survive unrelated
inspection, stale drafts reject, and a pending authority edit cannot be reported
as a completed slider change.

## EA2-4: handling characterization and tuning

Tune the corrected model in this order: proportions and mass properties,
suspension/anti-roll, tire curves and axle balance, drivetrain/brakes, steering
response, then any explicitly chosen assists. Compare the full results after
each change; avoid optimizing one metric invisibly.

| Driving question | Scenario | Evidence |
|---|---|---|
| Does the car accelerate and shift consistently? | Straight acceleration and lift-off | Speed/time, RPM, gear, longitudinal acceleration, pitch and axle travel |
| Are brakes useful and believable? | Matched-speed straight braking | Entry speed, distance/time, wheel slip, contact and front/rear load |
| Can the player read cornering balance? | Both-direction constant-radius turns and speed sweeps | Lateral acceleration, yaw rate, chassis sideslip, per-tire slip, roll and wheel loads |
| Does braking alter the corner predictably? | Braking/lift-off during a matched turn | Path deviation, available cornering response, axle saturation and recovery |
| Are transients progressive? | Steering step and alternating slalom | Raw/conditioned steer, yaw response, roll response and oscillation decay |
| Can a slide be recovered? | Throttle and handbrake breakaway followed by a defined recovery input | Slip development, recovery time/distance, spin and contact loss |
| Does suspension work beyond a flat pad? | Bump, curb and asymmetric wheel contact | Compression/rebound, bottoming, contact loss and chassis motion |
| Can the car genuinely roll? | Severe turn/obstacle with assist state declared | Wheel lift, tilt, rollover and the exact assist configuration |
| Does authoring preserve continuity? | Edit under motion, braking, cornering and a shift | Accepted/rejected transition, pose/velocity/occupancy continuity and exact revisions |

Use a useful spread of authored entry speeds and inputs; record their actual
values rather than inventing universal pass bands before measurement. Retain
existing engineering limits only where required by a physical or backend
contract. Baseline repeats establish numerical comparison tolerance.

Telemetry distinguishes chassis sideslip from individual tire slip and reports
contact validity. Wheel suspension impulses divided by the known physics
timestep can provide solver-derived load estimates, labelled as estimates.
The existing read-only wheel impulse API should be used before inventing a new
tire-force model.

Run the native driving journey after objective checks pass. Evaluate the
sedan's dive, squat, roll, corner entry and recovery in the industrial streets.
Compare the driving camera with a fixed/free view to separate camera motion
from physical motion. Change camera behavior only if the drive reveals a
specific vehicle-feel defect; authoring is the priority. Human evaluation owns
the final judgment of feel, while automated/native evidence owns transaction
correctness and reproducibility.

## EA2-5: acceptance and affected components

| Area | Concrete implementation targets | Required proof |
|---|---|---|
| Definition and content | Vehicle contract, new versioned vehicle asset reader/writer, `game/vehicles`, cook/install composition | Stable identities, dependency validation, deterministic digest, relocation and editor-disabled loading |
| Physics/feature | `src/engine/contracts/physics.zig`, `src/physics.zig`, `src/features/vehicle/{contract,root}.zig` | Correct units, per-instance definitions, real-Jolt behavior, safe apply/rebuild and failure atomicity |
| Save/replay | `src/hosts/simulation_snapshot.zig`, `sandbox_replay.zig`, snapshot/save codecs and feature logical digest | Exact admitted definition, input state and edit ingress; reject old incompatible cohorts explicitly |
| Network/presentation | Session protocol/authority/client, `replicated_world.zig`, `vehicle_prediction.zig`, `client_scene.zig`, solo rendering | Two distinct layouts; admission before use; no hardcoded car fallback; revision-aware prediction and draw identity |
| Authoring | Typed vehicle authoring contract/owner, composition adapter, Vehicle Lab, existing developer endpoint/CLI | UI and CLI agree on admission, revisions, rejection, revert, commit and measurement results |
| Diagnostics | Feature inspection, measurement report and incident projections | Producer/transaction/tick/frame correlation; archetype/value/visual digests and actual applied state |
| Packaging | `build.zig`, ownership/source-package gates and install manifests | Game, editor-game, headless authority and validation tools resolve the same authored definitions |

Advance every affected schema/cohort together when its meaning changes; update
handwritten encoders, decoders, hashes, golden fixtures and architecture checks.
The existing simulation source fingerprint also changes for the tire-unit fix.
Do not retain compatibility decoders or a hidden default archetype for old data.

Required checks include real physics and vehicle feature tests, measurement
tests, save/replay and malformed/mismatched definition admission, simultaneous
different archetypes, stale edits from UI/CLI, commit failure/restart, native
press/drag/release/cancel, and solo/listen/dedicated authority placement. Run the
native pointer suite separately from other macOS window tests. Finish with the
editor aggregate, editor-off/headless builds, installed native Metal journey and
source-package gate.

For driving-affecting authoring, record the accepted command and exact definition
in replay ingress. Incident evidence must identify any edit that changed the
vehicle. Asset commits alone do not substitute for replayable authority input.
Large typed evidence uses an owned full artifact plus correlation if the existing
inline recorder cannot hold it; do not silently drop or truncate vehicle values.

## Completion checklist

- [x] Research primary developer sources and inspect the pinned backend.
- [x] Reproduce and preserve the current measurement baseline.
- [x] Record the handling target, ownership, transaction semantics and ordered plan.
- [x] Correct the lateral-curve unit defect and verify a new baseline.
- [x] Admit game-owned vehicle definitions through all runtime placements.
- [x] Implement authority reconfiguration, durable authoring and shared UI/CLI.
- [x] Complete candidate measurement and authored sedan tuning.
- [x] Prove distinct archetypes, native interaction/driving, restart and diagnostics.
- [x] Complete the product gates and update the validation ledger.

EA3 lighting, EA4 general map tools and EA5 separate packaging retain their later
roadmap ownership. Vehicle damage/deformation, traffic, broad controller support
and a replacement tire solver require their own demonstrated need. Neural
rendering remains paused.
