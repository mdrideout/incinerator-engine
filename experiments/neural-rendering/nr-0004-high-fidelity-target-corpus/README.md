# NR-0004 — High-Fidelity Target and Paired-Corpus Foundation

**Status:** Accepted for the initial NR5-A/B structural scope

**Date opened:** 2026-08-08

**Governing plan:**
[Title Neural Renderer Implementation Plan](../../../docs/design/title-neural-renderer-implementation-plan.md)

## Question

Can Incinerator manufacture exact, rights-clean high-fidelity visual truth for
the same deterministic presentation state, with enough identity/depth evidence
to reject attractive but structurally invalid pairs before training?

## Hypothesis

A narrow Blender/Cycles adapter can reconstruct engine-owned camera, geometry,
identity, material intent, and lighting from an immutable presentation package.
The target can add materially richer texture, lighting, shadow, reflection,
glass, emission, and edge quality without changing authored world state.

NR-0004 trains no model. Its output is the trusted paired corpus and the
evidence required before NR-0005 may initialize a title renderer from scratch.

## NR4-A implementation

The first gate contains:

- one validation-only 26-draw urban-corner fixture with road, sidewalk,
  masonry storefront, glass, emissive fixtures, thin objects, a four-wheel
  vehicle, character, NPC, carryable, and crate;
- one adapter-local `incinerator.nr4.blender-target-frame.v1` package exported
  from the same immutable camera and draw plans as the engine capture;
- six 400×225 deterministic input channels and one 1600×900 high-fidelity
  target of the exact selected frame;
- pinned Blender 4.5.12 LTS/Cycles Metal with 256 fixed samples, seed 73,
  scene-linear float32 OpenEXR, AgX display output, and learned denoising off;
- object identity, linear depth, normal, source/environment provenance,
  synchronized alignment, and review-sheet evidence; and
- absent-root runners, a strict inspector, and two-run reproducibility
  comparison.

All fixture geometry, procedural materials, scripts, and lighting intent are
repository-owned. No external art, pretrained model, learned denoiser,
pseudo-target, or model-derived loss enters the lineage.

## Executed evidence

Canonical external root:

```text
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-a-technical-20260808-v2
```

Both fresh runs completed with exactly 26 cheap/source draws and 26 exported
target draws. Engine frame identity, camera, effects, all six input hashes,
conventional target, identities, and normalized target package reproduced
exactly. Target object identity and depth are byte-identical.

Both synchronized reports measured:

- 455,824 nearest-upsampled source fixture pixels;
- 452,792 target fixture pixels;
- 445,350 exact identity pixels;
- 456,695 union pixels; and
- 0.975158 exact identity-over-union, with no missing target identity that was
  visible in the cheap source.

Cycles target render time was 5.531 seconds and 5.520 seconds after the pinned
environment was warm. Display output differed by at most one 8-bit value.
Float32 normals differed by at most 4.768e-7 absolute error with 1.148e-8 RMSE;
the comparison records this observed Metal renderer noise without inventing a
pass threshold.

Each run also snapshots and hashes all 11 adapter/configuration tool sources.
The strict inspector verifies the Cycles target's declared renderer/common
source hashes against that immutable snapshot.

Start review with:

```text
acceptance.json
reproducibility.json
run-a/evaluation/nr4-a-review.png
run-b/evaluation/nr4-a-review.png
```

The source/target scene cohort and projection have been visually inspected in
both runs. Remaining magenta/cyan pixels in the alignment view are localized
raster/geometry edge differences rather than state substitution.

## NR4-A disposition

The automated/technical NR4-A proof passes. On 2026-08-08 the product owner
explicitly accepted the upper-right target as a sufficiently rich visual
direction worth expanding into moving sequences. The target and source depict
the same authored scene closely enough to close the first gate.

## NR4-B implementation and evidence

