# MP2.1 Transport Lifecycle Stabilization

**Status:** Implemented and accepted

**Date:** 2026-07-13

## Purpose

MP2 proved the real GameNetworkingSockets route, but the graphical client still
uses frame count as a reconnect clock and cannot distinguish a recoverable
transport loss from an authority that deliberately stopped. MP2.1 closes that
lifecycle gap before prediction adds more client state.

## Contract

- Reconnect scheduling uses monotonic elapsed time, never render frames.
- Recoverable transport loss uses capped exponential backoff with deterministic
  per-account jitter. A successful welcome resets the attempt count.
- Explicit rejection, requested disconnect, protocol failure, and authority
  shutdown are terminal for the current client invocation. They never enter an
  automatic reconnect loop.
- The authority sends a reliable `authority_stopping` semantic message before
  closing each admitted connection with transport linger.
- A new welcome re-anchors the estimated authority clock. Time spent
  disconnected cannot create an input catch-up burst.
- Retry state, terminal reason, attempts, and next-delay are observable.

## Acceptance

- [x] A transport loss retries using monotonic, capped backoff.
- [x] `authority_stopping` and cohort rejection do not retry.
- [x] Reconnect welcome resets input/authority time without stale catch-up.
- [x] Shutdown and retry policy have pure deterministic tests.
- [x] The real-GNS MP2 proof and graphical product still pass.

## Deliberate limits

MP2.1 does not add lobby reconnection, room reassignment, process supervision,
or an infinite retry promise. It only makes one client invocation's direct-IP
session lifecycle explicit.
