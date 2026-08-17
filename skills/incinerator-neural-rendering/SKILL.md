---
name: incinerator-neural-rendering
description: Honor the Incinerator neural-rendering product-track pause and, only after an explicit product-owner resume request, plan, implement, evaluate, or promote game-specific neural rendering trained from random initialization on title-owned paired data while preserving deterministic authority, provenance, runtime boundaries, fallback, and immutable selection. Use when work touches neural-rendering research, capture, datasets, training, evaluation/export, bundles, runtime inference, temporal history, diagnostics, or acceptance.
---

# Incinerator Neural Rendering

Keep the neural model inside presentation. The deterministic game remains the
only authority; experiments remain outside the runtime; promotion is the only
path from an evaluated export to selected game content.

## Product-track pause — hard stop

Neural rendering is paused indefinitely as of 2026-08-17. Read
`docs/design/neural-rendering-pause.md` before any other neural-rendering
resource.

Unless the user explicitly asks to resume neural-rendering work, do not mutate
this track: do not create a phase, capture data, train or optimize a model,
change a neural schema or runtime, begin NR6/NR7, or promote content. A
deterministic-rendering task does not implicitly reopen neural work. Preserve
RF10 as the accepted external, unpromoted stopping point.

Read-only questions and historical inspection are allowed. A direct user
request to implement new neural-rendering work is a scoped resume request; begin
by applying the restart gate in the pause document rather than automatically
continuing the old roadmap.

## Read before acting

1. Read `docs/design/neural-rendering-pause.md` completely and confirm the user
   has explicitly reopened the track before making changes.
2. Read `docs/adr/025-game-specific-neural-rendering-boundary.md` completely.
3. Read `docs/adr/026-from-scratch-title-neural-renderer.md` and
   `docs/design/title-neural-renderer-north-star.md` completely.
4. For NR-0004 or later title-renderer implementation, read
   `docs/design/title-neural-renderer-implementation-plan.md` completely.
5. For RF0-RF10 visual-content, paired-profile, or rich-spatial work, read
   `docs/design/rich-fidelity-roadmap.md` completely.
6. Read `docs/design/nr0-neural-rendering-feasibility.md` and, for capture or
   quality work, `docs/design/nr0-neural-rendering-evaluation-scene.md`.
7. For model/input decisions, read the relevant files under
   `docs/research/neural-rendering/`; do not treat research numbers as engine
   measurements.
8. For experiment work, read `experiments/neural-rendering/README.md`.
9. For tooling or promotion work, read `tools/neural-rendering/README.md` and
   `models/neural-rendering/README.md`.
10. For an acceptance or performance claim, read the NR0 validation ledger and
   performance baseline first.

Check repository status and current code before acting. Planned filenames in
NR0 are responsibilities, not proof that a file or implementation already
exists.

## Route the task

- **Research:** update the research snapshot and distinguish evidence,
  inference, and Incinerator recommendation. Amend ADR-025 only for a decision.
- **Input/capture:** change one versioned presentation schema, debug every
  channel, preserve exact paired-frame identity, and keep capture dependencies
  out of the product graph.
- **Experiment:** create one numbered definition and one external, immutable run
  folder. Record configuration, environment, seeds, revisions, data splits,
  baselines, metrics, samples, and conclusion.
- **Runtime:** keep sequencing/history in a neural host, backend resources in
  the macOS adapter, bundle validation in content, and final targets/present in
  the renderer. Do not grow `src/renderer.zig` into the orchestrator.
- **Promotion:** accept one evaluated export, verify provenance/schema/rights
  and digests, copy transactionally to one immutable bundle, then atomically
  update exact selection. Never load or mutate the source run.
- **Validation:** prove logical authority equivalence, schema failure, fallback,
  installed inference, model identity, quality, timing, memory, incidents, and
  human perceptual behavior separately.

## Guardrails

- Never feed player input, private components, Flecs entities, Jolt handles,
  session/transport objects, or durable authority state to the model.
- Treat model history as disposable visual cache. Reset it explicitly on the
  events declared by the selected schema; never persist or replicate it.
- Keep UI, text, editor chrome, accessibility graphics, and diagnostics after
  neural scene inference unless a measured experiment changes the ADR.
- Preserve a usable low-fidelity conventional fallback and make active model,
  schema, history, and fallback reason visible.
- Never discover `latest`, auto-select the highest metric, or read an experiment
  checkpoint at runtime.
- Never commit generated datasets, exhaustive frames, checkpoints, or temporary
  exports. Commit small experiment intent, provenance, conclusions, and review
  evidence.