NR4-B advances the adapter-local target package, without a compatibility
decoder, to `incinerator.nr4.blender-target-frame.v2`. The package now declares
material response, local-light state, and causal sequence events. The accepted
engine-owned `incinerator.neural-input.v1` model ABI remains unchanged until
NR4-C can justify additions from observed ambiguity.

One proof contains 18 frames across six isolated three-sample segments:

1. camera motion with fixed object/light state;
2. rigid vehicle motion with fixed camera/articulation/light state;
3. a near-edge camera pass with fixed object/light state;
4. wheel roll and front steering with fixed chassis/camera/light state;
5. NPC occlusion/disocclusion with every other owner fixed; and
6. sun, world, local-light, and emissive response with fixed camera/transforms.

Canonical external root:

```text
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-b-technical-20260808-a
```

Both fresh runs contain all 18 source captures, target packages, 1600×900
Cycles targets, object identity, depth, normal, per-frame alignment, causal
audit, command logs, and synchronized overview/detail sheets. Engine captures,
normalized packages, target identity, and target depth are exact across runs.
Identity-over-union spans 0.974974–0.987851 with no cheap-visible identity
omitted. Repeated display output differs by at most 1/255 and normal evidence
by at most 5.960e-7 absolute / 1.608e-8 RMSE.

The two runs report 132.762 and 133.374 seconds of total Cycles target time.
The full retained evidence root is approximately 2.5 GB. Agent visual review
finds that the richer target remains faithful over every declared transition;
the near-edge composition is severe by design and every visibility change is
explained by its camera event.

The three cheap conventional-target hashes in the lighting-effect segment are
identical even though the exact Cycles outputs change with the declared sun,
world, local-light, and emissive state. NR4-B therefore supplies one concrete
NR4-C ambiguity to investigate. It does not preselect a new input channel.

Start review with:

```text
acceptance.json
reproducibility.json
run-a/evaluation/reports/nr4-b-sequence-review.png
run-a/evaluation/reports/segment-00-camera_motion.png
...
run-a/evaluation/reports/segment-05-lighting_effect.png
```

## NR4-B disposition and current gate

The NR4-B technical gate passes. On 2026-08-08 the product owner reviewed the
synchronized sequence overview and explicitly accepted the moving target
direction. The original external `acceptance.json` remains immutable with its
pre-review `pending_human_sequence_target_and_alignment_review` value; this
committed disposition is the subsequent human decision.

NR4-C is now authorized to reuse the adapter and causal scenario definitions,
regenerate the native cohort, and obtain fresh native target acceptance. Only
then may it audit ambiguity and propose evidence-backed deterministic input
controls. Dataset assembly, model training, export, promotion, and runtime
selection are not authorized by this checkpoint.

### NR4-C native working cohort

New proof work uses `160×90` cheap appearance/default controls and direct
`400×225` high-fidelity Cycles targets. This is an explicit 2.5× linear
reconstruction at the same 16:9 aspect ratio. NR4-A/B remain immutable
historical records of the target adapter and correspondence method, but their
target pixels, metrics, and acceptance are excluded from the active cohort.

Before control ablations, NR4-C must prove exact non-integer pixel mapping,
generate and freshly accept a native `400×225` target still, regenerate all 18
causal frames from native `160×90` inputs and direct native `400×225` targets,
establish nearest/bilinear/bicubic baselines, and record the new capture,
target-render, decode, memory, and evidence costs. A control may use the
`400×225` structural extent only after its measured benefit justifies it.

Review reports retain only the native `160×90` and `400×225` artifacts. A UI
may zoom panes for legibility without emitting or accepting a different-
resolution derivative.

Other output extents are outside NR4-C through the first NR5 proof.

## NR4-C native implementation and evidence

NR4-C advances the whole active cohort without a compatibility decoder:

- `incinerator.neural-input.v3` renders all six inputs directly at `160×90`
  and owns four explicit frame-global lighting/material controls;
- capture schema 4 stores those native inputs plus the exact 16-byte control
  payload and no conventional product target;
