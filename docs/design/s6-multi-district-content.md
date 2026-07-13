# S6 Multi-District Content Workflow Design

> **Historical slice design.** This was the delivery contract for the slice at
> closure. Detailed file layout, cohorts, and limitations below may have been
> consolidated later. See [ADR-012](../adr/012-canonical-district-catalog-and-fixed-two-slot-streaming.md)
> and the [cleanup plan](../../CLEANUP_PLAN.md) for current architecture.

**Status:** Complete
**Platform:** Apple Silicon macOS only

The governing decision is
[ADR-012](../adr/012-canonical-district-catalog-and-fixed-two-slot-streaming.md).

## S6-A: Canonical catalog, cooking, and admission

- [x] Add the fixed-capacity canonical catalog codec, identity, coordinate and
  semantic lookup, dependency graph, reverse affected closure, and structured
  hostile-input tests.
- [x] Make bundle cooking coordinate-aware and dependency-aware while
  preserving the dependency-free S3 fixture identity.
- [x] Add the distinct self-authored east fixture and provenance; install both
  bundles, both provenance records, and the catalog.
- [x] Prove independent deterministic cooks and the real west -> east ->
  catalog build closure.
- [x] Add one shared admitted-catalog boundary and exact per-worker bundle
  identity checks before ready publication.
- [x] Add a domain-separated catalog `ContentCohort` while pinning the legacy
  single-bundle fingerprint and wire round trip. This records the S6 delivery
  state; cleanup C1 later removed that transitional identity entirely.

## S6-B: Fixed two-slot logical authority

- [x] Refactor `DistrictFeature` to two fixed lifecycle slots with one worker,
  exact ticket routing, typed duplicate/capacity/busy failures, and canonical
  extraction/diagnostics/logical state.
- [x] Make 0/1/2 district persistence and restore transactional, unique, and
  catalog-preflighted before world construction.
- [x] Extend physics budgets, snapshot/replay cohorts, scratch capacities, and
  tests for two active districts.
- [x] Prove independent unload/reload/cancel/failure while the neighbor remains
  active and prove insertion-order-independent logical digests.

## S6-C: Adjacent visual host and closeout

- [x] Compose two fixed stream slots over one content worker and one GPU
  registry, with per-handle drain and exact outcome routing.
- [x] Add overlap-producing adjacent hysteresis and deterministic admission
  arbitration without a generic spatial streaming service.
- [x] Bump shared diagnostics to report both slots truthfully and preserve S4
  fault/export/editor consumers.
- [x] Add a native installed Metal smoke at 240 and 80 Hz covering forward and
  reverse overlap, repeated cycles, exact budgets, and complete final drain.
- [x] Run Debug/ReleaseFast/editor/source-package/aggregate macOS gates and an
  independent P0/P1/P2 review.

## Acceptance

- [x] Identical source inputs produce byte-identical west/east bundles and
  catalogs; east-only change leaves west exact, while west change affects the
  declared west/east/catalog closure.
- [x] Duplicate IDs/keys/coordinates/edges, missing/self/cyclic dependencies,
  bad cohorts, corrupt catalog/bundles, and cook failures are typed before
  activation.
- [x] Both coordinates select only through the admitted catalog and a
  post-admission bundle replacement cannot publish ready content.
- [x] Two districts reach six logical static bodies and two draws/resident
  scenes in the overlap band while respecting fixed worker/GPU budgets.
- [x] Either district can unload/reload while the other remains active; final
  drain returns every job/entity/body/draw/scene/batch/byte owner to zero.
- [x] Catalog-backed replay and cold durable restore preserve 0/1/2 district
  authority and reject catalog mismatch before world construction.
- [x] Installed content works from `/tmp`; engine packaging contains only the
  two provenanced conformance fixtures and continues to exclude `assets`.

## Explicit Nonclaims

No general VFS, asset database, hot reload, CDN/patching, unbounded graph,
open-world spatial index, origin rebasing, multiple-worker pool, migration,
networking, or secondary-platform support is introduced.
