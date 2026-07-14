# MP1 Client/Authority Separation

**Status:** First character seam implemented; broader physical decomposition open

**Date:** 2026-07-13

## Implemented ownership

The solo product now owns a `local_solo_session.Session`, not a public
`sandbox_simulation.Simulation`. That session privately owns the one Flecs/Jolt
authority, a bounded typed link, a session client, and the replicated character
timeline. Character input crosses the same semantic identity, sequence, tick,
and validation shape used by the remote MP2 authority.

The remote graphical MP2 client links no simulation, Flecs, Jolt, feature
authority, persistence, or save-slot module. It owns input capture, connection
lifecycle, protocol identity, replicated state, camera, and rendering. The cold
MP2 authority owns simulation and character creation/mutation and links no SDL,
renderer, editor, visual assets, or lobby SDK.

```text
solo App -> LocalSoloSession -> typed local link -> embedded authority
                  |                                  |
                  +-- replicated client timeline <---+

MP2 client -> bounded codec -> GNS direct IP -> MP2 authority -> Simulation
```

`PersistentId`, `AccountId`, `SessionId`, `ParticipantId`, `ConnectionId`,
`ReplicatedEntityId`, `InputSequence`, and `SnapshotSequence` remain distinct.
The wire protocol contains no Flecs entity, Jolt handle, allocator state, save
bytes, or platform identity.

## Deliberate residual work

MP1 does not declare the legacy solo composition physically complete. The large
`App` still combines graphical, streaming, developer, authoring, validation,
and local-session administration. `LocalSoloSession` temporarily exposes a
broad set of explicit authority/admin pass-through operations so existing
save, replay, diagnostics, editor, vehicle, interaction, district, and NPC
behavior remains intact. `Simulation` also remains a broad internal facade.

Those are recorded pressure points, not compatibility promises. They should be
narrowed when the corresponding feature receives a real session request and
replication projection in MP4. A generic service locator, reflective ECS
replicator, or universal command bus is not the remedy.

## Current acceptance evidence

- Session identity/protocol/local-link/client/local-session/authority contract
  tests pass.
- The complete Debug suite passes the solo, save/restart, replay, diagnostics,
  editor-disabled, streaming, presentation, validation, and headless contracts.
- The product/validation marker boundary remains intact.
- The MP2 client module graph has no authority-state or persistence imports.
- The cold authority retains one world and passes the final-binary visual
  dependency scan.

