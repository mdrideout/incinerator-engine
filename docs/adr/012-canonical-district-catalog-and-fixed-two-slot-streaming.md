# ADR-012: Canonical District Catalog and Fixed Two-Slot Streaming

**Status:** Accepted, implemented, and validated in S6
**Date:** 2026-07-13

## Context

S3 proves one cooked district and one complete streaming lifecycle. S6 must
prove two adjacent self-authored districts, deterministic selective cooking,
installed coordinate lookup, exact content cohorts, adjacent residency
overlap, and restart/replay without turning that slice into a general VFS,
asset database, or open-ended streaming framework.

The current content root, workers, district feature, presentation coordinator,
and host are deliberately singleton. The GPU scene registry already owns four
scene slots and two upload batches, so adding a second registry or renderer
abstraction is unnecessary. The current replay cohort describes one bundle,
and several hosts duplicate its admission logic.

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

## Consequences

### Positive

- Installed content selection is deterministic, exact, and working-directory
  independent.
- Source changes rebuild a real declared closure without a general asset graph.
- Save, replay, live streaming, and restore share one admitted content truth.
- Two-district overlap is proven with fixed capacities and one worker.
- Existing GPU registry and one-district presentation coordinator remain
  reusable rather than being replaced.

### Negative

- The catalog, feature, host, and diagnostics schemas all require explicit S6
  cohort changes.
- East depends on west for the conformance seam, so a west change deliberately
  invalidates both bundles.
- One worker serializes preparation; S6 measures this before considering more
  concurrency.

## Explicit Nonclaims

S6 is not a VFS, general asset database, hot-reload service, CDN/patcher,
arbitrary dependency resolver, open-world quadtree, origin-rebasing system,
unbounded concurrent streamer, migration framework, or secondary-platform
content format. Dependencies do not pin runtime residency. Multiplayer remains
deferred.
