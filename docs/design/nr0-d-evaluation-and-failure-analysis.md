# NR0-D Evaluation and Failure Analysis

**Status:** Complete; evaluation accepted, NR-0002 remains unpromoted

**Date:** 2026-08-08

**Parent plan:**
[NR0 game-specific neural-rendering feasibility](nr0-neural-rendering-feasibility.md)

**Decision:**
[ADR-025](../adr/025-game-specific-neural-rendering-boundary.md)

## Purpose

NR0-C proved that the accepted 17-plane spatial ABI can learn the existing S13
scene and beat deterministic resize baselines on held-out camera paths. NR0-D
must find where that claim stops being true. It is an evaluation phase, not a
promotion phase and not permission to hide failure behind one aggregate score.

The phase adds a deterministic, presentation-only fixture and retains enough
numerical and visual evidence to answer:

- which geometry, identity, motion, and camera conditions the candidate handles;
- where small features, semantic boundaries, instances, disocclusions, or
  history transitions fail;
- whether a spatial result is temporally readable even though NR-0002 has no
  recurrent or reprojected state;
- what the offline model, capture path, and current standalone export cost on
  the named Mac; and
- which measurements genuinely require the later installed GPU-resident NR0-F
  runtime.

## Ownership

The fixture is presentation test data. It does not add gameplay entities,
physics bodies, authority state, navigation policy, or network replication.
Its immutable draws pass through the same conventional renderer and neural
input host as ordinary presentation data.

The deterministic simulation remains authoritative. Camera programs and reset
events are capture controls only. Python evaluation reads immutable external
captures and an explicit external checkpoint; neither path selects a runtime
model or writes into `models/neural-rendering/`.

## Fixture contract

The first fixture uses only capabilities the renderer actually implements:

- long rigid edges and repeated depth layers;
- thin vertical and horizontal features;
- small objects at several distances;
- patterned and solid-color identities available through current primitives;
- stable semantic and instance identities;
- a moving occluder and rotating repeated parts; and
- existing player, NPC, vehicle, carryable, ground, district, and authored
  scene draws surrounding the fixture.

It does not relabel flat colors as glossy, metallic, emissive, alpha-tested, or
volumetric materials. Those scene requirements remain capability gaps until
the rendering/input contracts represent their causes. Exposure remains a
recorded frame constant but is not an NR-0002 input plane, so exposure
generalization also remains unproven.

Each fixture revision has one source fingerprint and stable presentation IDs.
Capture manifests continue to own the exact engine/content/shader/schema
fingerprints and camera path. Generated captures remain outside Git.

## Stress camera programs

NR0-D adds deterministic programs beyond the NR0-C split paths:

| Program | Pressure |
|---|---|
| `near-pass` | near-plane passage, thin features, rapid screen-space scale |
| `fast-orbit` | large motion vectors, fine edges, repeated identities |
| `disocclusion-sweep` | foreground occluder crossing and newly revealed pixels |
| `camera-cut` | explicit discontinuous poses and camera-cut history resets |
| `top-down` | held-out, out-of-distribution composition and depth ordering |
| `resize-cycle` | exact target recreation and resize history resets |

The camera function returns its reset reason. The application passes that
reason into the versioned neural input contract; it does not infer a cut from a
large matrix delta. Resize is performed only by the NR0 evaluation validation
mode, and the input host records the resulting reset from actual target extent
change.

## Capture cohorts

Every stress path owns a distinct `stress` sequence. Consecutive frames remain
consecutive so temporal analysis can reproject them. Event windows are chosen
explicitly by capture start, stride, and requested frame count and are recorded
in each capture root. The tool does not silently sample, truncate instances, or
cap numerical records.

The source dataset is immutable after completion. A new engine, fixture,
shader, content, schema, camera, or candidate revision receives a new external
evaluation root.

## Numerical evaluation

The NR0-D evaluator loads the exact NR-0002 checkpoint and accepted schema-2
captures. For nearest, bilinear, bicubic, and model output, it records complete
per-frame and aggregate:

