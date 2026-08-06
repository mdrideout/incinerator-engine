# NR0 Neural Rendering Feasibility Validation Ledger

**Status:** Preliminary NR-0001 pipeline evidence recorded; NR0 acceptance open

**Date:** 2026-08-05

This ledger will record executed evidence for
[the NR0 plan](../design/nr0-neural-rendering-feasibility.md). Documentation and
directory scaffolding are not implementation acceptance.

## Required evidence

| Area | Required proof | Status |
|---|---|---|
| Buffer ABI | Exact format/convention tests and human debug views | Product RGB boundary proven; auxiliary ABI/debug views not started |
| Paired capture | Atomic manifest, fingerprints, alignment, split integrity, and provenance | Preliminary exact same-frame product-color capture passed across three S13 runs; full NR0 paired corpus open |
| Spatial baseline | Overfit proof followed by held-out comparison to non-neural baselines | Preliminary engine-capture model beat bicubic on whole-run validation/test splits |
| Promotion | Source-preserving transactional copy, digest/schema verification, exact selection | Not started |
| Runtime | Installed Apple Silicon inference with GPU-owned textures and visible model identity | Preliminary explicit-path Core ML proof passed; blocking CPU staging and no promoted bundle prevent acceptance |
| Fallback | Missing/rejected model, resize, cut, device/inference failure, and recovery | Missing-model conventional fallback passed; remaining transitions open |
| Boundaries | No training dependency or authority/private-gameplay access | Product-only texture input and cold/headless boundary passed; source audit remains at NR0-G |
| Performance | End-to-end latency, GPU time, frame pacing, and memory on named hardware | Preliminary standalone and staged timings recorded; full GPU/frame/memory profile open |
| Diagnostics | Debug views plus incident evidence for model/history/fallback state | Console model/path/state/failure/timing plus captured input/output/target implemented; editor/incident integration open |
| Human acceptance | Motion, identity, detail, disocclusion, effects, UI, fallback, and recovery | Not started |

## Acceptance conclusion

NR-0001 proves the local technical loop and rejects the CPU-staged adapter as a
final architecture. It does not accept NR0. The generated model is an external
candidate only and must not be copied into `models/neural-rendering/`.

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