- Keep training frameworks out of normal graphical, validation, headless, and
  server dependency graphs.
- Promotion-eligible weights and every learned training dependency begin from
  declared random initialization and use title-owned data. External pretrained
  models are comparison evidence only: do not fine-tune, distill, use as a
  learned loss, create pseudo-targets, or promote them.
- Target Apple Silicon macOS first. Do not introduce a cross-platform inference
  abstraction until a selected secondary platform creates a concrete consumer.
- Do not invent model, memory, dataset, frame-rate, or history caps. Measure a
  real failure or product envelope first and record the cohort.
- Advance schemas without compatibility decoders; coordinate every producer,
  consumer, capture, bundle, diagnostic, test, and document in the change.

## Retained native input and target contract

The retained RF10 input ABI is `incinerator.neural-input.v7`: six native `256×144`
RGBA8 appearance, linear-depth, world-normal, motion, semantic, and instance
targets plus five frame-global float32 presentation controls: sun, world,
local-light, emissive, and authored material-palette intent. Capture root
schema 8 requires an absolute absent root plus explicit cohort, sequence, and
camera-path ownership. It stores only native inputs; it does not emit a
conventional product target. PPM images and contact sheets are debug/UI
derivatives only.

The retained offline target package is
`incinerator.nr4.blender-target-frame.v8`. It declares a direct native
`1280×720` Cycles target and the exact uniform top-left pixel-center 5:1 mapping
on both axes: `((target_index + 0.5) / 5) - 0.5`, with clamp border behavior. Every
current producer, consumer, inspector, report, and baseline must reject foreign
extents. Never reduce or reuse an earlier high-resolution target as current
training, comparison, preview, metric, or acceptance material.

Use the Neural Input / Output window for the native live appearance/output
comparison and its collapsible schema, shader, history, identity, render,
model, capture, and auxiliary-input diagnostics. Use these tools for external
evidence:

```sh
zig build inspect-nr0-capture -- <capture-root> [<capture-root> ...]
zig build inspect-nr0-capture -- --require-identical <capture-a> <capture-b>
zig build nr0-visual-report -- <capture-root> <new-output.ppm>
zig build verify-nr0-ab
```

Open `capture.json`, then `frames.ndjson`, then the referenced per-frame
manifest. Check full source/content/schema/shader provenance and matrix/frame
identity before interpreting images. A complete capture must have every raw and
debug digest, stable identity mapping, zero compact-ID collision, and an exact
recorded/requested frame count. The inspector also requires aligned coverage,
grayscale depth, unit decoded normals, binary history, and manifest-backed
semantic/instance pixels. Do not infer buffer meaning from color alone; use the
schema encoding and debug-encoding strings.

NR-0001/2 training tools predate capture schema 3. Do not silently adapt or
discard its extra channels. Historical NR0-C uses `nr0_dataset.py` and NR-0002: appearance
RGB, depth R, normal RGB, motion/history RGB, semantic RGB, instance RGB, and
coverage A form an exact 17-plane ABI. Its target assumptions are historical
and incompatible with the active native cohort. Whole capture sequences own
overfit/train/validation/test splits; the test sequence is evaluated only
after validation selection.

`tools/run_nr0_c.sh` reproduces capture through export in a new external root.
The compact spatial model, deterministic nearest/bilinear/bicubic comparisons,
full-frame metrics/samples, checkpoint, Core ML export, benchmarks, exact
environment, and final conclusion stay in that root. `finalize_nr0_c.py` writes
a pending review separately from final accepted/rejected `experiment.json`.
NR-0002 is an unpromoted spatial candidate, not art-direction, temporal,
runtime, or shipping evidence.

NR0-D adds a presentation-only 23-identity fixture and six stress camera paths:
`near-pass`, `fast-orbit`, `disocclusion-sweep`, `camera-cut`, `top-down`, and
`resize-cycle`. Use `--nr0-evaluation-smoke` only as an installed validation
composition. It deliberately avoids gameplay/authority ownership while using
the real conventional and neural-input presentation seam. Camera cuts and real
target resizes deliver explicit history-reset reasons.

Run a fresh external evaluation with `tools/run_nr0_d.sh`. Read and verify an
existing evaluation with:

```sh
python tools/neural-rendering/inspect_nr0_d.py <absolute-evaluation-root>
```

`evaluate_nr0_d.py` retains every frame and visible instance plus boundary,
reset-aware temporal, disocclusion, timing, memory, and visual evidence.
`finalize_nr0_d.py` appends one immutable accepted/rejected/inconclusive phase
review; it never promotes the candidate.

