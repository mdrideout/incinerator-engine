# ADR-009: Runtime Content and Streaming Boundary

**Status:** Accepted
**Date:** 2026-07-12
**Decision Maker:** Matt

## Context

The engine and game have separate distribution/licensing futures. Existing
game-owned files are excluded from the engine package, while the current glTF
loader accepts authoring files and directly performs parsing, image decoding,
GPU allocation, upload, and fence waits. That function is useful for prototype
loading but is not a safe asynchronous runtime-content boundary.

S3 needs to stream without making worker threads aware of ECS, physics, SDL,
renderer state, or repository-relative paths. It also needs a path to preserve
authored scene structure without forcing source-format parsing and third-party
decoder initialization into the shipped runtime.

## Decision

Incinerator distinguishes three forms of content:

1. **Source content** is authoring input such as glTF, images, and game data. It
   is consumed only by offline/build/editor cook tooling.
2. **Cooked content** is a versioned, validated, renderer-neutral runtime
   bundle produced for a declared engine/content schema cohort.
3. **Resident content** is process-local simulation and GPU state created from
   a cooked bundle and owned by feature/host registries.

Production runtime streaming will not parse source glTF. A cooker will preserve
the nodes, transforms, instances, mesh/material relationships, and texture
references required by the consuming slice, then write an immutable bundle
with explicit version, sizes, offsets, integrity metadata, and stable semantic
identities. Unsupported source features fail the cook instead of silently
flattening or dropping authored behavior.

Runtime content lookup is explicit. Installed content lives beneath the
application prefix (initially `share/incinerator/content`) and is addressed
through a configured content root plus logical bundle key. Runtime code does
not infer content from the process working directory. Tests and development
runs may pass a generated cache path explicitly. Missing, corrupt, unsupported,
oversized, and I/O-failed bundles produce structured load failures.

Workers read and validate bounded cooked bytes and publish owned plain-data
payloads through a bounded completion boundary. They never receive Runtime,
Flecs, Jolt, SDL GPU, renderer, editor, or feature-private pointers. The main
thread alone commits logical state and submits GPU work.

Logical district activation is independent of GPU residency. Simulation may
activate against a validated payload at a fixed-tick boundary while the visual
host resolves fallback resources. A separate generational registry publishes
resident resources only after upload completion and invalidates them only after
feature presentation no longer refers to that generation.

S3-A uses a deterministic procedural producer of the same logical district
definition to prove worker, physics, persistence, and cancellation ownership.
It is conformance content, not an alternative production packaging path. S3-B
must add a tiny self-authored, provenance-recorded cook fixture before the
engine claims cooked-content installation or complete glTF preservation.

## Ownership and Cancellation

- Every request has a coordinate/key and nonzero monotonic generation ticket.
- Queues, decoded bytes, uploads, and resident resources have configured
  capacity and byte limits.
- Same-tick cancellation wins over completion; stale completions are released
  without publication.
- Pre-submit GPU cancellation releases provisional resources. Post-submit
  cancellation marks discard-on-completion and never attempts to reuse or
  republish a consumed command buffer.
- Shutdown stops admission, cancels work, joins workers, drains owned payloads,
  retires pending/resident GPU resources on the main thread, and only then
  destroys renderer/backend state.

## Packaging and Provenance

The open engine package contains no unprovenanced game content. Engine test
fixtures must be self-authored or have recorded redistribution provenance and
must be narrowly scoped to the contract they prove. Game bundles are installed
and licensed separately from the engine. Large-source storage policy (Git LFS
versus an artifact store) remains a distribution decision once real game
content enters the cook pipeline.

## Consequences

- Runtime startup and streaming are relocatable and independent of repository
  layout.
- Source-format upgrades and decoder replacements are isolated to the cooker.
- Cooked schema changes are explicit greenfield cohort changes; backward
  compatibility is not implied.
- The first streaming slice can remain small without blessing the current
  prototype glTF loader as architecture.
- S3 is delivered in A/B/C stages: procedural/headless ownership, cooked/GPU
  residency, then boundary-driven installed native evidence.

## Deferred

- patch/delta distribution, compression/encryption, CDN delivery, signatures,
  and live content version negotiation;
- a general VFS, asset dependency graph, hot reload, and editor asset database;
- game bundle licensing and large-source storage selection;
- secondary-platform cooked formats and server/client content partitioning.
