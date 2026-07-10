# ADR-005: Physics-ECS Integration Strategy

## Status

Accepted, amended 2026-07-09

## Context

The engine uses Flecs for entity and logical world state and Jolt Physics 5.5.0 through an engine-owned JoltC adapter for rigid-body simulation. The boundary must answer three different questions without conflating them:

1. Which system owns a transform at each point in a simulation tick?
2. Which data may rendering and gameplay consume?
3. Which identifiers and state may cross persistence or future network boundaries?

The former integration was described in terms of `zphysics` and claimed that ECS was always the single transform authority. That is incompatible with dynamic simulation: Jolt necessarily owns a dynamic body's simulated pose while it steps.

## Decision

### Narrow engine physics types

ECS, gameplay, editor, and rendering code depend on engine-owned physics types
and capabilities, not JoltC declarations. New feature slices use the
compile-time `Bodies` contract; the crate feature stores the capability's
opaque handle in a feature-private runtime component. The concrete Jolt
adapter's handle is `physics.BodyId`:

```zig
pub const RuntimeBody = struct { handle: Bodies.Handle };
// In the Jolt composition: Bodies.Handle == physics.BodyId
```

`physics.BodyId` is a narrow process-local handle containing an adapter-issued,
monotonic world token, an engine-issued 64-bit body serial, and Jolt's raw body
value. Every adapter operation validates the world token and the live
serial-to-raw mapping before entering Jolt. This prevents handles from another
or recreated physics world from aliasing a live body and prevents Jolt's finite
native generation field from reviving a stale handle after repeated slot reuse.
It must not be serialized, used as a persistent entity identity, or exposed as
a future network identity. The Jolt C import and ABI details remain private to
the physics adapter.

### Runtime and thread lifetime

JoltC initialization is process-global and not reference-counted. The adapter
therefore owns a runtime lease count: the first `Physics` world calls
`JPH_Init`, and only the final world calls `JPH_Shutdown`. Per-world systems,
allocators, filters, and jobs remain independently owned and transactionally
unwind on initialization failure.

Physics world lifecycle and adapter calls are confined to the thread that
created the first runtime lease. Jolt worlds can coexist on that thread, but
the current zflecs-backed simulation composition permits only one live owned
ECS world per process. Concurrent world mutation/lifecycle is deliberately
unsupported. This matches ADR-008's main-thread simulation ownership until a
real worker-facing command boundary is designed.

### Transform authority is explicit by body mode

| Body mode | Authority | Direction at the boundary |
|---|---|---|
| Dynamic | Jolt during simulation | Jolt body pose -> physics sync -> ECS logical transform |
| Kinematic | Gameplay/ECS intent | Command boundary -> Jolt; simulated result may then be published to ECS |
| Static | Authored/gameplay state | Creation or explicit command -> Jolt; no per-frame write-back is required unless queried |

For dynamic bodies the implemented fixed tick order is:

```text
commands -> pre-physics inputs -> step Jolt -> publish post-physics state
```

The S0 sandbox exposes only typed crate commands and immutable queries; it does
not expose immediate adapter setters. Kinematic/static intent remains deferred
until a feature defines its command and synchronization policy. Low-level
adapter mutators are internal implementation/test seams, not a cross-feature API.

Current adapter getters and mutators are checked error unions. Invalid/foreign
handles and non-finite transforms, velocities, forces, rotations, or time steps
do not silently cross the boundary. Physics-step capacity failures propagate
before ECS publication or completed-tick accounting.

Rendering never queries Jolt directly. It consumes presentation data derived from ECS so the renderer remains independent of the physics backend and future server/headless hosts do not acquire graphics dependencies.

ECS remains authoritative for entity identity, component composition, gameplay state, persistence inputs, and the logical transform published after a step. This does not make ECS authoritative for a dynamic body's in-progress simulated pose.

### Coordinate and rotation contract

The sync reads Jolt's body position intentionally, rather than substituting center-of-mass coordinates. Collider offsets and future compound shapes must preserve the distinction between entity/body origin and center of mass.

Rotation is stored as a normalized quaternion in ECS using `(x, y, z, w)`. Physics sync copies the quaternion components directly. Euler angles are an editor presentation only and are never the physics interchange format.

Future editor scale manipulation must be a typed feature command that updates
logical dimensions, the collider, persistence state, and both presentation
history samples transactionally. Direct editor access to Jolt bodies is not an
accepted integration path.

### Presentation history

The S0 crate feature publishes previous/current logical poses and immutable
presentation extraction interpolates between them using the host's clamped
`alpha`. Position is interpolated linearly and rotation uses normalized
shortest-path interpolation. Spawn and restore initialize both samples to the
same pose, and extraction never writes authoritative state.

The visual sandbox owns the same crate/Jolt `Simulation` composition as the
headless host. Rendering consumes only feature extraction plus a host-owned
static ground fixture; there is no second ECS synchronization/render path.

### Determinism and future networking

The fixed 120 Hz step and explicit authority boundaries support repeatable scheduling, but they do not promise bitwise or cross-platform lockstep determinism. Jolt's cross-platform deterministic compile mode is deliberately disabled. The intended future multiplayer model is an authoritative server that publishes state, not peers or clients independently reproducing an identical simulation.

Persistent identities, serializable logical state, commands, and presentation snapshots must therefore remain distinct from process-local Jolt handles even though replication itself is deferred.

## Complex Scenarios

Ragdolls, vehicles, and compound objects follow the same rule: a feature slice owns its engine-level components and commands while a physics adapter owns Jolt-specific handles and calls. Features must not leak raw JoltC structs or pointers into ECS components.

- A ragdoll may keep engine `BodyId` values in a process-local runtime component and publish a bone-pose buffer.
- A vehicle feature may keep a chassis handle and constraint handle behind a vehicle physics capability, then publish chassis and wheel presentation transforms.
- A body changing static, kinematic, or dynamic mode changes authority at an explicit command boundary; ownership must not be inferred from whichever system wrote last.

## Consequences

### Positive

- Dynamic simulation authority is unambiguous.
- Rendering, persistence, and future networking do not depend on JoltC.
- Quaternions cross the physics/ECS boundary without lossy Euler conversion.
- Process-local physics handles cannot accidentally become saved or replicated identities.
- Foreign and stale-world body handles cannot alias a live body in another world.
- Headless physics tests can link Jolt without SDL, renderer, shader, or editor dependencies.

### Negative

- Each body-mode transition needs an explicit command and synchronization policy.
- Physics-to-ECS publication remains per-tick work.
- Future kinematic/static and editor-authoring features still need typed transform commands and coherent history updates.
- The one-live-owned-world restriction prevents atomic old/new simulation replacement and must be resolved or accepted before multi-world server deployment.
- Collider origin and center-of-mass conventions need tests as shape complexity grows.

## References

- ADR-004: ECS Architecture
- ADR-007: Product, Platform, and Compatibility Scope
- [Jolt Physics documentation](https://jrouwe.github.io/JoltPhysics/)
- [`third_party/joltc-zig/README.md`](../../third_party/joltc-zig/README.md)
