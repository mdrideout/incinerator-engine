# NR0 Neural Rendering Evaluation Scene

**Status:** NR0-A/B conformance and NR0-C spatial baseline accepted on S13;
dedicated NR0-D art/failure fixture remains planned

**Date:** 2026-08-06

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
baseline. This still does not claim the material, lighting, transparency,
effect, camera-cut, resize, or temporal coverage needed for failure-envelope
evaluation. Those additions belong in the dedicated NR0-D fixture.

## Capture cohorts

Begin with exact 1600×900 target output and 400×225 cheap appearance input.
Higher-resolution structural buffers are permitted only when their measured
render/memory cost is recorded.

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
absolute error externally. Live model/error overlays and incident integration
remain NR0-D/F work.

The existing incident workflow should record model identity, schema, fallback
reason, history reset reason, inference timing, and the same visual anchors used
for ordinary human-test evidence.

## Exit evidence

The fixture is accepted only when its source/provenance is explicit, its paired
capture is inspectable, every required buffer aligns at moving boundaries, and
the same replay/camera cohort can be used by offline evaluation and the
installed runtime smoke.
