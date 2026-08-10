# NR0 Neural Rendering Evaluation Scene

**Status:** NR0-A/B conformance, NR0-C spatial baseline, and NR0-D failure
fixture accepted

**Date:** 2026-08-08

## Purpose

The NR0 scene is one bounded but demanding vertical-slice cohort. It must expose
model and buffer failures clearly without pretending to represent the final GTA-
style city.

## Scene requirements

The scene should contain:

- rigid static geometry with long edges, thin features, occlusion, and depth
  layers;
- several material identities covering matte, glossy, metallic, emissive,
  patterned, and alpha-tested surfaces;
- one moving character, one NPC, one vehicle with rotating/steering wheels, and
  one carryable using stable presentation identities;
- predictable sunlight, shadow boundaries, local emissive light, and controlled
  exposure changes;
- at least one explicitly represented transparent or volumetric effect only
  after its input field is defined;
- camera translation, rotation, near-object passage, disocclusion, a cut, and a
  resize; and
- ordinary post/UI content composited after the inferred scene.

Use the current fixed-rate authoritative simulation and replay boundaries. The
scene should reuse existing engine capabilities where they provide the needed
pressure, but its source assets and camera program remain a separate NR0
fixture so gameplay validation is not coupled to training data.

NR0-A/B deliberately use the existing deterministic S13 population scene as a
conformance cohort. It already pressures stable character, NPC, vehicle,
carryable, district, authored-scene, and repeated-part identities across moving
frames. NR0-C adds real default-follow, close-orbit, wide-orbit, and elevated
camera programs and accepts the first multi-channel spatial reconstruction
baseline. NR0-D now adds 23 presentation-only stable identities, rigid and thin
geometry, small objects, repeated depth layers, a moving occluder, rotating
parts, camera cuts, top-down composition, and real resize transitions. Its six
stress cohorts are immutable evaluation data and never become gameplay or
authority state.

The current renderer and input ABI do not explicitly represent roughness,
metallic, emissive, alpha-test, transparency, or volumetric causes. NR0-D
therefore records those as capability gaps rather than pretending flat-color
primitives satisfy the original material/effect requirements. Exposure is
recorded metadata but is not an NR-0002 input plane.

This fixture is consequently not the NR-0004 high-fidelity target scene.
ADR-026's [north star](title-neural-renderer-north-star.md) requires a separate
materially rich, exactly paired title slice before from-scratch product-model
training. NR0-D remains a reusable source of structural, identity, temporal,
cut, resize, and failure scenario/metric definitions. Later candidates
recapture those scenarios at their native declared extents; earlier frames and
results do not cross into the active cohort.

## Capture cohorts

NR0-A through NR4-B historically used different extents. Those immutable
artifacts remain audit history only and are excluded from the active cohort.

NR4-C and the first NR5 proof instead use `160×90` cheap appearance/default
controls and `400×225` high-fidelity targets for fast local iteration. The
2.5× linear mapping is part of the schema and must be tested explicitly.
Structural buffers may remain at `400×225` only when their measured render,
storage, and model benefit justifies the exception. The still, moving sequence,
training corpus, model output, reports, and human acceptance are all generated
natively at these declared extents. No cross-resolution reference or preview
participates. Other output resolutions are deferred.

Keep distinct cohorts for:

1. one-shot spatial overfit;
2. training camera paths and state combinations;
3. held-out validation paths;
4. held-out test paths never used for model selection; and
5. stress paths for cuts, resize, disocclusion, fast motion, effects, and
   fallback transitions.

Adjacent frames from one path cannot be split across train and test.

## Required debug presentation

The product/editor must be able to display and capture:

- cheap base image;
- each auxiliary buffer with a correct human-readable decode;
- conventional high-quality target;
- model result;
- absolute and perceptual error views;
- semantic/instance edge overlays;
- fallback state, model ID, schema, dimensions, history-valid flag, and timing;
  and
- synchronized four-up and cropped comparisons.

NR0-A/B provide the cheap and auxiliary views in the live Neural Rendering Lab,
the conventional target in capture, and a synchronized contact-sheet report.
NR0-C preserves full-frame target/baseline/model comparisons and amplified
absolute error externally. NR0-D adds exhaustive per-frame and per-instance
metrics, semantic/instance boundary views, reset-aware temporal reprojection,
disocclusion evidence, synchronized comparisons, and measured failure crops.
Live installed 17-plane model/error overlays and incident integration remain
NR0-F work.

The existing incident workflow should record model identity, schema, fallback
reason, history reset reason, inference timing, and the same visual anchors used
for ordinary human-test evidence.

## Exit evidence

The implemented fixture passed source/provenance, paired-capture, reset, and
offline inspection on 2026-08-08. The accepted external cohort contains 478
frames and is reusable by later candidate evaluation. Reuse by the installed
GPU-resident runtime remains an NR0-F acceptance requirement.