The accepted 2026-08-08 NR0-D evaluation finds NR-0002 broadly better than
deterministic resize but worse than bilinear in valid-history temporal residual
and boundary sharpness, with visible thin-feature loss and edge bleed. NR-0002
is not suitable for promotion. Do not start NR0-E by copying it into runtime
content.

NR-0003 then tested official LTX-Video 2B 0.9.8 distilled on the target M2 Max.
At 512×288 it achieved roughly 1.5 warm FPS with roughly 7.9 GB peak process
RSS, so the quality-first local proof-rate gate passed. Stock appearance-RGB
conditioning failed the renderer gate: conservative denoising preserved the
scene but added little fidelity; stronger denoising generated rich imagery by
replacing authored geometry and identities. Read
`experiments/neural-rendering/nr-0003-ltxv-2b-distilled/README.md` before LTX,
video-model, or next-candidate work.

NR4-A of the NR-0004 data-factory experiment is implemented and human-accepted.
Its validation-only urban-corner fixture exports 26 exact presentation draws
through the historical `incinerator.nr4.blender-target-frame.v1`; pinned
Blender 4.5.12 LTS/Cycles Metal produces the 1600×900 target, identity, depth,
normal, provenance, and synchronized review sheet. The canonical two-run proof
is under
`~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-a-technical-20260808-v2`.
The immutable acceptance manifest predates the subsequent product-owner review;
the experiment README and validation ledger record its accepted disposition.

NR4-B is implemented and technically proven through the adapter-local
`incinerator.nr4.blender-target-frame.v2`. Eighteen exact frames cover six
single-cause camera, object, near-edge, wheel, occlusion, and lighting/effect
segments. The canonical two-run proof is under
`~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-b-technical-20260808-a`.
Start with `acceptance.json`, `reproducibility.json`, and
`run-a/evaluation/reports/nr4-b-sequence-review.png`, then inspect the six
segment sheets. The technical gate passes, and on 2026-08-08 the product owner
accepted the synchronized moving target direction. The immutable external
review field retains its original pending state; the committed experiment
disposition records the subsequent acceptance.

NR4-C is accepted historical evidence. Its native technical still and
18-frame sequence gates passed
at `160×90 → 400×225`, and the product owner accepted the target/alignment
direction. Input schema v3, capture schema 4, and target-frame schema v4 add
four presentation-owned frame-global float32 lighting/material controls. Their
16-byte payload resolves the only observed ambiguity without a new raster
target. Consider a native spatial control only after a controlled-fit failure.
Treat the 2.5× mapping
as an explicit schema contract; test border, thin-feature, identity-edge, and
motion alignment. NR4-A/B artifacts remain immutable
historical adapter/correspondence evidence only. Exclude their target pixels,
metrics, and acceptance from current generation, training, comparison,
preview, and acceptance. Current evidence roots are recorded in the NR-0004
README and validation ledger. RF7 later superseded that resolution with direct
native `160×90 → 800×450`; RF8 and RF9 then used direct native
`160×90 → 640×360`. RF10 owns the retained direct native
`256×144 → 1280×720` contract. All older extents remain immutable history only
and must not enter RF10 training, comparison, export, or runtime output.

Preserve or deliberately advance the 17-plane engine ABI as one cohort; RGB is
only the stock baseline adapter. Begin controls at the native input extent;
RF10 adds no structural raster at another extent. Do
not train on the current flat conventional target or a stock hallucinated
output and call it truth. LTX weights remain a licensed comparison baseline
only. NR4-D's technical gate passes with six whole sequences and 108 pairs at
`~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-d-corpus-20260808-b`.
NR4-E accepts that corpus only for the initial structural scope at
`~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-e-coverage-20260809-b`.
NR5-A and NR5-B then accept the cohesive random-origin framework and controlled
overfit at
`~/Library/Application Support/Incinerator/neural-rendering/experiments/nr5-b-controlled-overfit-20260809-c`.
NR5-C/D are accepted at
`~/Library/Application Support/Incinerator/neural-rendering/experiments/nr5-c-held-out-20260810-b`:
validation selected the checkpoint, test opened once, a real second attempt was
rejected, and a fresh 36-frame native stress corpus passed. Inspect with
`zig build inspect-title-renderer-candidate -- <absolute-run-root>`. NR5-E then
accepts the explicit external trial bundle at
`~/Library/Application Support/Incinerator/neural-rendering/trial-bundles/nr5-e-spatial-20260810-b`.
Inspect it with `zig build inspect-nr5-e-trial-bundle -- <absolute-bundle-root>`
and run its graphical gate with
`zig build verify-nr5-e-trial -Deditor=true -- <absolute-bundle-root>`. It is a
live evaluation path, not promotion or installed content. RF0 through RF5 are
accepted, and RF6-A through RF6-F are technically complete at
`~/Library/Application Support/Incinerator/neural-rendering/experiments/rf6-held-out-20260811T032650Z`
with the external trial at
`~/Library/Application Support/Incinerator/neural-rendering/trial-bundles/rf6-rich-spatial-20260811T034154Z`.
Read `docs/validation/rf6-cumulative-rich-spatial.md` before interpreting that
historical result. RF7 through RF9 remain historical. RF10 is the currently
implemented spatial contract and retained external experiment cohort. NR6 is
not authorized while the product track is paused.
Do not claim title-wide, temporal, promotion, installed-runtime, or
art-complete readiness from NR-0005 or RF6.

