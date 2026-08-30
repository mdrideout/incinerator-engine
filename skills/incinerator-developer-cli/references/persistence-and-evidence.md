# Persistence and Evidence

Read this reference before requesting a world save, claiming restoration, or
capturing a rendered frame.

## World snapshots

`world.save` reports admission separately from completion. Poll the returned
save request with `world.save-result` until it is `committed` or `failed`.
Record the slot, generation, payload size, and typed detail.

`payload_bytes` is the canonical snapshot payload inside the durable envelope.
The fixed sandbox slot does not currently expose a storage generation, so a
null `generation` is expected and must be reported as null rather than guessed.

A committed result proves that the graphical product wrote its fixed durable
slot. It does not prove that an ordinary graphical relaunch loads that slot.
The accepted S5 cold-restore architecture uses a separate fresh
SDL/editor/GPU-free verifier with matching world and content expectations.
Do not claim cold restoration unless that verifier actually consumed the
saved cohort.

## Correlated frames

Frame capture requires an editor build with incident capture enabled.
`frame.capture` is admitted through the existing incident owner. Poll with
`frame.inspect` until it is `captured` or `failed`.

For a captured frame, record the artifact path, authority tick, presentation
frame, wall time, run identity, and capture ID. The artifact path grants access
only to the returned evidence; it is not permission to browse unrelated files.

Use a frame to verify visible consequences after the authoritative result is
terminal. A picture alone is not proof of an accepted authority transaction,
and a transaction result alone is not proof of the intended visual outcome.
