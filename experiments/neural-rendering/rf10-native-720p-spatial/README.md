# RF10 Native 720p Spatial Cohort

**Status:** Complete; accepted by the product owner as the retained external,
unpromoted stopping point; neural-rendering implementation paused

Further work requires an explicit product-owner resume request under the
[pause decision](../../../docs/design/neural-rendering-pause.md).

RF10 implements the direct native `256x144 -> 1280x720` decision recorded in
[`docs/design/rf10-native-720p-spatial-cohort.md`](../../../docs/design/rf10-native-720p-spatial-cohort.md).

The experiment owns fresh native pixels, new whole-sequence split assignments,
new random initializers, new checkpoints, a single-open sealed test, separately
manufactured post-selection stress, and an explicit external Core ML trial. It
reuses repository code and the RF9 visual-cause taxonomy; it does not reuse RF9
pixels, weights, optimizer state, metrics, review sheets, or approval.

RF10-A and RF10-B established the engine and target schemas and a fresh direct
native target audit. RF10-C through RF10-G completed fresh corpus manufacture,
random-origin controlled fit, validation-only selection, a single-open sealed
test, newly manufactured post-selection stress, exact Core ML export, and
macOS runtime acceptance. The committed `controlled-overfit.json` and
`held-out.json` configurations own the random-origin training gates. They
reuse RF9's validation-winning bilinear-refinement topology only as code
structure and load no earlier tensor or optimizer state. Generated artifacts
remain under explicit external roots and never enter this directory.

The accepted trial contains 1,062,587 parameters and remains unpromoted. Exact
external roots, metrics, rejected harness evidence, known limitations, and
reproduction commands are recorded in
[`docs/validation/rf10-native-720p-spatial.md`](../../../docs/validation/rf10-native-720p-spatial.md).
