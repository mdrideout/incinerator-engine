# NR0 Neural Rendering Feasibility Validation Ledger

**Status:** NR0-A through NR0-C accepted; NR0-D through NR0-G open

**Date:** 2026-08-06

This ledger will record executed evidence for
[the NR0 plan](../design/nr0-neural-rendering-feasibility.md). Documentation and
directory scaffolding are not implementation acceptance.

## Required evidence

| Area | Required proof | Status |
|---|---|---|
| Buffer ABI | Exact format/convention tests and human debug views | **NR0-A passed:** schema v1, six MRT channels, shader contracts, live lab, raw captures, and contact-sheet inspection |
| Paired capture | Atomic manifest, fingerprints, alignment, split integrity, and provenance | **NR0-B passed:** schema-2 capture and two-launch deterministic comparison passed; train/validation/test ownership is explicit |
| Spatial baseline | Overfit proof followed by held-out comparison to non-neural baselines | **NR0-C passed:** 17-plane controlled fit, disjoint camera cohorts, held-out nearest/bilinear/bicubic comparison, human review, FP16 export, and standalone benchmark passed |
| Promotion | Source-preserving transactional copy, digest/schema verification, exact selection | Not started |
| Runtime | Installed Apple Silicon inference with GPU-owned textures and visible model identity | Preliminary explicit-path Core ML proof passed; blocking CPU staging and no promoted bundle prevent acceptance |
| Fallback | Missing/rejected model, resize, cut, device/inference failure, and recovery | Missing-model conventional fallback passed; remaining transitions open |
| Boundaries | No training dependency or authority/private-gameplay access | NR0-A/B presentation contract and GPU/capture hosts plus NR0-C offline tools pass cold/headless and M5 architecture boundaries; final source audit remains NR0-G |
| Performance | End-to-end latency, GPU time, frame pacing, and memory on named hardware | NR0-C standalone Core ML latency recorded; full GPU/frame/memory and installed end-to-end profile remains NR0-D/F |
| Diagnostics | Debug views plus incident evidence for model/history/fallback state | Lab exposes six channels, schema/shader, history, identity collision, model, capture, failure, and timing state; incident integration remains open |
| Human acceptance | Motion, identity, detail, disocclusion, effects, UI, fallback, and recovery | Not started |

## Acceptance conclusion

NR0-A/B accept the engine-owned input ABI and deterministic paired-capture
foundation. NR0-C accepts the first multi-channel spatial reconstruction
candidate against the S13 conformance scene. It does not accept final art
quality, temporal behavior, the NR0-D failure envelope, promotion, or a shipping
runtime. NR-0001 remains the preliminary local loop proof; NR-0002 supersedes
it as model evidence. Both generated models remain external and must not be
copied into `models/neural-rendering/`.

Executed NR0-C evidence on 2026-08-06:

- four independent installed S13 Metal captures completed with zero failures:
  8 controlled-fit frames, 40 default-follow train frames, 12 orbit-wide
  validation frames, and 12 elevated-sweep test frames;
- the schema-2 inspector verified every raw channel, target, manifest, digest,
  identity map, and split owner; the assembler rejected cross-split sequence or
  provenance drift and declared the 17-plane model ABI;
- offline Python NR0-C contracts passed 3/3 tests; the complete repository
  passed 285/285 build steps and 963/963 tests with the training packages still
  absent from runtime/headless graphs;
- the 51,888-parameter controlled-fit model reduced MAE from 0.17685 to 0.03233;
- held-out validation reduced MAE from 0.18025 to 0.02556 and raised SSIM from
  0.8074 to 0.8710; untouched test reduced MAE from 0.18479 to 0.02556 and
  raised SSIM from 0.7981 to 0.8661;
- human inspection of train, validation, and test comparison sheets found no
  blank frame or geometry drift and confirmed restoration of target palette
  and scene structure; and
