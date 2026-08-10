# NR-0003 LTX-Video 2B Distilled Baseline

**Result:** Platform feasibility accepted; stock RGB conditioning rejected for
Incinerator presentation; unpromoted

**Executed:** 2026-08-08

**Hardware:** MacBook Pro, Apple M2 Max, 64 GiB unified memory

## Question

Can the official LTX-Video 2B distilled model turn Incinerator's deliberately
simple raster frames into materially richer video on the target Mac at the
quality-first proof rate of roughly 1–2 FPS, while preserving authored camera,
geometry, identity, and timing?

This is a capability baseline, not the title model. It deliberately tests the
stock RGB video-to-video interface before Incinerator invests in paired LTX
training or runtime integration.

## Fixed inputs

- Official inference source:
  `Lightricks/LTX-Video@4b2d053057623ddd4d0a1d3e9cd28890e9ef487f`.
- Official trainer reviewed for the next experiment:
  `Lightricks/LTX-Video-Trainer@e055182fa36dba6f48eb0919aef09d277da30fbd`.
- Checkpoint: `ltxv-2b-0.9.8-distilled.safetensors`, SHA-256
  `76aa8c4786af752fa6f951947129d5290c3c6c0b2fadcadea6b5e114ae2cad8f`.
- Model terms: LTXV Open Weights License 0.X, SHA-256
  `30eabbcc090dd3bd70cffaa14338142df82f348f7bd91b2f63f0c6099ccf50e0`.
  Every candidate retains a promotion-and-distribution review gate.
- Input: the first nine appearance frames from the accepted
  `nr0-d-fast-orbit-0001` capture, resized with nearest sampling from 400×225
  to 512×288 and encoded at 8 FPS. The sequence manifest preserves exact frame,
  source, content, channel, and materialized-image hashes.
- Prompt enhancement is disabled. The committed title-style prompt and seed
  `1783` are fixed for both comparisons.

The generated model cache, upstream checkouts, environment, sequence, videos,
and evidence remain outside Git under:

```text
~/Library/Application Support/Incinerator/neural-rendering/
```

## Executed candidates

| Candidate | Schedule | Warm pipeline | Effective rate | Peak process RSS | Human result |
|---|---:|---:|---:|---:|---|
| Structure | `0.7250, 0.4219` | 5.966 s / 9 frames | 1.509 FPS | 7,918,895,104 bytes | Major authored primitives remain, but output is mainly softened/smoothed and does not supply the requested fidelity increase |
| Richness | `0.9094, 0.7250, 0.4219` | 6.079 s / 9 frames | 1.480 FPS | 7,918,878,720 bytes | Rich materials, lighting, buildings, and vehicles appear, but they replace rather than render the authored scene |

Cold end-to-end execution was 30.872 seconds and 30.964 seconds respectively,
including checkpoint, text encoder, and VAE loading. Warm timing synchronizes
MPS around the top-level LTX pipeline. It excludes process startup and loading,
but includes the candidate's encode, denoise, and decode path.

Canonical evidence:

```text
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr-0003-ltxv-2b-20260808-a/
  sequence/
  candidate-structure-license-final/
  candidate-rich-license-final/
```

Open `comparison-sheet.png` in either candidate. Within every time block the
source row is above the generated row. `candidate.json` records all immutable
inputs, environment packages, upstream/model/license digests, timing, memory,
and generated artifact hashes.

## Failure evidence retained

The official 0.9.8 multiscale pipeline rejected this video-to-video input
because its supplied full-resolution latent shape did not match the first
downscaled pass. That attempt is retained as `candidate/` with terminal
`failed` state. Exploratory single-scale schedules are retained as
`candidate-v2` through `candidate-v4` and are superseded by the schema-2 final
candidates. They are not canonical evidence because their repository config
paths predated immutable config snapshots.

## Conclusion

