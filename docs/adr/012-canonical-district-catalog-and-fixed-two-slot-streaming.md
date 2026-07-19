# ADR-012: Canonical District Catalog and Fixed Two-Slot Streaming

**Status:** Accepted, implemented, and validated in S6
**Date:** 2026-07-13
**Amended:** 2026-07-19 after the physical traversal and vehicle–NPC collision review

## Context

S3 proves one cooked district and one complete streaming lifecycle. S6 must
prove two adjacent self-authored districts, deterministic selective cooking,
installed coordinate lookup, exact content cohorts, adjacent residency
overlap, and restart/replay without turning that slice into a general VFS,
asset database, or open-ended streaming framework.

At S6 entry, the content root, workers, district feature, presentation
coordinator, and host were deliberately singleton. The GPU scene registry
already owned four scene slots and two upload batches, so adding a second
registry or renderer abstraction was unnecessary. The entry replay cohort
described one bundle, and several hosts duplicated its admission logic.

## Decision

### One bounded canonical catalog

Runtime content contains one explicit, integrity-protected little-endian
district catalog. It has a small fixed entry/edge/string/file budget and no
directory enumeration. Each entry binds:

- a stable semantic ID and chunk coordinate;
- a validated cooked bundle key;
- district recipe version and authoritative logical checksum;
- exact bundle format/schema/source/integrity identity;
- a sorted list of semantic dependency edges.

Encoding normalizes declaration order. Decoding requires canonical entry and
edge order and rejects duplicate semantic IDs, keys, coordinates, or edges;
missing/self dependencies; cycles; incompatible versions; malformed bounds;
and integrity failure structurally. The catalog identity is domain-separated
from a bundle identity and covers every coordinate, logical checksum, bundle
identity, and dependency edge. Absolute paths, timestamps, directory order,
runtime handles, and platform-native layout never enter canonical bytes.

Catalog dependencies are cook/install/cohort dependencies, not residency
dependencies. They define a deterministic reverse affected closure while host
proximity alone controls logical/GPU residency.

### Exact admission precedes activation

One renderer/filesystem-neutral admitted-catalog boundary opens the catalog,
validates every referenced bundle and coordinate-specific logical build, and
constructs the replay/save cohort. Live scene requests carry the exact expected
bundle identity copied from that immutable admission. A valid bundle replaced
after startup therefore fails identity comparison in the worker and never
reaches logical or GPU activation.

Replay and saves use the domain-separated admitted catalog fingerprint. The
S6 implementation initially retained its preceding single-bundle cohort only
as a transitional test identity; greenfield cleanup removes that legacy
variant rather than maintaining two content authorities. A one-entry catalog
does not alias an older wire identity. The save envelope carries the admitted
catalog fingerprint, and no old save/capture compatibility is promised.

### Real dependency-aware cooking

The host-only cooker receives an explicit coordinate plus sorted dependency
bundle identities. A dependency is a real build input, so Zig's cache graph
implements the declared closure. The west fixture remains dependency-free; the
east boundary fixture depends on west. Changing east rebuilds east and the
catalog. Changing west rebuilds west, east, and the catalog. Source digests are
domain-separated and include dependency semantic IDs and canonical bundle
identities, never paths.

The cooker derives static collision from the sandbox-owned canonical district
recipe for the declared coordinate. Reusable district contracts retain only
payload shapes, bounds, checksums, and structural validation. Authored visual
transforms remain in each source fixture.
Both fixtures and provenance records are project-owned conformance content;
game-owned `assets` remain excluded.

### Fixed two-slot authority and one worker

`DistrictFeature` becomes a fixed two-slot lifecycle owner. It may hold two
active districts but at most one loading/cancelling transition because the
existing logical loader is a one-job worker. Requests allocate the lowest free
slot deterministically and use one global monotonic ticket generation. Exact
tickets route cancel/unload and typed outcomes. Duplicate coordinates,
capacity, loader busy/stale, and wrong-state requests are bounded rejections.

Extraction, persistence, logical digests, and diagnostics publish both slots in
canonical coordinate/identity order. Restore is whole-operation transactional:
failure while restoring the second record destroys the first and returns to
the empty baseline.

The visual host owns two fixed stream slots, each with its catalog entry,
hysteresis, presentation coordinator, state, correlation, pending bundle, and
scene handle. They share one content worker and the existing GPU registry. One
slot can drain while the other stays active. Per-handle residency, not global
registry emptiness or aggregate pump attribution, determines slot completion.

Adjacent centers are 16 units apart. The load/unload margins deliberately
produce a bounded overlap band in which both logical districts and both scenes
may be resident. The S6 host admits at most one new transition per fixed-tick
reconcile pass in canonical catalog order.

### Current sandbox route is wholly resident without a containment perimeter

The current product contains exactly the two catalogued route districts. The
normal sandbox composition therefore pins both logical and GPU route slots
resident after admission. Streaming validation profiles still exercise the
real load, overlap, cancellation, unload, and reload lifecycle; the playable
product does not expose that lifecycle as unexplained block pop inside its
entire authored route.

Recipe version 4 briefly added collision-backed perimeter walls around those
two districts. Physical testing showed that this was the wrong response to a
distance/presentation defect: it prevented the tester from reaching the
condition instead of validating and repairing it. Recipe version 5 removes
those walls from both collision and proxy presentation. The two original
obstacle boxes remain canonical visible blockers.

The infinite checkerboard is renderer-diagnostic terrain, not completed game
content, but characters and vehicles may traverse it. Content-owned actions in
sparse space may reject explicitly until more districts exist. Expanding
content and streaming—not containment geometry—is the accepted path toward the
open sandbox.

The graphical host resolves third-person camera obstruction against the same
live physics world and keeps the camera on the target side of the first hit.
This is a read-only value query: district/Jolt identities remain owned by the
simulation placement. Visible route collision must not turn into an opaque
full-screen surface merely because the orbit camera crossed behind it.

## Consequences

### Positive

- Installed content selection is deterministic, exact, and working-directory
  independent.
- Source changes rebuild a real declared closure without a general asset graph.
- Save, replay, live streaming, and restore share one admitted content truth.
- Two-district overlap is proven with fixed capacities and one worker.
- The complete current route does not visually enter or leave while it is
  being played, while traversal remains available beyond current content.
- Follow-camera placement respects the same collision-backed boundary exposed
  to players and vehicles.
- Existing GPU registry and one-district presentation coordinator remain
  reusable rather than being replaced.

### Negative

- The catalog, feature, host, and diagnostics schemas all require explicit S6
  cohort changes.
- East depends on west for the conformance seam, so a west change deliberately
  invalidates both bundles.
- Diagnostic space beyond the authored route is sparse and may reject
  district-owned interactions until subsequent content slices expand coverage.
- One worker serializes preparation; S6 measures this before considering more
  concurrency.

## Explicit Nonclaims

S6 is not a VFS, general asset database, hot-reload service, CDN/patcher,
arbitrary dependency resolver, open-world quadtree, origin-rebasing system,
unbounded concurrent streamer, migration framework, or secondary-platform
content format. Dependencies do not pin runtime residency. Multiplayer remains
deferred.
