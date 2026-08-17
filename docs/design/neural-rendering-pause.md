# Neural Rendering Product-Track Pause

**Status:** Paused indefinitely by product owner

**Effective date:** 2026-08-17

**Retained baseline:**
[RF10 Native 720p Spatial Cohort](rf10-native-720p-spatial-cohort.md)

**Validation:**
[RF10 Native 720p Spatial Validation](../validation/rf10-native-720p-spatial.md)

## Decision

Neural-rendering implementation is paused. RF10 is the accepted stopping point:
a direct native `256x144 -> 1280x720`, title-specific, random-initialized
external trial. It remains unpromoted and is not installed or selected as
shipping game content.

Deterministic rendering is now the active product focus.

This is a portfolio decision, not a rejection of the architecture or an
authorization to remove the work. Preserve the existing code, tests, contracts,
documentation, external evidence, and trial workflow so the track can be
reassessed deliberately later.

## Hard stop for agents

Unless the product owner explicitly requests that neural-rendering work resume,
do not:

- create a new neural-rendering phase or experiment;
- capture or manufacture a new corpus or target cohort;
- train, fine-tune, ablate, optimize, export, or promote a model;
- begin NR6 temporal work, NR7 detail work, or NR0-E through NR0-G;
- change neural input, target, bundle, selection, or runtime schemas;
- expand the neural runtime, editor UI, diagnostics, or platform support; or
- perform speculative neural-rendering cleanup or refactoring.

Do not interpret a nearby deterministic-rendering task, an outdated “next
phase” statement, a deferred phase, or a failing optional neural trial as
authorization to restart this track.

Read-only explanation, inspection, and historical evidence review are allowed.
Small factual documentation corrections and minimal maintenance required to
keep shared code compiling are allowed. If deterministic-rendering work exposes
a substantive neural-only repair or redesign, report it and leave it paused
rather than expanding scope.

## Preservation and ownership

- RF10's committed contracts and small reproducibility evidence remain in Git.
- Generated datasets, checkpoints, reports, exports, and the trial bundle remain
  under their external artifact roots; do not copy them into the repository.
- Do not delete or rewrite historical cohorts merely because they are inactive.
- Do not create a mutable `latest` pointer or silently promote RF10.
- Deterministic-rendering architecture should serve deterministic product needs;
  it does not need to preserve speculative compatibility with a future model.
- The accepted neural architectural boundary remains valid: deterministic
  simulation is authority, learned output is presentation, and promotion is an
  explicit transaction.

The retained RF10 campaign is:

```text
~/Library/Application Support/Incinerator/neural-rendering/experiments/
  rf10-native-720p-campaign-20260814T015457Z
```

Its `trial-bundle/` child is the retained runnable external trial. The original
artifact is immutable evidence, not selected runtime content.

## Restart gate

Only an explicit product-owner request to resume neural rendering reopens the
track. A restart begins with a short reassessment, not by automatically starting
the previously deferred NR6 phase:

1. audit deterministic renderer, presentation schema, content, macOS runtime,
   and toolchain drift since RF10;
2. verify the retained RF10 campaign and trial bundle without mutating them;
3. decide whether RF10 remains a useful baseline or a fresh cohort is required;
4. choose the next product question—spatial fidelity, temporal stability,
   performance, promotion, or another bounded goal; and
5. write and approve a new implementation phase before changing code or
   producing artifacts.

Until that explicit gate is opened, there is no neural-rendering next phase.
