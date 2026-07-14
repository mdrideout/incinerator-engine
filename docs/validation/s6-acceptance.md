# S6 Multi-District Content Acceptance

> **Historical phase record.** This document preserves the evidence and claims
> recorded when this slice closed. Counts, cohorts, platform results, and
> limitations below describe that dated tree, not current support. See the
> [current macOS readiness record](macos-readiness.md) and
> [cleanup plan](../../CLEANUP_PLAN.md).

**Status:** Complete
**Platform:** Apple Silicon macOS only
**Date:** 2026-07-13

This record is governed by
[ADR-012](../adr/012-canonical-district-catalog-and-fixed-two-slot-streaming.md)
and tracks the staged checklist in
[the S6 design](../design/s6-multi-district-content.md).

## S6-A — Canonical catalog, cooking, and admission

Complete. The explicit little-endian fixed-capacity catalog normalizes entry
and dependency order, rejects malformed graphs structurally, provides forward
and reverse closure queries, and has a domain-separated identity. The real
build graph is west -> east -> catalog; the repeat graph produces byte-exact
west, east, and catalog outputs. The dependency-free west bundle retains its
S3 identity.

The shared renderer-neutral admission boundary loads only
`district/catalog.icat`, checks every coordinate recipe/checksum, decodes every
referenced bundle, compares the exact format/schema/source/integrity identity,
and compares cooked static boxes to the coordinate-specific logical build.
Every live scene request carries that admitted exact identity, so a replaced
valid bundle cannot publish ready under the original cohort.

Evidence:

- `zig build test-content-cooker -Deditor=false --summary all`: 20/20 build
  steps; four bundle-cooker tests and two catalog-cooker tests pass; both
  deterministic verifiers pass.
- `zig build test-content -Deditor=false --summary all`: 18/18 codec,
  explicit-root, worker, catalog graph, hostile-input, and replacement tests.
- `zig build test-district-content-catalog -Deditor=false --summary all`:
  admission boundary compiles and passes independently.
- `zig build smoke-installed-content -Deditor=false --summary all`: 22/22;
  both bundles and the catalog admit from `/tmp` with an explicit installed
  root.
- At S6 close, replay unit tests still pinned the preceding single-bundle
  wire/fingerprint while catalog cohorts used a separate domain marker. The
  later greenfield cleanup intentionally removed that legacy identity; the
  current cohort is recorded in the
  [macOS readiness record](macos-readiness.md).

## S6-B — Fixed two-slot logical authority

Complete. `DistrictFeature` owns exactly two lifecycle slots over one bounded
loader. It allocates the lowest free slot, routes exact tickets, permits two
active districts but only one loading/cancelling transition, and publishes
canonical coordinate/identity-ordered draws, snapshots, diagnostics, and
logical state. Restore validates 0/1/2 records and rolls back the complete
restored prefix if a later record fails.

The snapshot schema is V5 and replay schema cohort is 3. Identity scratch and
real-Jolt body budgets reserve two district authorities. Catalog admission
preflights durable records before a fresh world is constructed.

Evidence:

- `zig build test-district-feature -Deditor=false --summary all`: 20/20,
  including two-active, neighbor-preserving cancel/failure/unload/reload,
  duplicate/capacity/busy/stale rejection, restore rollback, and
  insertion-order-independent logical digests.
- `zig build test-headless -Deditor=false --summary all`: 24/24 aggregate
  tests, including two real-Jolt authorities, six district bodies, independent
  unload/reload, zero-body drain, canonical save, and fresh restore.
- `zig build smoke-installed-s4-replay-macos -Deditor=false --summary all`:
  47/47; catalog-backed capture ends with two districts and same-cohort replay
  matches before the altered ingress diverges in the district category.
- `zig build smoke-installed-s5-save-macos -Deditor=false --summary all`:
  49/49; a fresh editor/GPU-free process catalog-preflights and canonically
  restores one crate plus two districts/six district bodies.
- Extracted source package: 59/59 build steps and 95/95 tests, with S6 source,
  fixtures, catalog tools, admission, replay, and save paths included and
  `assets` excluded.

## S6-C — Adjacent visual host and closeout

Complete. The macOS visual host owns exactly two catalog-backed stream slots
over one content worker and one bounded GPU registry. Normal startup fails
before world activation unless the admitted catalog contains exactly west
`(0,0)` and east `(1,0)`. Canonical catalog-order arbitration starts at most
one new operation per reconciliation; a decoded neighbor may wait in its fixed
slot while the single logical loader completes another transition.

Every content, logical, presentation, and GPU outcome routes through its exact
generation, request ID, coordinate, ticket, and scene handle. Content
generations remain visible through active/unloading/draining diagnostics, and
only `recycleComplete(scene)` releases the exact retired generation. One
district can therefore drain and recycle without observing or blocking its
resident neighbor.

The installed native smoke traverses west-only -> overlap -> east-only ->
overlap -> west-only three times, then drains both slots. At every overlap it
checks the production developer snapshot as well as direct authority: two
active slots with distinct correlations, two exact content/logical/scene
generations, two logical entities, six static district bodies, two canonical
draws, two authored resident scenes, and truthful GPU aggregates. Final
snapshot assertions require both slots, the worker, logical state, bodies,
draws, scenes, batches, and every current GPU byte counter at baseline.

Evidence:

- `zig build smoke-installed-s6-macos -Doptimize=ReleaseFast -Deditor=false
  --summary all`: 46/46. From `/tmp`, with the content-root override removed,
  Metal completed three forward and three reverse overlaps at both cadences.
  The 240 Hz run recorded 84 frames / 42 ticks / 42 zero-tick frames / zero
  multi-tick frames. The 80 Hz run recorded 30 frames / 45 ticks / zero
  zero-tick frames / 15 multi-tick frames. Both peaked at two live/resident
  scenes, one active batch, 344 staged CPU bytes, 116 in-flight upload bytes,
  and 232 resident GPU bytes before complete drain and clean shutdown.
- The installed S3 regression gate remains green at both cadences after the
  two-slot refactor: 46/46 steps, including production resident/drained
  diagnostics and its cancellation path.
- Full post-remediation matrix: Debug editor-off 125/125 build steps and
  493/493 tests; Debug editor-on 128/128 and 493/493; ReleaseFast editor-off
  125/125 and 493/493; ReleaseFast editor-on 128/128 and 493/493.
- Extracted source package: 59/59 build steps and 95/95 tests; S6 catalog,
  fixtures, host/admission code, design, validation, and performance evidence
  are present while `assets` remains excluded.
- `zig fmt --check` and `git diff --check`: pass.
- `zig build test-macos-readiness -Doptimize=ReleaseFast -Deditor=true
  --summary all`: 70/70 serialized installed native steps, including the
  corrected S4 retained-fault fixture and all prior S2-S5 gates.
- Two independent reviews corrected two restore/activation rollback P2s and
  five host diagnostics/fail-fast/cadence/per-handle-drain findings. The final
  reviews report no remaining actionable P0/P1/P2 in S6-A/B or S6-C scope.

Resource and cadence characterization is recorded in
[the S6 native baseline](../performance/s6-baseline.md). The complete aggregate
macOS readiness gate also includes this S6 smoke serially with the prior S2-S5
native gates.