RF8 is the frozen comparison spatial cohort. Read
`experiments/neural-rendering/rf8-direct-640x360-spatial-sharpness/README.md` before
capture, corpus, training, export, or runtime work. It uses fresh native
`160×90` historical schema-v5 inputs and direct native `640×360`
target-frame-v6 truth,
one learned uniform 4× model, and the existing explicit external Core ML trial
seam. Never insert, derive, supervise, compare, export, or present a `400×225`
or `800×450` image in RF8. Do not reuse its pixels or weights in RF9.

RF8's external corpus and run lineage use the
`rf8-direct-640x360-*-20260812-*` roots beneath
`~/Library/Application Support/Incinerator/neural-rendering/`. Inspect the full
disposition, metrics, limitations, and live command in
`docs/validation/rf8-direct-640x360-spatial-sharpness.md`. It remains
unpromoted and does not authorize installed content,
temporal claims, or title-wide readiness.

RF9 is a completed external technical spatial trial. Read
`docs/design/rf9-spatial-quality-expansion.md` and
`docs/validation/rf9-spatial-quality-expansion.md` and
`experiments/neural-rendering/rf9-spatial-quality-expansion/README.md` before
acting. It preserves direct native `160×90 → 640×360`, adds only the
controlled-ablation-proven material-palette scalar, compares learned 2×/2×
feature reconstruction against RF8-style bilinear refinement, and evaluates
capacity, detail ownership, and a conditional high-frequency residual without
using RF8 pixels or weights. The completed evidence retains bilinear refinement
and rejects learned pyramid reconstruction, added capacity, detail-focused
sampling, and the detail residual. Generated RF9 data, checkpoints, and bundles
stay external and unpromoted; product review was superseded by the RF10
resolution decision. Further neural work is paused.

RF10 is the retained stopping-point cohort. Read
`docs/design/rf10-native-720p-spatial-cohort.md` and
`docs/validation/rf10-native-720p-spatial.md` and
`experiments/neural-rendering/rf10-native-720p-spatial/README.md` before any
resolution, capture, target, corpus, training, export, or runtime change. It
replaces the complete learned problem with direct native `256×144 → 1280×720`
and an exact uniform 5:1 mapping. Reuse RF9 code and factual findings where
appropriate, but never RF9 pixels, weights, optimizer state, metrics, split
approval, or review sheets. RF9 is historical and must not be used as the
active engine ABI or executable comparison trial.

RF10-A through RF10-G are complete and RF10-H is accepted by the product owner
as the retained external, unpromoted stopping point. The
accepted external campaign is
`~/Library/Application Support/Incinerator/neural-rendering/experiments/rf10-native-720p-campaign-20260814T015457Z`.
Its 1,062,587-parameter Core ML bundle is trial-only and unpromoted. Use
`zig build inspect-rf10-trial-bundle -- <bundle>` and
`zig build verify-rf10-trial -- <bundle>` before interpreting it. The remaining
hands-on review must check the native centered `1280×720` main scene, black
surround, `N` fallback toggle, and native `256×144` debug source. Do not infer
promotion, temporal readiness, or title-wide quality from technical
acceptance.

## Validation and handoff

For each completed NR0 phase:

1. update its plan checklist/status and the validation ledger;
2. preserve commands, hardware, model/data/content/shader/schema digests, and
   generated artifact paths;
3. compare against the cheap renderer and a non-neural upscale baseline;
4. report numerical quality, semantic/temporal failures, latency, memory,
   fallback behavior, and remaining human tests without merging the claims;
5. run affected engine and cold/headless boundary tests; and
6. update the performance baseline only from repeatable executed evidence.

Do not call a model “best.” Call it a candidate until explicit promotion and an
accepted runtime bundle make it selected.
