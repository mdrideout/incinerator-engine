# S3 District Streaming

**Date:** 2026-07-12
**Status:** S3-A and S3-B complete; full S3 remains open for S3-C

## Outcome

S3-A loads one procedural district asynchronously and unloads it safely. The
complete lifecycle owns and releases its worker job, decoded CPU build,
persistent district entity, static Jolt bodies, and extracted logical draws.
Repeated cycles, cancellation, stale completion, bounded capacity,
save/restore, and shutdown are explicit behavior rather than incidental
cleanup.

This is a streaming vertical slice, not a general asset framework. S3-A proves
logical ownership and thread affinity. S3-B adds the cooked fixture, installed
content, scene generations, fallback, and nonblocking Metal residency. Full S3
remains open until S3-C adds proximity policy, repeated installed lifecycle
smokes, and complete end-to-end evidence.

## Content Policy

Runtime streaming consumes an immutable, validated, renderer-neutral
`DistrictBuild`; it does not consume authoring files. The first producer is a
deterministic procedural recipe compiled into the engine test sandbox. This
keeps the open engine package independent of unlicensed game content and makes
worker, cancellation, physics, persistence, and GPU ownership reproducible.

Source import is an offline/editor or cook-time concern. S3-B installs a
versioned package with an explicit content root, provenance, integrity checks,
and preserved glTF node/material/instancing behavior. The former runtime
`loadGlb` prototype was removed because it combined source parsing, image
decoding, GPU upload, and fence waiting.

## Bounded Contract

The initial contract supports exactly:

- one in-flight worker job;
- one loading, cancelling, or active district;
- one declared coordinate, `(0, -4)`, outside the bootstrap ground, in the
  sandbox host;
- recipe version 1;
- at most eight finite axis-aligned static boxes;
- one host-supplied typed mesh/material pair carried as inert logical draw data;
- fixed CPU build-byte limits;
- one loader completion committed per fixed tick.

Limits are configuration and rejection policy, not dynamic allocation goals.
Additional chunks, dependencies, materials, and assets require measurements
and a later contract revision.

Command, outcome, and event channels are fixed-capacity and lossless. The host
must drain outcomes and events as part of its owner-thread loop. If either
output channel cannot accept a due command result or loader completion, the
system returns `DistrictOutputBackpressure` and the Runtime enters its declared
terminal fault state; it never silently leaves a completion stalled forever.
Faulted teardown still cancels/joins the worker and releases owned bodies and
entities.

## Dependency Boundaries

### District build contract

A named gameplay-level contract shared by the feature and worker adapter owns:

- `ChunkCoord`;
- a fixed-capacity `DistrictBuild` of static box descriptors;
- recipe version, deterministic checksum, and byte accounting;
- job handle and `pending`, `ready`, `cancelled`, or structured-failure poll
  results;
- structural assertions for the worker port.

It imports no SDL, renderer, Jolt, Flecs, or feature implementation.

### DistrictFeature

`DistrictFeature` is generic over a static-body capability and a main-thread
district-loader port. It owns commands, state transitions, the persistent district entity,
static-body handles, logical records, typed outcomes/events, and immutable draw
extraction. It does not spawn threads, allocate GPU resources, inspect the
character feature, or decide player proximity.

The public commands are:

- `request_load(coord, request_id, assets)`;
- `cancel_load(request_id, ticket)`;
- `unload(request_id, ticket)`.

The feature accepts worker completion only for the current generation.
Activation is an internal logical transition: it transactionally reserves
result storage, creates every static body, creates one persistent entity,
installs components, then publishes `active`. It never waits for GPU residency.
Failure rolls back the complete candidate prefix. Unload removes all bodies and
the entity before publishing `absent`.

Within the command system, all due user commands are processed before at most
one loader completion. A same-tick cancellation therefore changes the current
generation before completion is observed and always wins. Even an immediately
ready fake completion cannot activate before `request_tick + 1`. Stale results
are released and diagnosed without mutating current state.

### Worker adapter

The concrete procedural loader uses one short-lived Zig thread per accepted
request. No idle thread or unbounded queue exists. Shared state is protected by
a small mutex; worker code produces only a bounded plain-data build. It never
touches ECS, Jolt, SDL, renderer, editor, or host state.

Cancellation sets the current generation's flag. The worker checks it between
bounded work units and publishes `cancelled`; shutdown cancels and joins any
live thread. A new request is rejected until the previous result has been
consumed and its thread joined.

### Static-body adapter

The physics contract gains only the axis-aligned static-box capability this
slice uses. The Jolt adapter translates it to world-qualified body handles and
strict create/destroy ordering. Jolt identifiers never cross the feature
boundary.

### Visual host boundary

S3-B makes the visual host own the cooked scene worker, district scene
registry, SDL/Metal upload, and fallback resolution. The host reserves a typed
scene generation before it requests a logical load. Logical activation may
immediately become visible through collision-box fallback geometry; GPU
residency later changes only host-side handle resolution and never simulation
authority or collision. S3-C will add host-owned proximity policy.

