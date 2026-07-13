# ADR-006: Physics Debug Rendering Architecture

## Status

Superseded by ADR-010; retained as the historical prototype-retirement decision

**Superseded:** 2026-07-13

## Context

The prototype implemented the old `zphysics` debug-renderer vtable, CPU-transformed debug geometry, a fixed 64-slot circular primitive pool, an editor physics panel, and an F4 toggle. That design no longer describes the repository after the Jolt 5.5/JoltC migration.

Carrying it forward would have preserved several unresolved hazards:

- circular batch-slot reuse could overwrite geometry still referenced by Jolt;
- callback, batch-storage, physics-world, and renderer teardown ordering was not an explicit ownership contract;
- physics callbacks reached directly toward renderer/editor structures;
- the implementation depended on wrapper-specific debug APIs that are not part of the new narrow adapter.

## Historical Decision

The unsafe prototype debug renderer was removed during the JoltC migration and
was not carried forward. At that point, replacement physics visualization was
deferred until it could meet the ownership requirements below.

This is a deliberate scope decision, not a claim that collision visualization is unnecessary. It keeps the unsafe prototype out of the upgraded physics boundary until a new implementation has a concrete debugging need and can satisfy the following contract.

### Requirements applied to its replacement

The successor JoltC-backed debug renderer was required to:

1. Keep Jolt C ABI types and callbacks inside the physics adapter.
2. Distinguish compile-time support from a runtime enabled/disabled setting.
3. Publish bounded, plain debug primitives or immutable batch handles; callbacks must not mutate ECS or editor state.
4. Use owned or generational batch storage whose handles cannot alias overwritten geometry. A fixed circular overwrite pool is not acceptable.
5. Define teardown so the physics world and all Jolt references are destroyed before callback state or batch storage.
6. Let a renderer capability consume extracted lines/triangles without making physics depend on SDL GPU or ImGui.
7. Specify and test body-origin, center-of-mass, handedness, matrix-layout, and quaternion conventions.
8. Remain absent from and harmless to the headless host and isolated physics tests.
9. Place bounded memory, overflow behavior, and per-frame clearing under explicit policy.

GPU instancing versus CPU transformation was intentionally left to measured
implementation work. Likewise, the editor remained a consumer rather than the
owner of physics extraction.

## Current Successor

ADR-010 and S4-C implement the replacement. The physics adapter now publishes
bounded renderer-neutral line/triangle evidence after completed ticks; the
Metal host owns fixed GPU upload slots; the editor consumes immutable controls
and diagnostics; and the cold headless product links no rendering/editor path.
The replacement does not revive the retired wrapper vtable or circular
overwrite pool described by this ADR.

## Consequences

### Positive

- The upgraded JoltC boundary has no dependency on the retired wrapper debug API.
- Known lifetime and geometry-aliasing risks are not carried into the greenfield architecture.
- Headless physics remains independent of renderer and editor linkage.
- The successor implementation was evaluated against explicit ownership and
  API criteria.

### Historical negative

- Collision shapes, bounds, velocities, and centers of mass were temporarily
  unavailable in-engine between the JoltC migration and S4-C.

## Historical note

The previously accepted CPU-transform/vtable implementation is retained in repository history only. Its file list, editor controls, and 64-slot pool are not current APIs and must not be used as an implementation guide.

## References

- [Jolt Physics debug rendering](https://jrouwe.github.io/JoltPhysics/)
- ADR-005: Physics-ECS Integration Strategy
- [ADR-010: Developer Diagnostics, Replay, and Debug Visualization](010-developer-diagnostics-replay-and-debug-visualization.md)
- [S4-C validation record](../validation/s4c-acceptance.md)
- [`third_party/joltc-zig/README.md`](../../third_party/joltc-zig/README.md)
