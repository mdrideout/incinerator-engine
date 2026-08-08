---
name: incinerator-neural-rendering
description: Plan, implement, evaluate, and promote Incinerator Engine game-specific neural rendering while preserving deterministic authority, explicit presentation schemas, experiment provenance, macOS runtime boundaries, conventional fallback, and immutable model selection. Use when work touches neural-rendering research, G-buffer or auxiliary input design, paired capture, datasets, training runs, model evaluation/export, model bundles, promotion, runtime inference, temporal history, neural-rendering diagnostics, or NR0 documentation and acceptance.
---

# Incinerator Neural Rendering

Keep the neural model inside presentation. The deterministic game remains the
only authority; experiments remain outside the runtime; promotion is the only
path from an evaluated export to selected game content.

## Read before acting

1. Read `docs/adr/025-game-specific-neural-rendering-boundary.md` completely.
2. Read `docs/design/nr0-neural-rendering-feasibility.md` and, for capture or
   quality work, `docs/design/nr0-neural-rendering-evaluation-scene.md`.
3. For model/input decisions, read the relevant files under
   `docs/research/neural-rendering/`; do not treat research numbers as engine
   measurements.
4. For experiment work, read `experiments/neural-rendering/README.md`.
5. For tooling or promotion work, read `tools/neural-rendering/README.md` and
   `models/neural-rendering/README.md`.
6. For an acceptance or performance claim, read the NR0 validation ledger and
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
- Target Apple Silicon macOS first. Do not introduce a cross-platform inference
  abstraction until a selected secondary platform creates a concrete consumer.
- Do not invent model, memory, dataset, frame-rate, or history caps. Measure a
  real failure or product envelope first and record the cohort.
- Advance schemas without compatibility decoders; coordinate every producer,
  consumer, capture, bundle, diagnostic, test, and document in the change.

## Current NR0-A through NR0-D contract

The accepted input ABI is `incinerator.neural-input.v1`: six 400×225 RGBA8
appearance, linear-depth, world-normal, motion, semantic, and instance targets.
The paired conventional target is canonical 1600×900. Capture schema 2 requires
an absolute absent root plus explicit cohort, sequence, and camera-path
ownership. Its raw bytes are canonical RGBA8 (including normalization from a
BGRA Metal product source); PPM images are debug derivatives only.

Use the Neural Rendering Lab for live schema, shader, history, identity,
render, model, and capture state. Use these tools for external evidence:

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

NR-0001 RGB training tools predate capture schema 2. Do not silently adapt or
discard its extra channels. NR0-C uses `nr0_dataset.py` and NR-0002: appearance
RGB, depth R, normal RGB, motion/history RGB, semantic RGB, instance RGB, and
coverage A form an exact 17-plane ABI. Training targets remain canonical
1600×900 RGB. Whole capture sequences own overfit/train/validation/test splits;
the test sequence is evaluated only after validation selection.

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
content. The next model experiment should first test whether broader spatial
training coverage and loss correction resolve the measured envelope; do not
assume temporal state is required before that experiment proves it.

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
