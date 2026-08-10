---
name: incinerator-neural-rendering
description: Plan, implement, evaluate, and promote Incinerator Engine game-specific neural rendering trained from random initialization on title-owned paired data while preserving deterministic authority, explicit presentation schemas, experiment provenance, macOS runtime boundaries, conventional fallback, and immutable model selection. Use when work touches neural-rendering research, G-buffer or auxiliary input design, target rendering, paired capture, datasets, training runs, model evaluation/export, model bundles, promotion, runtime inference, temporal history, neural-rendering diagnostics, or NR0 documentation and acceptance.
---

# Incinerator Neural Rendering

Keep the neural model inside presentation. The deterministic game remains the
only authority; experiments remain outside the runtime; promotion is the only
path from an evaluated export to selected game content.

## Read before acting

1. Read `docs/adr/025-game-specific-neural-rendering-boundary.md` completely.
2. Read `docs/adr/026-from-scratch-title-neural-renderer.md` and
   `docs/design/title-neural-renderer-north-star.md` completely.
3. For NR-0004 or later title-renderer implementation, read
   `docs/design/title-neural-renderer-implementation-plan.md` completely.
4. Read `docs/design/nr0-neural-rendering-feasibility.md` and, for capture or
   quality work, `docs/design/nr0-neural-rendering-evaluation-scene.md`.
5. For model/input decisions, read the relevant files under
   `docs/research/neural-rendering/`; do not treat research numbers as engine
   measurements.
6. For experiment work, read `experiments/neural-rendering/README.md`.
7. For tooling or promotion work, read `tools/neural-rendering/README.md` and
   `models/neural-rendering/README.md`.
8. For an acceptance or performance claim, read the NR0 validation ledger and
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

## Current native input and target contract

The active input ABI is `incinerator.neural-input.v3`: six native `160×90`
RGBA8 appearance, linear-depth, world-normal, motion, semantic, and instance
targets plus four frame-global float32 lighting/material controls. Capture
schema 4 requires an absolute absent root plus explicit cohort, sequence, and
camera-path ownership. It stores only native inputs; it does not emit a
conventional product target. PPM images and contact sheets are debug/UI
derivatives only.

The active offline target package is
`incinerator.nr4.blender-target-frame.v4`. It declares a direct native
`400×225` Cycles target and the exact top-left pixel-center 5:2 mapping:
`((target_index + 0.5) * 2 / 5) - 0.5`, with clamp border behavior. Every
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

NR4-C is accepted. Its native technical still and 18-frame sequence gates pass
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
README and validation ledger. Other output extents are deferred.

Preserve or deliberately advance the 17-plane engine ABI as one cohort; RGB is
only the stock baseline adapter. Begin controls at `160×90` and use `400×225`
for a structural channel only after a measured ablation justifies the cost. Do
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
live evaluation path, not promotion or installed content. NR6 is the active
phase. Do not claim title-wide, temporal, promotion, installed-runtime, or
art-complete readiness from NR-0005.

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
