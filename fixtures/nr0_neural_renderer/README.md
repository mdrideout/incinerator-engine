# NR0 Neural Renderer Fixture

**Status:** NR0-D deterministic code-native fixture implemented and accepted

This directory will contain the small provenance-recorded source fixture needed
by the
[NR0 evaluation-scene contract](../../docs/design/nr0-neural-rendering-evaluation-scene.md).
It is engine/sandbox conformance content, not the separately licensed game's
target art dataset.

Do not add generated frames, cooked datasets, model checkpoints, or exports
here. Those are external experiment artifacts.

The first fixture is code-native in
`src/hosts/neural_evaluation_fixture.zig`. Its exact source fingerprint is:

```text
nr0-d-fixture-v1|rigid-edges|thin-features|small-objects|depth-layers|moving-occluder|rotating-parts|stable-identities
```

It contains 23 stable presentation identities covering long edges, thin
features, small objects, depth layers, patterned and solid geometry, a moving
occluder, rotating repeated parts, and character/NPC/vehicle/crate semantic
classes. It owns no gameplay or physics state. Every plan is mirrored through
the ordinary conventional product draw and the accepted neural-input host.

The fixture intentionally makes no material or effect claim. The present
renderer/input ABI has no explicit roughness, metallic, emissive, alpha-test,
transparent, volumetric, or exposure plane. Those requirements remain visible
NR0 capability gaps rather than mislabeled colored cubes.

Use the installed validation-only `--nr0-evaluation-smoke` mode. Camera path,
capture ownership, source revision/dirty fingerprint, content/shader/schema
digests, stable identities, and actual source scene extent are recorded in the
external capture manifests. See
[`../../docs/design/nr0-d-evaluation-and-failure-analysis.md`](../../docs/design/nr0-d-evaluation-and-failure-analysis.md).

The accepted 2026-08-08 execution retained 478 complete frames across all six
stress paths. Individual camera-cut and resize reset frames remained complete;
the fixture successfully exposed thin-feature, boundary, and temporal failures
in NR-0002 without changing deterministic gameplay authority.
