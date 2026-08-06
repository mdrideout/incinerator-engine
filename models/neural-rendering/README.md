# Promoted Neural Rendering Models

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

Do not add weights before NR0 implements and verifies promotion, artifact
storage, repository-size policy, and distribution rights.

