# S0 Crate Lifecycle Design

**Status:** Implemented; acceptance evidence in progress
**Scope:** S0 only
**Related decisions:** ADR-004, ADR-005, ADR-007, ADR-008

## Purpose

S0 proves the intended engine architecture with one complete behavior: a crate can be spawned by command, simulated, presented with interpolation, saved, restored into a fresh simulation, and destroyed without leaking an entity or physics body. The same crate feature must run in a visual sandbox and in a headless executable.

This is a vertical slice, not the beginning of a general-purpose framework. Shared machinery is included only where this slice uses it.

## Required properties

- The public engine module is the feature-authoring kernel/contracts API; the
  concrete crate `Simulation` is an internal conformance composition, not a
  game-specific API exported by the engine package.
- The crate feature owns its commands, components, systems, persistence schema, and presentation extraction.
- Composition and feature registration finish at startup; neither is mutable during a tick.
- The physics dependency is a narrow compile-time contract shaped by crate operations.
- Persistent identity is independent of Flecs and Jolt runtime handles.
- Spawn, restore, and destroy have explicit commit and rollback rules.
- A dynamic body is the authoritative transform source while it is `PhysicsDriven`.
- Rendering consumes interpolated plain data and cannot mutate simulation state.
- Headless composition cannot import or link SDL, the renderer, ImGui, or editor code.

## Engine and conformance surfaces

The public `incinerator_engine` module exposes backend-neutral contracts,
persistent/runtime identity values, `Runtime`, and the startup-only
`FeatureRegistry` needed by separately licensed game features. Runtime storage
is type-erased; Flecs worlds/APIs, Jolt body IDs, renderer objects, hosts, and
crate implementation types are not public engine state. Feature code receives
a validated `RuntimeId` containing only a runtime token and engine-issued
serial; the raw Flecs entity value remains in the runtime's private index.

S0 also contains a private concrete Jolt composition used by the sandbox and
headless conformance tests. Its surface is no broader than:

```zig
init(allocator, config) !Simulation
initBorrowed(allocator, world_context, physics, config) !Simulation
deinit() void
submit(command) !void
tick() !void
pollOutcome() ?Outcome
presentation(alpha) ![]const CrateDraw
save(allocator) ![]u8
fromSnapshot(allocator, json, config) !Simulation
```

Exact Zig spelling may vary to fit the implementation, but these semantics do not:

- `submit` accepts intentional public commands, not arbitrary ECS mutations.
- `tick` advances exactly one configured fixed step. Hosts own wall-clock accumulation and catch-up policy.
- `presentation` is a borrowed, immutable snapshot valid until the next tick or extraction.
- `alpha` is clamped to `[0, 1]` and never feeds back into authoritative state.
- `save` writes V1 logical simulation state only.
- `fromSnapshot` constructs a fresh `Simulation`; it never patches a live world in place.

The first command set is limited to `SpawnCrate`, `DespawnEntity`, and an impulse command only if the visual or timeline test uses it. New commands are added for demonstrated behavior, not to make a generic command API.

## Static composition

`Simulation.init` creates the world, opens a startup-only registry, registers
`CrateFeature`, builds the schedule, validates unique owned system names, and
then freezes registration. Registration after initialization is an error by
construction rather than a synchronized runtime operation.

The registry exists only to declare what S0 executes:

- crate components;
- crate synchronization systems;
- the one physics-step system.

Typed commands/outcomes, V1 persistence, and render extraction remain
feature-owned methods. S0 does not add speculative registries for them.

It is not a service locator, dependency-injection container, reflection database, dynamic plugin manager, or feature-discovery mechanism. The schedule is likewise fixed at startup. Systems use explicit feature-owned context and execute in deterministic registration order within a phase.

The kernel defines these named phases:

1. `commands` — apply the command queue at the structural-mutation boundary;
2. `pre_physics` — prepare physics inputs required by registered features;
3. `physics` — advance the physics world once by the fixed step;
4. `post_physics` — copy authoritative body state into transform history;

