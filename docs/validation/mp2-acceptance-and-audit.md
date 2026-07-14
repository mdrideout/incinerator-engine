# MP2 Acceptance and Architecture Audit

**Status:** Historical MP2 character acceptance; MP3-MP5 and M4 follow-ups were
subsequently accepted, and M5 embedded cohesion is now accepted separately

**Date:** 2026-07-13

## Delivered slice

- GameNetworkingSockets 1.5.1 is exact-pinned and built from source on Apple
  Silicon macOS through a narrow engine-owned C ABI shim.
- Four explicit lanes carry unreliable input, unreliable application-sequenced
  snapshots, reliable gameplay, and highest-priority reliable control.
- One cold authority and one presentation-only graphical client are independent
  products. Multiple client processes use distinct development accounts.
- Admission checks protocol, generated build cohort, MP2 logical-content cohort,
  account, reconnect credential, participant, connection, sequence, and tick.
- The authority creates separate characters, consumes intent, simulates at
  60 Hz, and publishes full character snapshots at 20 Hz.
- Join-in-progress, graceful/transport disconnect, handshake/idle timeout,
  automatic graphical reconnect, exact participant replacement, and rejection
  close semantics are bounded.
- Client/server diagnostics expose connection state, entity/snapshot age,
  transport ping/quality/rates/queued bytes, queue high-water, rejection,
  malformed-message, reconnect, and dropped-callback counts.

## Automated evidence

`zig build verify-mp2 --summary all` compiles both products, runs their
composition tests, scans the final authority binary for visual/editor/test
seams, and runs a real GNS loopback proof. The proof uses one cold authority
composition and two independent protocol clients; it does not substitute the
typed local link.

The acceptance run must demonstrate:

- first client joins and receives one relevant character;
- second client joins in progress and both receive two characters with distinct
  ownership;
- sequenced input changes only the authority-owned character, with processed
  input acknowledged in snapshots;
- a wrong build cohort receives an explicit rejection;
- transport disconnect enters reconnect grace and the new connection retains
  the original participant identity;
- transport callback overflow remains zero.

Authority unit tests additionally cover stale/duplicate input, malformed and
oversized traffic, duplicate-account authorization, terminal admission cleanup,
handshake timeout, and idle timeout without partial participant mutation.

A native graphical smoke launched the installed cold authority plus two
independent Metal clients (`account=501` and `account=502`) against the default
loopback-only listener. Both GPU devices initialized, the clients joined at
authority tick 537 with distinct participants, and the server admitted 126
messages and emitted 44 snapshots with zero rejection, malformed-message, or
callback-drop count before both
clients closed into reconnect grace.

## Audit findings

No new unrecorded P0 correctness or ownership finding remains in the MP2
character slice. The real transport proof found and closed three issues during
implementation:

1. reliable rejection followed by a non-lingering close could discard the
   rejection; close mode is now explicit;
2. unreliable snapshot reorder was propagated as a fatal client error; stale
   samples are now counted and dropped;
3. terminal admission and locally closed handles could remain temporarily
   pollable; authority/transport ownership now ends explicitly.

The following table preserves the next-phase disposition recorded at MP2 close;
it is not a current implementation-status table:

| Pressure point | Disposition |
|---|---|
| Legacy solo `App` and `Simulation` were physically broad | Historical MP1 pressure point; accepted M5 uses an opaque shared-authority placement and extracted owners while retaining the live `Simulation` facade as a measured private pressure point |
| No local prediction or reconciliation | MP3 |
| No deterministic latency/loss/duplicate/reorder harness | MP3 |
| Full fixed character snapshots; no delta baseline/relevance scheduler | MP4 |
| Only character state is networked | MP4 vehicle, interaction, district, and NPC slices |
| MP2 content cohort names a fixed proof world, not an installed cooked catalog | MP4 room/catalog admission |
| No Steam lobby, P2P, SDR, tickets, or proprietary SDK | MP5, deliberately deferred |
| Development `AccountId` is self-declared and unauthenticated | Server defaults to loopback; real identity/ticket admission is required before public exposure |
| No Linux/Windows or hosting fleet | Deliberately deferred product/deployment decisions |

At MP2 close, MP3 was therefore the next networking phase: prediction and an
in-process deterministic impaired-link adapter preceded expansion of the
protocol to the rest of the sandbox. Those follow-ups are now accepted through
M4; see [`m4-multiplayer-foundation.md`](m4-multiplayer-foundation.md). M5's
current status lives in
[`m5-client-authority-cohesion.md`](m5-client-authority-cohesion.md).