- MAE, MSE, PSNR, and SSIM;
- image-gradient error as an explicit non-learned structure proxy;
- semantic-boundary and non-boundary error;
- every visible instance's pixel area, interior error, and boundary error; and
- inference timing and observable process/MPS memory.

Temporal analysis uses the declared previous-to-current NDC motion field to
reproject the preceding target and result into the current frame. Semantic and
instance agreement reject invalid history; newly revealed pixels are reported
as disocclusion. It records temporal residual error for valid pixels and a
separate current-frame error for disoccluded pixels. First-frame, camera-cut,
and resize pairs are intentionally excluded from history comparison and
retained as reset evidence.

These are descriptive measurements. NR0-D does not invent a passing numeric
threshold. The conclusion names the observed envelope and unacceptable
failures after the saved evidence is inspected.

## Human-readable evidence

All frame and instance metrics remain in JSON/NDJSON. Visual selection affects
only review convenience, never the underlying record. The report saves:

- full-frame target, nearest, bilinear, bicubic, model, amplified absolute
  error, semantic, and instance views;
- synchronized comparison sheets;
- crops around the highest measured overall, semantic-boundary, instance, and
  temporal errors;
- every camera-cut and resize transition; and
- a manifest that maps every image to capture, frame, candidate, tool, and
  metric provenance.

The report directory must be absolute and absent. Finalization writes a
separate accepted, rejected, or inconclusive review record without mutating the
candidate or source captures.

## Performance boundary

NR0-D can truthfully measure:

- offline PyTorch/MPS full-frame inference distributions;
- standalone Core ML package execution already exported by NR0-C;
- process RSS and observable PyTorch MPS allocation during evaluation;
- capture artifact volume and capture-enabled validation timing; and
- model/checkpoint/export sizes and exact digests.

It cannot truthfully claim installed end-to-end GPU time, GPU-resident input
assembly/inference/composition, fallback transition cost, final frame pacing,
or installed model/history residency because the 17-plane candidate is not yet
an NR0-F runtime bundle. Those measurements remain explicitly open rather than
being approximated from the preliminary RGB CPU-staged bridge.

## Executed evidence

NR0-D was executed on the Apple M2 Max development host against the exact
external NR-0002 checkpoint. Six immutable stress captures retained 478
frames: 64 `near-pass`, 64 `fast-orbit`, 64 `disocclusion-sweep`, 80
`camera-cut`, 64 `top-down`, and 142 `resize-cycle`. The resize cohort captured
real 1600x900, 1280x720, 1440x900, and restored 1600x900 source extents while
the capture contract kept its canonical 1600x900 target.

The evaluator preserved 478 frame records, 9,374 visible-instance records,
478 reset-aware temporal records, and 4,307 visual evidence files, including
measured worst temporal and disocclusion crops. Integrity
inspection passed before and after the immutable human conclusion was added.
Camera-cut frames 60 and 120 and resize frames 120, 180, and 240 were inspected
individually: each is complete and independently readable, with no blank frame
or geometry loss after reset.

The complete external evidence root is:

```text
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr0-d-20260807-a/
```

Start with `evaluation-v2/evaluation.json`, then
`evaluation-v2/conclusion.json`, `evaluation-v2/aggregate.json`, and the three
complete NDJSON metric streams. The earlier `evaluation/` is retained immutable
but superseded because its complete numerical and per-frame evidence omitted
the two promised convenience crops.
Generated captures and comparisons remain external and are not runtime model
content.

## Observed envelope

NR-0002 substantially improves broad spatial reconstruction over all declared
resize baselines. Across 688,320,000 evaluated pixels, full-frame model MAE was
0.03811 and mean-frame SSIM was 0.87138, versus bilinear MAE 0.16700 and SSIM
0.83490. On newly revealed pixels, model MAE was 0.12051 versus bilinear
0.16729. The spatial input ABI therefore remains useful and the model extracts
real information from its structural channels.

That aggregate advantage does not make NR-0002 promotion-worthy:

- valid-history temporal residual MAE was 0.04090 for the model versus 0.03318
  for bilinear, exposing visible frame-to-frame instability in a stateless
  spatial candidate;
