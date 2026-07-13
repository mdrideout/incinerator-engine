# S3-B Cooked Content and GPU Residency Acceptance

> **Historical phase record.** This document preserves the evidence and claims
> recorded when this slice closed. Counts, cohorts, platform results, and
> limitations below describe that dated tree, not current support. See the
> [current macOS readiness record](macos-readiness.md) and
> [cleanup plan](../../CLEANUP_PLAN.md).

**Date:** 2026-07-12  
**Platform:** Apple Silicon macOS / Metal  
**Scope:** S3-B only; full S3 remains open for S3-C proximity and repeated
installed lifecycle evidence.

## Accepted Boundary

S3-B replaces the prototype runtime source-import path with three explicit
forms of content:

1. The host-only cooker reads source glTF and images.
2. The runtime worker reads a bounded, versioned, renderer-neutral bundle from
   an explicit absolute content root.
3. The visual host alone owns staged, submitted, and resident SDL GPU state.

`DistrictFeature` carries only an inert scene generation. Logical collision
activation does not inspect or wait for GPU residency. The visual host resolves
fallback geometry until the whole scene generation is resident.

## Cooked Contract

- Wire format: explicit little-endian V1; no serialized Zig struct layout.
- Integrity: canonical header and payload SHA-256 plus source/provenance digest.
- Hard file limit: 64 KiB.
- Bounded sections: strings, nodes, meshes, primitives, materials, textures,
  `VertexPNU`, `u32` indices, RGBA8 pixels, and logical static boxes.
- Validation covers sizes, offsets, strides, overlaps, references, UTF-8,
  finite transforms/geometry, identity static-box rotations, indices, texture
  ranges, and integrity.
- Lookup accepts a validated logical key beneath an absolute directory
  capability. It never falls back to the process working directory.
- Missing, inaccessible, I/O-failed, oversized, corrupt, unsupported, and
  allocation-failed cases remain distinguishable.

The engine-owned fixture is self-authored and provenance-recorded. Its two
named nodes share one mesh with different authored transforms; the mesh keeps
its material and decoded 1x2 RGBA8 texture relationship. Two independent cooks
must be byte-identical.

## Worker and Host Ownership

- `SceneWorker` admits one job, enforces monotonic generations, receives only
  an absolute root/key/limits plus allocator and I/O capability, and imports no
  Runtime, Flecs, Jolt, SDL, renderer, or game feature.
- Cancellation wins over an unpublished or published-but-unconsumed scene and
  releases decoded ownership. Poll joins the thread before moving a completion
  to the owner.
- A scene-level handle preserves nodes, shared geometry, materials, textures,
  and instances instead of flattening the district into one mesh/material pair.
- Empty extraction is required before normal unload releases a scene
  generation.

## GPU Residency

- Four fixed scene slots and two in-flight batch slots.
- At most four scenes per batch, eight meshes/materials/textures and 32
  instances per scene.
- Default caps: 16 MiB staged CPU, 16 MiB in flight, 32 MiB resident, and
  8 MiB submitted per pump.
- One batch uses one transfer buffer, one copy pass, one command buffer, and one
  fence.
- Frame pumping uses `SDL_QueryGPUFence`; streamed code contains no fence wait.
- Pre-submit cancellation releases staging immediately. Post-submit
  cancellation marks discard-on-completion and never reuses the consumed
  command buffer.
- Publication is atomic for the whole scene generation. Stale generations
  cannot resolve or release a replacement.

The existing procedural startup resources remain synchronous. “Sole GPU
owner” in this acceptance record applies to streamed district resources; their
unrelated migration is not part of S3-B.

## Evidence

- `zig build test-content -Deditor=false`: 8/8 focused codec/root/worker tests.
- `zig build test-content-cooker -Deditor=false`: deterministic double cook and
  semantic preservation pass.
- `zig build smoke-installed-content -Deditor=false`: installed bundle loads
  from `/tmp` through an explicit root.
- `zig build test-district-presentation -Deditor=false`: 4/4 lifecycle tests.
- `zig build test-district-scene-adapter -Deditor=false`: 23/23 total tests,
  including two adapter-specific preservation and invalid-index tests.
- `zig build test-district-gpu-registry -Deditor=false`: fake-backed registry,
  budget, failure, thread-affinity, and SDL declaration coverage passes in
  Debug and ReleaseFast.
- The full Debug, ReleaseFast, and editor-enabled graphs each pass all 280
  tests, including headless source/final-binary boundary checks.
- The extracted source package passes 29/29 build steps and its expanded 28-test
  headless/content graph without source-tree assets.
- `zig build run -- --verify-install` validates cooked content without SDL/GPU.
- A native sandbox startup selected Metal, staged the cooked two-node scene,
  activated the logical district, published 116 GPU bytes after fence polling,
  and rendered continuously until the diagnostic was interrupted. Controlled
  repeated shutdown evidence remains an S3-C gate.
- Independent content/cooker, GPU-residency, and host/composition reviews pass
  after targeted corrections with no remaining actionable P0/P1/P2 finding.

## Explicit S3-C Remainder

S3-B does not close full S3. S3-C still owns:

- character/vehicle-independent host proximity hysteresis;
- installed ReleaseFast `/tmp` load, cancel, unload, and reload cycles above
  and below the fixed tick frequency;
- end-to-end repeated lifecycle measurements and final independent full-S3
  reviews.
