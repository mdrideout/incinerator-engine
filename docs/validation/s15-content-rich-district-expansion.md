# S15 Content-Rich District Expansion Validation

**Status:** Accepted; implementation, automated/native evidence, and
product-owner walkthrough complete

**Plan:**
[S15 Content-Rich District Expansion](../design/s15-content-rich-district-expansion.md)

**Decision:**
[ADR-028](../adr/028-content-rich-four-district-cohort.md)

## Phase Ledger

| Phase | Status | Evidence |
|---|---|---|
| S15-A — decision and cohort | Accepted | ADR-028, exact coordinate list, recipe 8, population catalog 2, snapshot 15, replay 18, protocol 17, and roadmap promotion |
| S15-B — cook and admission | Accepted | Four deterministic bundles, canonical dependency diamond, byte-identical repeated cook, exact catalog lookup/closure, relocation, and headless cohort `fcdabbf6…af503` |
| S15-C — logical world/support | Accepted | Four transactional district slots and bootstrap records; one composition support plus eight district obstacle bodies; no floor duplicate or perimeter |
| S15-D — navigation/activity | Accepted | 32-node/64-edge graph, four-seam circuit, live north-row detour, 24 destinations/activity slots, 32 spawn slots, and three ordinary members initially in each district |
| S15-E — presentation/diagnostics | Accepted | Four simultaneous Metal scenes at 10,112 resident GPU bytes, four exact diagnostic slots, complete baseline publication, cross-row stable population identity, and full-world NPC projection |
| S15-F — acceptance/cleanup | Accepted | `verify-s15` 191/191 steps and 428/428 tests; editor-on/off repository aggregates pass 1,004/1,004 tests; two-rate Metal; performance baseline; source/doc/dead-assumption audit; product-owner walkthrough accepted 2026-08-18 |

## Required Commands

```sh
zig build test-content-cooker test-district-content-catalog test-district-feature
zig build test-navigation-planner test-sandbox-navigation
zig build test-sandbox-population test-sandbox-population-placement
zig build measure-s12 measure-s13 -Doptimize=ReleaseFast
zig build smoke-installed-s13-macos -Deditor=true --summary all
zig build verify-s15 -Deditor=true --summary all
zig build test -Deditor=true --summary all
zig build test -Deditor=false --summary all
```

## Recorded Evidence

- Four bundles are 4,364 / 4,360 / 4,364 / 4,360 bytes; the catalog is
  824 bytes. Repeated cooks are byte-identical.
- The installed Metal product stages 3,888 CPU bytes and 2,528 GPU bytes per
  scene, retains all four scenes, and reports 10,112 resident GPU bytes.
- The two-rate Metal population journey completes 960 authority ticks at both
  240 Hz and 40 Hz, retains all twelve ordinary members after reaching the
  full cohort, sees all four district draws, and observes a stable member on
  both rows.
- The 32-node planner measured p99 1.522 ms under the 4.166 ms ceiling. The
  six-controller movement meter recorded no blocked actors or teleport
  rollback; the live detour test reaches its destination through the north
  row after the south seam closes.
- Twenty-four activity-slot CharacterVirtual placements admit against exactly
  one support plus eight obstacle bodies with zero rejection or separation
  violation. See the [S15 baseline](../performance/s15-baseline.md).
- `zig build verify-s15 -Deditor=true --summary all`: 191/191 steps and
  428/428 tests passed.
- `zig build test -Deditor=true --summary all`: 300/300 steps and 1,004/1,004
  tests passed.
- `zig build test -Deditor=false --summary all`: 297/297 steps and
  1,004/1,004 tests passed.

## Evidence Requirements

- deterministic repeated cook and exact dependency closure;
- installed relocation and headless cohort agreement;
- transactional four-district restore and replay;
- solo/listen/dedicated four-district activation/publication;
- full circuit route plus gate/displacement/content-wait recovery;
- ordinary north-row activity, death, and safe replacement;
- singular flat support collision ownership;
- four-scene GPU residency and clean drain;
- schema-5 incident evidence without truncation;
- two-rate installed Metal journey; and
- performance/resource comparison against S13 and DR1.

## Product-Owner Walkthrough

The product owner reported the four-district product verified on 2026-08-18
and supplied no corrective finding. This closes S15. The accepted follow-up is
the [Engine Authoring Foundation](../design/engine-authoring-foundation.md),
which begins the ownership work originally assigned broadly to G1 through
concrete material, vehicle, lighting, and map-authoring consumers.