- semantic-boundary gradient MAE was 0.05644 versus bilinear 0.04918, and
  instance-boundary gradient MAE was 0.06191 versus 0.05522;
- near and thin features blur or disappear, checker detail is smoothed, and
  high-contrast boundaries acquire dark halos and color bleed; and
- the top-down and reset cohorts remain structurally valid but expose local
  failures that their background-dominated aggregate scores conceal.

Unsupported roughness, metallic, emissive, alpha-test, transparency, and
volumetric causes were not fabricated for this evaluation. Exposure remains
metadata rather than an NR-0002 input. Installed GPU-resident inference,
composition, fallback, frame pacing, and residency remain NR0-F work.

The superseding offline PyTorch/MPS evaluation measured 3.430 ms p50, 5.784 ms
p95, 7.473 ms p99, and 117.633 ms maximum. The exhaustive evaluator took about
23.6 minutes, used 8,550,137,856 bytes peak process RSS, and reported
399,396,352 current and 3,557,277,696 driver-allocated MPS bytes after
evaluation. Those are offline
evaluation-process measurements, including evidence generation and framework
overhead; they are not installed model residency or product frame cost.

## Disposition

NR0-D is accepted because the fixture, reset contract, exhaustive evaluator,
integrity inspector, retained visual evidence, and explicit conclusion satisfy
the phase exit criteria. NR-0002 itself is not accepted for NR0-E promotion and
remains external and unpromoted.

Closeout verification passed the NR0-C 3-test and NR0-D 4-test Python suites,
the two neural shader tests, and the full editor and non-editor repository
suites. A fresh installed Metal fixture smoke rendered 1,200 frames, 300
simulation ticks, 23 fixture plans and 25 neural-input draws, exposed live
aligned input buffers in the Neural Input / Output window, and shut down cleanly.

The next actual model work is one bounded spatial failure-correction experiment
using this fixture as held-out evaluation: broaden training coverage for thin
features, small instances, camera discontinuities, and resize states, and tune
losses against boundary and temporal readability. A temporal architecture is
not assumed yet; the next candidate must first prove whether a better spatial
training distribution and objective can remove the observed failures. NR0-E
starts only when an evaluated candidate is deliberately selected for runtime
work.

## Implementation phases

### D1 — Fixture and reset contract — complete

- Add one presentation-only evaluation fixture with stable IDs and a source
  fingerprint.
- Add the six stress camera programs and explicit camera-cut/resize events.
- Add one installed graphical validation mode that captures the real fixture
  without requiring unrelated S13 acceptance.
- Test parsing, deterministic transforms, stable IDs, reset delivery, and cold
  authority boundaries.

### D2 — Failure evaluator — complete

- Add the checkpoint/capture evaluator and focused unit contracts.
- Preserve per-frame, per-instance, boundary, temporal, timing, memory, and
  artifact records.
- Generate full-frame comparisons and measured failure crops.
- Add a read-only integrity inspector and separate review finalizer.

### D3 — Executed stress evidence — complete

- Install the validation product and capture every declared stress path into a
  new external root.
- Inspect every capture before evaluation.
- Evaluate the immutable NR-0002 candidate and inspect the visual report.
- Record observed strengths, failures, capability gaps, and exact commands.

### D4 — Acceptance and closeout — complete

- Update the NR0 plan, evaluation-scene document, validation ledger,
  performance baseline, tool/fixture instructions, experiment registry, and
  neural-rendering skill.
- Run Python contracts, shader tests, editor/non-editor repository tests, and
  installed graphical fixture validation.
- Accept NR0-D only if its retained evidence is complete and its conclusion is
  explicit. Do not promote a model as part of this phase.

## Exit criteria

NR0-D is complete when:

- all stress captures are complete and independently inspectable;
- the report can be regenerated from explicit immutable inputs;
- no sequence leaks into model training or selection;
- full numerical evidence and selected visual evidence agree about the useful
  envelope and failures;
- every unmeasured renderer/runtime capability is named;
- training dependencies remain absent from product, headless, and server
  graphs; and
- the candidate remains external and unpromoted.
