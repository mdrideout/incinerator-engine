# RF8 Direct 640×360 Spatial Sharpness

**Status:** Accepted external live trial; unpromoted

RF8 replaces the active RF7 trial cohort with one direct title-owned mapping:

```text
native 160×90 deterministic inputs
  → one random-initialized learned spatial model
  → native 640×360 scene-linear HDR output
```

There is no intermediate image or inherited checkpoint. Both axes use one
exact `4:1` pixel-center mapping, and both rasters consume the same 16:9 camera
projection.

RF8 also strengthens spatial reconstruction with a deeper native-output
refinement path, a structural feature branch, Laplacian-band and local-contrast
losses, and validation selection by an auditable spatial-quality score rather
than global MAE alone. Generated corpus, checkpoints, reports, and Core ML
bundles remain in immutable external artifact roots.

The runtime presents the scene as a centered, unscaled 640×360 surface. Larger
windows add black surrounding space; the Neural Input / Output tool displays
only the live native 160×90 source and diagnostics.

The executed corpus, validation-only selection, single-open test, stress,
Core ML export, 48-frame Metal gate, and real-window inspection are recorded in
[`../../../docs/validation/rf8-direct-640x360-spatial-sharpness.md`](../../../docs/validation/rf8-direct-640x360-spatial-sharpness.md).