- `incinerator.nr4.blender-target-frame.v4` declares the native `160×90`
  input, direct `400×225` target, and exact top-left pixel-center 5:2 mapping;
- the target adapter renders scene-linear float32 OpenEXR directly at
  `400×225`; and
- every consumer rejects foreign extents rather than resizing an old target.

The first native tools generated two independent still proofs and two
independent 18-frame sequence proofs from fresh absent roots:

```text
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-c-native-still-20260808-b
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-c-native-sequence-20260808-b
```

The still gate reproduced every captured input, normalized target package,
target identity, target depth, and display pixel. The sequence gate reproduced
the same facts for all 18 frames. Repeated sequence displays differ by at most
1/255; float32 normals differ by at most `9.537e-7` absolute and `1.767e-8`
RMSE. Identity-over-union spans `0.940195–0.976374` with no input-visible
identity omitted by the direct target.

Run A renders the 18 direct targets in 14.862 seconds total
(`0.646–1.516` seconds each). The validation capture records 2.725 ms total
CPU command-encoding time over its 18 selected input frames, with 0.229 ms
maximum. This is not GPU raster time; the current SDL GPU surface does not
provide that measurement. Per-pair display decode averages 6.454 ms. Nearest,
bilinear, and bicubic baselines average 0.057, 0.365, and 0.564 ms
respectively. Blender peak process RSS reaches 540,540,928 bytes; pinned
Cycles does not expose GPU-memory residency to the adapter, and the manifest
records that limitation explicitly.

One run contains 11,064,553 bytes of native input capture, 359,158 bytes of
target-frame packages, 65,751,976 bytes of direct target evidence, and
11,607,072 bytes of alignment/baseline/report evidence. The full two-run
sequence root is 178,312,689 bytes. The separate two-run still root is
9,565,341 bytes.

The reports deliberately show the native input, an explicitly UI-only nearest
zoom, the direct native target, and deterministic resize baselines. Only the
raw native `160×90` channels and direct native `400×225` target are eligible
training material. No neural output exists yet; model training remains
blocked until the target review, ambiguity audit, corpus assembly, and coverage
gates close.

Start review with:

```text
nr4-c-native-still-20260808-b/acceptance.json
nr4-c-native-still-20260808-b/run-a/evaluation/native-baselines/native-160x90-to-400x225-review.png
nr4-c-native-sequence-20260808-b/acceptance.json
nr4-c-native-sequence-20260808-b/run-a/evaluation/reports/nr4-c-native-sequence-review.png
```

The technical gate passed. Agent visual audit found synchronized geometry,
intended material/lighting enrichment, and explainable edge-only alignment
deltas. On 2026-08-08 the product owner explicitly accepted the native
`160×90 → 400×225` target and alignment direction.

The native ambiguity audit is retained separately at:

```text
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-c-native-ambiguity-20260808-b
```

Camera, object, near-edge, wheel, and occlusion target changes all alter
meaningful native input channels. The lighting/effect segment does not: scene
lighting and material response change while appearance, depth, normal,
semantic, and instance remain byte-identical. Only motion B changes, which is
the history-validity bit caused by segment reset and is not a lighting owner.
The current model input is therefore semantically many-to-one for this segment.

The closing ablation advanced the active cohort to input schema v3, capture
schema 4, and target-frame schema v4. It adds exactly four presentation-owned
float32 values per frame: sun, world, local-light, and emissive strength. The
fresh accepted evidence is retained at:

```text
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-c-global-controls-still-20260808-a
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-c-global-controls-sequence-20260808-a
```

Without the values, `lighting_effect` is ambiguous. With them, every declared
target change has a deterministic input owner in both independent runs. The
cost is 16 training bytes per frame, zero additional GPU raster targets, and
zero additional raster pixels. A spatial illumination channel, target-extent
control, material-ID bundle, or generic candidate-channel bundle remains
unjustified.

