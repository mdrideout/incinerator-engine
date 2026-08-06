# NR0-A/B Input and Capture Conformance

**Result:** Accepted foundation, not a model candidate

**Date:** 2026-08-05

## Question

Can the real Incinerator presentation produce a small, explicit, inspectable
multi-channel neural input and pair it with the same submitted conventional
frame without leaking authority state, corrupting identity, or silently mixing
dataset cohorts?

## Contract under test

- input schema: `incinerator.neural-input.v1`;
- six 400×225 RGBA8 channels: appearance, linear depth, world normal, motion,
  semantic, and instance;
- canonical conventional target: 1600×900 RGBA8;
- capture schema: 2;
- conformance scene: deterministic S13 authored-population smoke;
- cohort/sequence/camera path: `validation` /
  `s13-default-follow-0001` / `default-follow`; and
- selected presentation frames: 300, 360, and 420 from each launch.

## Acceptance method

`zig build verify-nr0-ab` launches the installed Metal validation product twice,
captures both runs, validates every declared byte count and SHA-256 digest,
checks schema/shader/source/content and split provenance, checks stable and
compact identity mappings, exact cross-channel coverage, depth/normal/motion
encodings, and manifest-backed semantic/instance pixels, requires the two
logical/raw signatures to match, and produces a synchronized contact sheet.

Human review checks conventional/appearance alignment, monotonic depth, world
normal orientation, motion/history visibility, semantic class/part separation,
and distinct instance IDs. This review found and corrected an inverted
primitive normal caused by framebuffer-Y convention before final acceptance.

## Result

Both 3,840-frame runs completed cleanly with 964 simulation ticks, the full
twelve-member population cohort, every required authored role/activity state,
three captures, and zero capture failures. Six frame records were identical
across fresh launches. The selected frames contained 64,761–65,610 covered
pixels, 20–23 visible stable instances, 8–9 visible semantic colors, and valid
previous-frame history for every covered pixel. The generated artifacts remain
outside Git under the explicit acceptance root recorded in the validation
ledger.

This result accepts NR0-A and NR0-B only. It makes no model-quality, temporal,
performance-budget, promotion, or shipping-runtime claim. NR0-C must create a
new numbered multi-channel model experiment and keep its train, validation,
test, and stress sequences disjoint.
