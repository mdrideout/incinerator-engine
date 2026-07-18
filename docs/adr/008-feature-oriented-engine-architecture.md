# ADR-008: Feature-Oriented Engine Architecture

**Status:** Accepted and implemented through the post-S11 corrective pass
**Date:** 2026-07-09
**Amended:** 2026-07-13; 2026-07-15 after S11 corrective review
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
`CrateFeature`, `CharacterFeature`, `VehicleFeature`, `DistrictFeature`,
`InteractionFeature`, and `NpcFeature` independently prove that boundary while
sharing one runtime and physics world. Cross-feature behavior uses narrow
named gameplay ports—such as driver, carrier, district, and navigation
access—rather than private components or direct feature imports. These are
concrete authority contracts, not a general possession or messaging framework.

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
ticks, command submission, and persistence. The composition owns the current
`SnapshotV11` world schema, runtime clock/identity metadata, global identity
policy, validated cross-feature relationships, and logical district
reconstruction;
features own their logical V1 records and feature-specific persisted tuning.
Feature simulation tuning is required in the current save envelope and
authoritative on restore; host capacity and presentation assets remain
restore-time policy. Occupied restore creates characters and vehicles before
linking authority, while district, interaction, and NPC restore rebuild
validated logical ownership without persisting worker or backend handles.
Any partial link or activation failure rolls back before the candidate world is
discarded.

The S11 corrective amendment preserves that ownership while adding explicit
persisted NPC route modes, durable encounter/replacement state, and exact
transactional headless replacement and restored-combat consumption. It is an
intentional current-cohort break, not a compatibility reader for `SnapshotV7`.
The cold product graph declares its vitals and encounter contract roots
directly; a client-root import cannot satisfy or conceal a headless dependency.

The current zflecs wrapper permits one live engine-owned world per process. A
shared lease rejects a second owner before entering zflecs and preserves the
existing caller. The accepted M3 product model is one authoritative world per
process, with replacement through validated process restart rather than
in-process hot swap. The visual sandbox and cold authority own deliberately
different host compositions over the same logical contracts. The graphical
host is also compiled as two separately named products: the normal client and
an explicitly installed validation composition. Scripted scenarios and fault
seams are compile-time absent from the normal client. The prototype `GameWorld`
and borrowed-world bridge have been removed. Pending command and outcome
storage is fixed-capacity and accepted commands reserve
authority-outcome delivery before mutation. M3 also bounds external producer
ingress and result delivery. A future network transport must add its own
authentication, retry, idempotency, and rate policy; it may not rely on
unbounded growth.

## Consequences

- New gameplay is delivered and tested as an end-to-end slice.
- Shared infrastructure is extracted after demonstrated reuse, normally after a second consumer.
- Headless behavior is a routine composition rather than a special mock of the graphical application.
- Backend upgrades are isolated behind smaller seams.
- Some code remains intentionally local or duplicated until its common invariant is proven.

## Supersedes

This ADR supersedes ADR-002's global layered-module architecture. Low-level modules may still be internally layered, but gameplay delivery and top-level ownership follow feature boundaries.