Presentation is deliberately outside the fixed schedule. The render host calls
immutable extraction at frame frequency with its interpolation alpha.
S0 currently registers no `pre_physics` system, so that phase is an intentional
empty boundary until a feature has physics input to publish.

Commands present before a tick are consumed in its `commands` phase. Commands
emitted anywhere while a tick is executing target the next tick, independent
of system registration order. Expected domain rejection (for example, a stale
despawn) produces a typed outcome and does not fault the world. Infrastructure,
adapter, or invariant failures terminally fault normal ticking, command
submission, and persistence while leaving diagnostics and coordinated teardown
available.

## Physics contract

The crate feature is parameterized by a physics implementation at compile time. S0 does not add a runtime vtable, universal backend interface, or backend selection mechanism. The compiler verifies the small method set used by the slice.

The required operations are:

```text
createDynamicBox(dynamic_box_desc) -> body handle or error
destroyBody(body handle) -> error
bodyState(body handle) -> body state or error
applyImpulse(body handle, impulse) -> error          # only if used by S0
step(fixed_delta_seconds) -> error
```

`BodyState` contains position, normalized rotation, linear velocity, and angular velocity. The contract's body handle is opaque to the feature except for passing it back to the same physics world. The Jolt adapter validates world ownership and stale handles; Jolt/JoltC types do not cross the adapter boundary.

The contract is intentionally asymmetric: dynamic crates are read from physics after the step. General queries, constraints, character control, collision event routing, multiple worlds, and backend swapping are deferred until a slice needs them.

## Identity and runtime state

The persistent identity for S0 is:

```zig
pub const PersistentId = struct {
    namespace: u64,
    local: u64,
};
```

`namespace` identifies the logical simulation/save lineage. `local` is allocated monotonically within that namespace and is never reused during the simulation's lifetime. The pair, not `local` alone, is the identity key. Zero values are reserved as invalid unless implementation tests establish a different explicit rule.

The namespace and next-local counter are saved. Restore rejects duplicate IDs, a mismatched namespace inside one document, invalid reserved values, and a next-local counter that could collide with restored records. A new spawn after restore receives an ID greater than every restored local ID.

Flecs entity values and physics body handles are process-local runtime
references. Feature code receives only the validated `RuntimeId` wrapper, and
the crate simulation's public command/view surface returns persistent IDs
instead. Runtime values are never compared as persistent identity, written to
a save, or assumed stable across restore. The kernel `Runtime` owns the
persistent-ID-to-runtime-ID index; the crate feature owns its active list and
private body component. Runtime lookup validates the full persistent ID,
runtime token, and engine-owned monotonic entity serial. Physics handles add an
engine-owned 64-bit serial so Jolt's finite native generation cannot revive a
stale handle.

## Feature ownership and transform authority

`CrateFeature` owns:

- the `Crate` data, including half-extents;
- `PersistentId`, `TransformHistory`, `PhysicsDriven`, and the private body-reference component;
- the crate command queue and handlers;
- spawn/despawn coordination;
- post-physics synchronization;
- V1 logical serialization;
- crate presentation records and their extraction;
- feature-level tests.

`PhysicsDriven` is an explicit authority marker, not an inferred convention. For such an entity:

- the physics body owns current position and rotation during simulation;
- `post_physics` first moves `current` to `previous`, then reads the new body pose into `current`;
- gameplay cannot silently write the transform component; a future teleport operation must update body state and both history samples coherently;
- scale is logical crate data and is not read back from Jolt;
- rendering receives only an interpolated copy.

On spawn, `previous` and `current` are initialized to the same pose, preventing
a one-frame interpolation from an unrelated origin. Presentation interpolates
position linearly and rotation with normalized shortest-path interpolation;
half-extents are copied unchanged because S0 has no scale history. Extraction
never writes either history sample.

