# RF7 Direct 800×450 Spatial Fidelity

**Status:** Accepted as an external live trial; unpromoted

## Question

Can one title-owned model trained from random initialization directly map the
existing native `160×90` deterministic input cohort to a native `800×450`
high-fidelity target with materially better spatial and color fidelity than
RF6, without temporal state or an intermediate reconstruction image?

## Fixed contract

```text
native 160×90 cheap inputs
  -> one direct learned 5× spatial reconstruction
  -> native 800×450 scene-linear HDR output
```

The target adapter renders each training target directly at `800×450`. No
`400×225` or `1600×900` pixel is an input, target, intermediate image,
comparison source, or acceptance reference for RF7. Historical artifacts are
retained only as evidence of earlier phases.

The model retains the six input-schema-v4 channels and four frame-global
controls, uses a learned direct `5×` reconstruction head, and is trained with
explicit linear RGB, log-luminance, chroma, final-output multiscale color,
gradient, frequency, boundary, geometry, and negative-radiance terms. Every
learned tensor begins at the declared random initializer.

## Gates

1. Produce a fresh whole-sequence corpus with direct native `800×450` Cycles
   targets and exact `5:1` correspondence.
2. Pass controlled overfit without opening validation or test pixels.
3. Train on overfit/train, select on validation, and open the test once.
4. Inspect complete `160×90 input | 800×450 model | 800×450 target` sheets and
   color-fidelity metrics; the product owner pre-authorized agent acceptance of
   visuals judged good enough for live trial.
5. Export the accepted checkpoint to an immutable external Core ML trial,
   verify numerical agreement, and run it through the existing live Neural
   Input / Output window.

RF7 does not authorize temporal work, promotion, or installed game content.

## Executed conclusion

RF7 completed on 2026-08-11. The fresh 108-pair direct native corpus passed
coverage and correspondence checks. A 1,245,147-parameter model initialized
from fresh random weights selected epoch 215 using validation only, then passed
the single-open test and stress cohorts. Linear-HDR MAE was `0.011649` on
validation, `0.016473` on test, and `0.013500` on stress. The external float32
Core ML bundle agrees within `0.00003147` maximum absolute error and completed
48/48 installed Metal predictions without failure or unknown category pixels.

The live result is visibly richer and materially closer to native `800×450`
truth than deterministic scaling. Fine high-contrast edge noise, emissive
ringing, narrow fixture coverage, and blocking CPU staging remain explicit
limitations. See
[`../../../docs/validation/rf7-direct-800x450-spatial.md`](../../../docs/validation/rf7-direct-800x450-spatial.md)
for roots, commands, measurements, and the live preview workflow.