The accepted sequence reproduces exact engine capture, normalized packages,
target identity, and target depth across two runs. Display output varies by at
most 1/255 and normal output by at most `6.557e-7` absolute / `1.774e-8` RMSE.
Run A renders all 18 targets in 15.365 seconds and peaks at 544,800,768 bytes
of Blender process RSS. The accepted two-run sequence root is approximately
173 MiB and the still root approximately 9.4 MiB.

## NR4-C disposition

NR4-C is accepted. It proves the native working resolution, exact mapping,
rights-clean target direction, moving correspondence, deterministic recapture,
and the minimal controls needed by the only observed ambiguity. No model was
trained and no runtime bundle was promoted. NR4-D may now assemble the paired
corpus; spatial controls remain conditional on a future controlled-fit failure.

## NR4-D implementation and evidence

NR4-D adds deterministic corpus camera programs and one generic paired-sequence
runner without weakening the locked NR4-C causal proof. It generates six fresh
whole sequences: one controlled overfit, one train, one validation, one sealed
test, and two stress sequences. Every sequence contains 18 native pairs and is
fully rendered, aligned, and inspected before assembly.

The corpus transaction starts partial, copies each complete immutable run into
a self-contained root, and becomes complete only after it verifies one frame
identity join across capture, target package, HDR target, target auxiliaries,
rights, and provenance. It indexes all six raw input channels, the 16-byte
global controls, scene-linear target EXR, identity, depth, and normal with exact
sizes and SHA-256 digests. Display derivatives are explicitly ineligible for
training. Whole-sequence split ownership, a sealed test policy, common source
provenance, and cross-sequence conditioning/pair uniqueness fail closed.

Canonical external evidence:

```text
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-d-corpus-20260808-b
```

The fresh absent-root proof contains 6 sequences and 108 pairs: 18 each for
overfit, train, validation, and test, plus 36 across two stress sequences. All
source runs and the copied corpus pass the strict inspector. Exact
identity-over-union spans `0.913698–0.977032`, with no input-visible identity
omitted. Cycles renders total 86.245 seconds (`0.544–1.662` seconds per target)
and peak Blender process RSS is 546,144,256 bytes.

The complete retained proof root is approximately 1.0 GiB, including the
source runs, a 506 MiB self-contained corpus, logs, reports, and immutable tool
snapshots. The compact split review was visually inspected: camera diversity
is present, every target preserves the authored scene, and material/lighting
enrichment remains coherent. It contains 15 panels from overfit, train,
validation, and stress only. The fresh camera-cut test sequence is mechanically
inspected but contributes no pixel to the review report.

The earlier `nr4-d-corpus-20260808-a` root is superseded because its review
sheet opened the nominal test frames. It is retained as diagnostic evidence,
not accepted corpus evidence. The `-b` root generates a new test sequence and
enforces `test_frames_included=false` as an executable report contract.

The corpus inspector has focused negative contracts for artifact corruption,
removal, and cross-sequence digest leakage; the underlying strict sequence
inspector already rejects schema, provenance, target-package, frame identity,
alignment, rights, and missing-artifact drift. No model was trained. NR4-D's
technical gate passes; NR4-E now owns explicit coverage review and the final
NR-0004 corpus acceptance decision.

## NR4-E disposition

On 2026-08-09 the product owner accepted the NR4-D review sheet. The coverage
tool then inspected the exact accepted corpus without decoding or publishing
sealed-test pixels and retained its result at:

```text
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-e-coverage-20260809-b
```

The ledger accepts this corpus for NR5-A framework validation and NR5-B
controlled spatial overfit. It does not accept title-wide generalization,
temporal or learned-detail training, promotion, or runtime selection. Those
claims remain blocked by the explicit coverage gaps in `coverage.json` and
`coverage.md`. The accepted environment and coverage-tool sources are
snapshotted beside the ledger. NR5-B must verify this exact authorization and
corpus digest before it can start.