A crate presentation record contains only its persistent ID, interpolated transform, and the smallest typed mesh/material handles required by the visual sandbox. Those handles are host/resource-owner concerns, are generational where reuse is possible, and are neither simulation authority nor persisted data. Headless extraction may omit resolution of visual handles while preserving the same logical crate behavior.

## Transactional lifecycle

### Spawn

Before allocating a runtime entity or physics body, spawn validates the
requested pose, velocities, and half-extents. Queue/list capacity may be
reserved first; an explicit restored persistent ID is validated when the
provisional runtime entry is created. Creation then proceeds through explicit
stages:

1. reserve or validate the persistent ID and create a provisional indexed
   runtime entity;
2. create/configure the dynamic physics body;
3. attach complete crate state;
4. commit the feature active list and typed outcome.

The single-threaded command boundary does not expose the provisional entry to
another system before commit. If any stage fails, completed stages are undone
in reverse order. A failed spawn leaves no live body, entity, or lookup entry.
Issued IDs may remain retired; identities are never reused to conceal failure.

### Destroy

Destroy first resolves and validates the full persistent ID. It removes the physics body before deleting the entity and lookup entry, so a failed body removal cannot leave an untracked live body. Once body destruction succeeds, removal of the feature-owned entity state and lookup entry must be non-failing or treated as an internal invariant violation. Repeating a destroy for a no-longer-live ID returns a defined not-found/stale-ID error and does not affect another crate.

The visual crate asset is owned once by the visual composition/resource owner, not by each crate entity. Instance destruction therefore releases the entity and body but does not destroy shared GPU resources. Visual-host shutdown destroys crate instances before the shared asset and renderer.

### Simulation teardown

`Simulation.deinit` drains feature-owned live instances through the same coordinated cleanup invariant, then releases feature storage, the ECS world, and the physics world in dependency order. Teardown is safe after partial initialization and after a failed restore.

## V1 persistence

V1 is a versioned logical JSON document. It contains:

- schema version `1`;
- persistent namespace and next-local counter;
- simulation tick/fixed-step information required to continue the logical timeline;
- crates sorted by persistent ID;
- for each crate: persistent ID, half-extents, current pose, linear velocity, and angular velocity.

It does not contain Flecs IDs, Jolt handles, allocator addresses, schedule state, GPU handles, cached presentation records, interpolation-only `previous` samples, or backend configuration. After restore, `previous` is set equal to restored `current`, so the first rendered frame is stable.

JSON parsing is strict for required fields and version. All records are parsed and validated into temporary logical data before runtime objects are published. Validation rejects duplicate IDs, non-finite numbers, non-positive extents, invalid or non-normalizable rotations, and unsupported versions. Limits on document size and crate count are explicit configuration, not accidental allocator exhaustion behavior.

Logical candidate construction is transactional:

1. parse and validate the whole V1 document;
2. create a fresh simulation with the requested backend/configuration and saved timeline metadata;
3. recreate crates through the normal transactional spawn path;
4. revalidate/reapply the tick and identity cursor after all crates succeed;
5. return the fresh simulation.

The current zflecs Zig wrapper permits one owned world per process. Attempting
to create a second candidate returns `error.EngineWorldAlreadyLive` before
entering zflecs and leaves the current simulation usable. A successful
replacement currently requires deinitializing the old simulation first.
In-place load/merge is outside S0. True atomic old/new swapping remains open
and is a material constraint for future multi-world server deployment.

Output is deterministic for the same logical state: records have a stable order and fields use one canonical representation chosen by the implementation. Byte-for-byte output stability across future schema versions is not promised.

## Composition graphs

The headless build uses an allowlist rather than relying only on a convention that graphical imports happen not to execute:

```text
headless host
  -> private S0 Simulation composition
      -> kernel: identity, schedule, world lifecycle
      -> CrateFeature
      -> narrow physics contract
      -> Flecs implementation detail
  -> Jolt physics adapter
      -> JoltC / Jolt
```

