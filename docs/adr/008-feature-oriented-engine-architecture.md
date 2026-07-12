# ADR-008: Feature-Oriented Engine Architecture

**Status:** Accepted
**Date:** 2026-07-09
**Amended:** 2026-07-12
**Decision Maker:** Matt

## Context

The prototype is wired through one application object and organized primarily by technical subsystem. That is understandable at its current size, but it scatters a gameplay capability across ECS, physics, rendering, input, persistence, and editor code as the engine grows.

The engine needs boundaries that support complete gameplay slices without turning an in-process game into a network of services or prematurely generalizing every backend.

## Decision

Incinerator will use a thin horizontal kernel, feature-owned vertical slices, narrow capability contracts, backend adapters, and explicit host composition roots.

### Dependency direction

1. Hosts compose the kernel, features, contracts, and adapters.
2. Features depend only on the kernel and capability contracts.
3. Adapters implement contracts and may depend on third-party libraries.
4. The kernel and contracts do not import SDL, Jolt, ImGui, hosts, or gameplay features.
5. Adapters do not import private feature implementation.
6. Feature-to-feature interaction uses an explicit command, event, query, relationship, or deliberately shared component.

These are compile-time module boundaries inside one process. They are not microservices, dynamic plugins, or runtime dependency injection.

### Kernel responsibilities

The kernel is limited to broadly shared policy:

- world lifecycle;
- fixed-tick scheduling and named phases;
- a fixed command phase and target-tick policy for feature-owned queues;
- time and tick identity;
- runtime and persistent identity primitives;
- feature registration and static composition;
- diagnostics and lifecycle hooks.

Flecs remains the ECS implementation. The kernel exposes only a minimal,
identity-aware component registration/access seam needed by feature code; it
must not grow into a second query language or general Flecs facade. Flecs
identifiers and APIs must not become persistent IDs, serialized data, or the
public host interface.

### Feature ownership

A feature owns its data and behavior end to end: components, commands, events,
systems, persistence, render extraction, optional editor extension, and tests.
`CrateFeature`, `CharacterFeature`, and `VehicleFeature` now independently
prove that boundary while sharing one runtime and physics world. Character and
vehicle interact through the named `DriverAccess` gameplay port rather than
private components or direct feature imports. This is the narrow common
authority contract proven by two consumers, not a general possession framework.

Feature registration is deterministic and explicit. Runtime feature unloading, hot reload, a binary plugin ABI, and auto-discovery are deferred until a real use case requires them.

### Contracts and adapters

Contracts are narrow and shaped by gameplay operations, such as creating and destroying a rigid body or appending a render-extraction record. They do not mirror entire SDL, Jolt, or storage APIs.

SDL GPU remains the single graphics implementation until it demonstrates a concrete limitation. Jolt is accessed through an engine-facing physics contract so the Zig binding can change without rewriting features.

### Interaction semantics

- A **command** requests a state change at a declared safe boundary.
- An **event** records an immutable fact that already occurred.
- A **query** reads current state without hidden mutation.

External input, editor tooling, and future networking use the same command semantics where their behavior matches. Structural world mutation is deferred to declared schedule boundaries. Rendering consumes extracted presentation data and cannot mutate authoritative simulation state.

### Composition and thread affinity

Composition roots explicitly construct their features and adapters. There is no global service locator or universal mutable `EngineContext`.

The main thread owns ECS structural mutation and SDL GPU submission. Physics or worker callbacks may publish bounded plain-data results; they do not mutate gameplay, ECS, renderer, or editor state directly.

### Current implementation boundary

The public `incinerator_engine` module is the feature-authoring surface. It
exports backend-neutral contracts, identity values, a type-erased `Runtime`,
and the startup-only `FeatureRegistry`. Its public layout does not expose a
Flecs world or mutable kernel bookkeeping. The concrete sandbox/Jolt
`Simulation` is deliberately a private conformance composition shared by the
visual sandbox and headless tests; it is not game-specific API promised by the
engine package.

The registry declares components and systems only. Commands, outcomes,
persistence records, and render extraction remain owned by each feature. The kernel
executes four fixed-tick phases—`commands`, `pre_physics`, `physics`, and
`post_physics`—and
runs immutable presentation extraction outside that schedule at render
frequency. CharacterFeature uses `pre_physics` for controller movement and
VehicleFeature applies tick-scoped input before the single composition-owned
Jolt step. No feature adapter privately advances the shared world. Expected
domain rejection is reported as a typed outcome;
infrastructure, adapter, and invariant errors put the runtime into a terminal
fault state that permits diagnostics and teardown but rejects further normal
ticks, command submission, and persistence. The composition owns the V3 world
schema, runtime clock/identity metadata, global identity policy, and validated
character/vehicle driver relationships;
features own their logical V1 records and feature-specific persisted tuning.
Character and vehicle simulation tuning is required in the V3 envelope and
authoritative on restore; host capacity and presentation assets remain
restore-time policy. Occupied restore creates characters and vehicles before
linking authority, and any partial link failure rolls back before the candidate
world is discarded.

The current zflecs wrapper permits one live engine-owned world per process. A
shared lease rejects a second owner before entering zflecs and preserves the
existing caller, but successful atomic old/new snapshot swapping is not yet
available. The visual sandbox now owns that same composition; the prototype
`GameWorld` and borrowed-world bridge have been removed. Pending command and outcome
storage is also intentionally unbounded for the single-player sandbox; bounded
backpressure is required before network-originated work is accepted.

## Consequences

- New gameplay is delivered and tested as an end-to-end slice.
- Shared infrastructure is extracted after demonstrated reuse, normally after a second consumer.
- Headless behavior is a routine composition rather than a special mock of the graphical application.
- Backend upgrades are isolated behind smaller seams.
- Some code remains intentionally local or duplicated until its common invariant is proven.

## Supersedes

This ADR supersedes ADR-002's global layered-module architecture. Low-level modules may still be internally layered, but gameplay delivery and top-level ownership follow feature boundaries.