LTX-Video 2B distilled clears the local compute gate on this Mac and has a
strong learned visual prior. Stock appearance-RGB conditioning does not clear
the authored-structure gate. The tested schedules reveal no useful overlap:
weak transformation preserves structure without the desired rendering leap;
strong transformation creates the desired richness by hallucinating a
different world.

That is evidence that substantial learned visual richness is possible and that
appearance-only conditioning is insufficient. It is not an ancestor for the
product model. [ADR-026](../../../docs/adr/026-from-scratch-title-neural-renderer.md)
supersedes the provisional IC-LoRA direction: promotion-eligible learned
components are implemented by Incinerator and trained from random
initialization on title-owned pairs.

The architectural lesson still defines the required corpus:

```text
reference: simple deterministic Incinerator raster/control video
target:    high-fidelity render of the exact same tick, camera, geometry,
           animation, lighting intent, and identity
```

The next phase is
[NR-0004](../../../docs/design/title-neural-renderer-north-star.md): build the
high-fidelity target and paired-corpus foundation. It is followed by a
repository-defined structural renderer trained from scratch, then causal
temporal and learned-detail experiments. Training must not begin until a
genuinely high-fidelity aligned target exists; using the current flat
conventional render or a hallucinated stock output as truth would teach the
wrong mapping.

No NR-0003 artifact may enter `models/neural-rendering/`, and NR0-E remains
blocked on a candidate that preserves authored structure and passes the
unchanged NR0-D failure envelope.

## Reproduce

Create a dedicated external Python 3.13 environment and install the official
checkout at the exact revision:

```sh
export INCINERATOR_NR_ROOT="$HOME/Library/Application Support/Incinerator/neural-rendering"
export HF_HOME="$INCINERATOR_NR_ROOT/model-cache/huggingface"
PYTHON=/opt/homebrew/opt/python@3.13/bin/python3.13

git clone https://github.com/Lightricks/LTX-Video.git \
  "$INCINERATOR_NR_ROOT/upstream/LTX-Video"
git -C "$INCINERATOR_NR_ROOT/upstream/LTX-Video" checkout \
  4b2d053057623ddd4d0a1d3e9cd28890e9ef487f
"$PYTHON" -m venv "$INCINERATOR_NR_ROOT/envs/nr-0003-ltxv-2b"
LTX_PYTHON="$INCINERATOR_NR_ROOT/envs/nr-0003-ltxv-2b/bin/python"
"$LTX_PYTHON" -m pip install --upgrade pip
"$LTX_PYTHON" -m pip install -e \
  "$INCINERATOR_NR_ROOT/upstream/LTX-Video[inference]" psutil
```

Prepare a new immutable sequence from a complete capture:

```sh
export PYTHONPATH="$PWD/tools/neural-rendering"
"$LTX_PYTHON" tools/neural-rendering/prepare_ltxv_sequence.py \
  --capture <absolute-complete-schema-2-capture> \
  --output <new-absolute-sequence-root> \
  --start-index 0 --frames 9 --extent 512x288 --fps 8
```

Run either committed schedule using a new output directory:

```sh
export PYTHONPATH="$INCINERATOR_NR_ROOT/upstream/LTX-Video:$PWD/tools/neural-rendering"
"$LTX_PYTHON" tools/neural-rendering/run_ltxv_candidate.py \
  --repo "$PWD" \
  --upstream "$INCINERATOR_NR_ROOT/upstream/LTX-Video" \
  --sequence <absolute-sequence-root>/sequence.json \
  --config "$PWD/experiments/neural-rendering/nr-0003-ltxv-2b-distilled/ltxv-2b-v2v-mps.yaml" \
  --prompt "$PWD/experiments/neural-rendering/nr-0003-ltxv-2b-distilled/style-prompt.txt" \
  --output <new-absolute-candidate-root>

"$LTX_PYTHON" tools/neural-rendering/inspect_ltxv_candidate.py \
  <absolute-candidate-root>
```
