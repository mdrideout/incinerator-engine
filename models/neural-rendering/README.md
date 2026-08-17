# Promoted Neural Rendering Models

> **Product-track pause (2026-08-17):** Promotion is not authorized. RF10 is
> retained externally and unpromoted; this directory must remain empty unless
> the product owner explicitly resumes neural rendering and approves a later
> promotion transaction. See
> [`docs/design/neural-rendering-pause.md`](../../docs/design/neural-rendering-pause.md).

This is the source location for deliberately promoted runtime model bundles used
by the open Incinerator sandbox. It is currently empty: no model has been
selected, bundled, licensed, or accepted.

A future successful promotion creates:

```text
models/neural-rendering/
  selected-model.json
  bundles/
    <immutable-model-id>/
      manifest.json
      model.<runtime-format>
      evaluation.json
      provenance.md
      RIGHTS.md
```

`selected-model.json` identifies one immutable model ID and digest. It is not a
symlink, version range, experiment path, or `latest` alias. The build will
eventually install only that selected bundle beneath:

```text
share/incinerator/content/neural-rendering/
```

The repository's sandbox bundle must be independently redistributable under the
future engine policy. A separately licensed game owns its own target assets,
datasets, experiment history, promoted bundles, selection manifest, and rights
record while consuming the same engine bundle contract.

Under [ADR-026](../../docs/adr/026-from-scratch-title-neural-renderer.md), every
learned artifact in a promoted bundle must descend from a declared random
initialization and title-owned training data through the repository-owned
framework. A fine-tuned, distilled, adapted, or repackaged external pretrained
checkpoint is not eligible for this directory.

Do not add weights before NR0 implements and verifies promotion, artifact
storage, repository-size policy, and distribution rights.