- the FP16 Core ML export agreed with PyTorch within 0.000491 maximum absolute
  error; 500 warmed standalone predictions measured 5.077 ms p50, 5.720 ms
  p95, and 5.988 ms p99 using Core ML `ALL` compute units.

Retained NR0-C evidence:
`~/Library/Application Support/Incinerator/neural-rendering/experiments/nr-0002-20260806-a`.
Start with `experiment.json`; the external folder is evidence, not source or a
runtime selection. Reproduction and exact parameters are recorded in
[`NR-0002`](../../experiments/neural-rendering/nr-0002-multichannel-spatial-baseline/README.md).

Executed automated evidence on 2026-08-05:

- `zig build test -Deditor=false --summary all`: 270/270 build steps and
  959/959 tests passed;
- installed S1 offscreen conventional smoke: 160/160 ready frames;
- three independent installed S13 captures: each completed 3,840 frames,
  960 controlled ticks, the full twelve-member cohort, and all role/activity
  observations;
- installed S13 neural run: 3,840 predictions and zero adapter failures;
- missing-model S1 run: explicit fallback, zero readbacks, and successful
  completion; and
- offline Python tool contracts: 3/3 tests passed.

Executed NR0-A/B evidence on 2026-08-05:

- `zig build test-shaders --summary failures`: neural primitive/model MRT
  shader entry points, locations, uniform sizes, samplers, and generated Metal
  reflections passed;
- `zig build test -Deditor=false --summary failures` and
  `zig build test -Deditor=true --summary failures`: full repository tests,
  installed products, and M5/M6/MP6 boundaries passed in both compositions;
- `zig build verify-nr0-ab`: two independent 3,840-frame S13 Metal runs each
  completed 964 simulation ticks, retained the full twelve-member population,
  observed every authored role/activity requirement, and captured frames 300,
  360, and 420 with zero capture failures;
- capture inspection verified six frames, schema/channel order, source and
  canonical extents, declared byte counts, SHA-256 hashes, shader/source/content
  provenance, cohort/sequence ownership, stable identity mappings, exact
  cross-channel coverage masks, grayscale depth, unit-length decoded normals,
  binary motion history, manifest-backed semantic/instance pixels, and no
  compact-ID collision;
- the two fresh launches produced identical frame identity, camera/effect
  metadata, stable mappings, six raw channel digests, and conventional target
  digests; and
- human inspection of the generated 1200×900 contact sheet confirmed aligned
  conventional/appearance geometry, readable monotonic depth, corrected +Y
  world normals, visible history/motion variation, distinct semantic classes
  and vehicle parts, and distinct instance colors.

Retained acceptance evidence for this execution:
`~/Library/Application Support/Incinerator/neural-rendering/acceptance/nr0-ab-20260805-accepted-v3`.
The external folder is evidence, not checked-in source; reproduce it with the
commands in the neural-rendering tool README.

Accepted capture provenance:

| Field | Value |
|---|---|
| Source revision | `192cf7c773dd5b0347b5edb4341617e519492f52` |
| Working-tree identity | Exact dirty-source SHA-256 recorded in each external `capture.json`; intentionally not copied into this hashed working tree |
| Content SHA-256 | `4cf1512641aa88af49b71a09c4504c528d8ef4edaa070d7a79699e88d6cce290` |
| Input schema | `incinerator.neural-input.v1`; fingerprint `nr1|rgba8|400x225|appearance-srgb|depth-view-linear-0.1-250|normal-world|motion-prev-to-current-ndc-2|semantic-palette-v1|instance-rgb24|top-left|pixel-center|reversed-y|no-jitter|exposure-1` |
| Shader contract | `nr-input-mrt-v1|primitive/model|world-normal|linear-view-depth|prev-current-ndc` |
| Compiled shader SHA-256 | `73771bbb3013f30300e419dd2d79a5fa028195659700122f12e73a94853c1bdc` |
