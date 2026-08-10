# Neural Rendering Research

**Status:** Active research supporting accepted ADR-025 and ADR-026; NR0-A
through NR0-D, NR-0004, and NR5-A/B accepted; NR5-C and NR0-E through NR0-G
open

**Last reviewed:** 2026-08-08

This directory preserves the evidence and reasoning behind Incinerator's
game-specific neural-rendering track. It is research input, not a runtime
contract and not evidence that a model has passed acceptance.

Start with:

1. [`2026-07-landscape.md`](2026-07-landscape.md) for the July 2026 evidence;
2. [`incinerator-feasibility.md`](incinerator-feasibility.md) for the proposed
   Incinerator baseline and major unknowns;
3. [ADR-025](../../adr/025-game-specific-neural-rendering-boundary.md) for the
   accepted ownership and promotion boundary; and
4. [ADR-026](../../adr/026-from-scratch-title-neural-renderer.md) and the
   [north star](../../design/title-neural-renderer-north-star.md) for the
   accepted title-owned, random-initialization training direction; and
5. [the NR0 plan](../../design/nr0-neural-rendering-feasibility.md) for the
   first implementation sequence.

Executed quality-first evidence now includes
[`NR-0003`](../../../experiments/neural-rendering/nr-0003-ltxv-2b-distilled/README.md).
It proves official LTX-Video 2B distilled can run around 1.5 FPS at 512×288 on
the target M2 Max, but rejects stock RGB video-to-video as the title renderer:
conservative conditioning preserves structure without enough added fidelity,
while stronger generation invents a different scene. The current research
direction is therefore exactly aligned high-fidelity targets plus a
repository-defined causal neural renderer trained from random initialization,
not more prompt/denoise tuning or external-model adaptation.

The exact target implementation is retained as
[`NR-0004`](../../../experiments/neural-rendering/nr-0004-high-fidelity-target-corpus/README.md).
Its native still direction, 18-frame moving target, and minimal global-control
schema are accepted, and the two-run technical/reproducibility proofs pass.
NR4-D's 108-pair technical corpus gate passes from the explicit native
`160×90 → 400×225` contract, and NR4-E accepts it for the initial structural
scope with explicit broader gaps. NR5-A/B then prove repository-owned random
initialization, immutable lineage, direct linear-HDR learning, and controlled
reconstruction across all 18 overfit frames. NR5-C held-out reconstruction is
next. Artifacts at other extents remain historical only.

Research may compare broad techniques. Implementation choices enter the
engine only through an ADR or an amendment to ADR-025, an executable vertical
slice, and recorded validation.
