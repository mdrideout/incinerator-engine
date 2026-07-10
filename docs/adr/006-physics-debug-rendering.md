# ADR-006: Physics Debug Rendering Architecture

## Status

Superseded; replacement deferred as of 2026-07-09

## Context

The prototype implemented the old `zphysics` debug-renderer vtable, CPU-transformed debug geometry, a fixed 64-slot circular primitive pool, an editor physics panel, and an F4 toggle. That design no longer describes the repository after the Jolt 5.5/JoltC migration.

Carrying it forward would have preserved several unresolved hazards:

- circular batch-slot reuse could overwrite geometry still referenced by Jolt;
- callback, batch-storage, physics-world, and renderer teardown ordering was not an explicit ownership contract;
- physics callbacks reached directly toward renderer/editor structures;
- the implementation depended on wrapper-specific debug APIs that are not part of the new narrow adapter.

## Decision

Physics debug rendering is removed from the current engine and deferred. The JoltC build does not enable `JPH_DEBUG_RENDERER`; there is no physics debug adapter, editor panel, or debug hotkey in the supported implementation.

This is a deliberate scope decision, not a claim that collision visualization is unnecessary. It keeps the unsafe prototype out of the upgraded physics boundary until a new implementation has a concrete debugging need and can satisfy the following contract.

### Requirements for a future replacement

A future JoltC-backed debug renderer must:

1. Keep Jolt C ABI types and callbacks inside the physics adapter.
2. Distinguish compile-time support from a runtime enabled/disabled setting.
3. Publish bounded, plain debug primitives or immutable batch handles; callbacks must not mutate ECS or editor state.
4. Use owned or generational batch storage whose handles cannot alias overwritten geometry. A fixed circular overwrite pool is not acceptable.
5. Define teardown so the physics world and all Jolt references are destroyed before callback state or batch storage.
6. Let a renderer capability consume extracted lines/triangles without making physics depend on SDL GPU or ImGui.
7. Specify and test body-origin, center-of-mass, handedness, matrix-layout, and quaternion conventions.
8. Remain absent from and harmless to the headless host and isolated physics tests.
9. Place bounded memory, overflow behavior, and per-frame clearing under explicit policy.

GPU instancing versus CPU transformation is intentionally undecided until representative debug workloads are measured. Likewise, an editor UI is a consumer of the future capability, not part of its core physics implementation.

## Consequences

### Positive

- The upgraded JoltC boundary has no dependency on the retired wrapper debug API.
- Known lifetime and geometry-aliasing risks are not carried into the greenfield architecture.
- Headless physics remains independent of renderer and editor linkage.
- A later implementation has explicit ownership and API criteria.

### Negative

- Collision shapes, bounds, velocities, and centers of mass cannot currently be visualized in-engine.
- Some physics diagnosis must use tests, logs, or external tooling until the replacement is prioritized.

## Historical note

The previously accepted CPU-transform/vtable implementation is retained in repository history only. Its file list, editor controls, and 64-slot pool are not current APIs and must not be used as an implementation guide.

## References

- [Jolt Physics debug rendering](https://jrouwe.github.io/JoltPhysics/)
- ADR-005: Physics-ECS Integration Strategy
- [`third_party/joltc-zig/README.md`](../../third_party/joltc-zig/README.md)