After a successful `unload`, extraction is empty before the host releases
the scene. One scene generation preserves nodes, shared mesh instances,
materials, textures, and authored transforms. Unloading invalidates the old
generation, so stale draws or double release fail.

The older procedural mesh/texture startup helpers remain synchronous, but they
are not used by streamed districts. The streamed path batches a bounded set of
scenes into one transfer buffer, copy pass, command buffer, and fence; it polls
with `SDL_QueryGPUFence` and turns post-submit cancellation into
discard-on-completion. It never waits for a streamed upload fence.

## State Machine

```text
absent --request--> loading --ready/commit--> active
   ^                    |                       |
   +---- cancel/fail ---+--------- unload ------+
```

Every request receives a monotonically increasing generation. Commands and
worker results with an older generation reject without mutating the current
state. Expected capacity, stale-generation, duplicate, and invalid-state cases
are typed rejections. Worker/physics/allocator/invariant faults remain terminal
runtime errors after transactional unwind.

## Persistence

S3-A advances the composition snapshot to V4. Only an active district is
authoritative snapshot state; `loading` and `cancelling` are transient and make
save return `DistrictTransitionPending`.

`DistrictV1` stores persistent ID, coordinate, recipe version, and deterministic
build checksum. Assets, worker handles, generations, queues, GPU resources,
static-body handles, and prepared bytes are excluded. Restore validates all
global identities and recipe metadata before constructing the candidate world,
rebuilds the deterministic recipe synchronously, transactionally recreates its
static bodies/entity using host-supplied presentation assets, and starts with
no worker. Immediate save after restore must be byte-stable.

Cross-chunk references are not created by this one-chunk recipe. Their format
and missing-reference behavior remain deferred until a second simultaneously
resident chunk proves the requirement.

## Backpressure and Accounting

The slice records and enforces:

- one accepted in-flight job;
- maximum boxes and prepared CPU bytes;
- current active bodies, entities, and logical draws;
- request-to-active tick latency;
- activation, deactivation, cancellation, and teardown time.

No wall-time threshold is used in shared CI. Schema, bounded counts, material
movement/collision evidence, lifecycle completion, and zero-resource cleanup
are gates; local timings are characterization evidence.

## S3-A Staged Delivery

1. [x] Add Runtime owner-thread enforcement; implement and test the
   build/job/static-body contracts and real worker
   cancellation/teardown.
2. [x] Implement `DistrictFeature` against fakes, including transactional
   activation, stale generations, capacity, extraction, and V1 records.
3. [x] Compose the real worker and Jolt static bodies; add Snapshot V4 and a
   headless request/cancel/request/prepare/activate/collide/deactivate cycle.
4. [x] Record the ReleaseFast headless baseline, repeat independent reviews,
   and close S3-A without claiming full S3 completion.

## Remaining Full-S3 Gates

### S3-B: cooked content and GPU residency — complete

- The explicit little-endian V1 bundle, absolute content root, structured
  loader failures, joined runtime worker, self-authored glTF/provenance,
  deterministic cooker, installed relocation proof, scene-level registry,
  fallback, bounded batching, nonblocking polling, and cancellation state
  machine are implemented.
- Renderer queues, hardware instancing, culling, and LOD remain deliberately
  absent because the one-scene measurements do not justify them.

### S3-C: boundary host and native evidence

- Add proximity hysteresis without importing character/vehicle features into
  `DistrictFeature`.
- Run the installed cooked-content/Metal lifecycle smoke from `/tmp` above and
  below the fixed tick rate, including repeated cancel/load/unload/reload.
- Record repeated lifecycle timing/peak profiles and repeat final full-S3
  independent reviews.

## Acceptance Evidence

- Worker tests prove real background execution, cancellation after work starts,
  stale-handle rejection, bounded single-job backpressure, and join-on-shutdown.
- Feature tests prove every state/command transition, generation isolation,
  transactional body/entity rollback, deterministic extraction, cleanup, and
  logical record validation.
- Real headless composition proves the main thread alone commits prepared data,
  district collision affects a live dynamic body, repeated activation returns
  body/entity counts to baseline, and V4 restore is byte-stable.
- ReleaseFast S3-A measurement records job latency, command/commit/unload cost,
  complete tick/extraction distributions, byte/count budgets, and final cleanup.

## Explicit Full-S3 Deferrals

- multiple resident chunks, dependency graphs, portals, cross-chunk references,
  and world-origin rebasing;
- runtime source glTF parsing, a general VFS, patching, compression, and game
  asset distribution;
- general mesh/material/texture registries and shared-resource deduplication;
- general upload heaps and device-loss recovery;
- culling, instancing, LOD, occlusion, streaming mipmaps, and render queues;
- navigation meshes, AI population, audio zones, lighting, terrain, and gameplay
  entities owned by district content;
- secondary platforms, network interest management, and editor authoring.