Allowed headless dependencies are Zig's standard library, the public simulation/kernel code, `CrateFeature`, Flecs, the narrow physics contract, the Jolt adapter, JoltC/Jolt, and platform libraries required by Jolt. SDL, SDL GPU, the renderer, shader tooling/runtime assets, zgui/ImGui, zmesh, zstbi, editor modules, and visual resource owners are prohibited from the headless graph and final linkage.

The visual sandbox adds SDL input/window/GPU adapters, the renderer, and a minimal crate visual-resource owner at its composition root. Neither `CrateFeature` nor the headless host imports those modules. Both hosts submit the same public commands and advance the same simulation.

The build verifies the boundary by constructing a dedicated headless module/executable from the allowlist, compiling its tests independently, and inspecting its declared dependencies or linked binary for prohibited libraries. A source-level dependency test guards against prohibited import edges.

## Tests and acceptance evidence

S0 is complete only with all of the following:

1. **Lifecycle integration:** real Jolt headless run of spawn, ticks, save, destroy, restore into a fresh simulation, more ticks, and destroy; no live bodies or entities remain.
2. **Repeat lifecycle:** many spawn/despawn cycles, including stale-ID destruction attempts, leave body/entity counts at baseline and never alias a new crate.
3. **Transactional failure:** injected failure at each supported spawn/restore stage leaves no published entity, body, or ID mapping; failed fresh restore is fully deinitialized.
4. **Persistence validation:** V1 round-trip preserves logical state and velocities; malformed, duplicate-ID, non-finite, invalid-version, and over-limit documents fail without changing an existing simulation.
5. **Identity:** namespace-plus-local equality and lookup are enforced; restored allocation cannot collide with restored IDs.
6. **Schedule:** registration order is deterministic, registration freezes after startup, and commands emitted during a tick execute at the next command boundary.
7. **Deterministic timeline:** the same initial V1 state and command/tick sequence run twice produce the same expected logical samples within an explicitly documented floating-point tolerance.
8. **Interpolation:** endpoints, midpoint position, shortest-path rotation, clamping, and spawn/restore initialization are covered without mutating authoritative samples.
9. **Authority:** a physics-driven crate follows body state after each step and has no direct presentation-to-simulation write path.
10. **Architecture:** the public root and crate feature compile without SDL/editor/renderer imports; the dedicated headless artifact has no prohibited graphical linkage.
11. **Visual smoke:** the sandbox displays one falling/tumbling crate smoothly when rendering above and below the fixed simulation frequency, and shutdown releases instance and shared visual resources in order.

Tests use a small compile-time fake physics implementation for precise failure
and schedule assertions, plus the real Jolt adapter for integration and
ownership evidence. Current injected coverage includes body creation, restore
rollback, and post-physics body-read failure. Remaining all-stage failure,
non-finite/over-limit persistence, low-rate visual, and initial performance
evidence stay open in the overhaul plan. The fake implements the same narrow
operations; it is not a second production backend.

## Explicit non-goals

S0 does not introduce:

- a generic ECS facade over Flecs;
- runtime feature loading, hot reload, plugin ABI, or feature discovery;
- a global service locator or universal engine context;
- a runtime physics-backend interface or promise of interchangeable backends;
- a general event bus, query language, job system, or multithreaded scheduler;
- arbitrary entity graphs, prefabs, scenes, or a generic serializer;
- live-world load, save merging, rollback networking, replication, MMO authority, or compatibility migrations beyond rejecting non-V1 documents;
- a general asset database, renderer abstraction, or material system;
- editor UI for crates;
- collision-event architecture, character control, vehicles, or constraints;
- backward compatibility with prototype APIs or data.

If S0 appears to require one of these, implementation pauses to identify the concrete crate requirement and chooses the smallest local solution. A broader abstraction waits for a second real consumer and a demonstrated shared invariant.
