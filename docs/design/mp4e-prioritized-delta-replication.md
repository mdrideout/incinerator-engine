# MP4-E Prioritized Delta Replication

**Status:** Implemented and accepted

**Date:** 2026-07-14

MP4-E replaces repeated whole relevant-state payloads with acknowledged,
bounded deltas while preserving the existing authoritative simulation and
feature semantics.

## Contract

- Every relevance baseline is a reliable, complete backend-neutral
  projection. The client acknowledges the relevance generation before normal
  snapshots begin.
- Every steady delta names the exact acknowledged snapshot sequence used as
  its base. Updates and explicit generational removals are materialized against
  that base, not against whichever packet happened to arrive previously.
- Client and authority each retain eight complete materialized projections.
  The storage is fixed and remains below the declared 4 MiB per-client
  baseline ceiling.
- A complete snapshot is sent at least once per second in the normal profile,
  or sooner when the acknowledged base is absent or old. A lost delta can
  therefore cause temporary staleness, never permanent divergence.
- Character, owned/dependent vehicle, carryable, and lifecycle/control traffic
  outrank replaceable NPC presentation. NPC updates retain their 10 Hz target
  but are omitted first under byte pressure.
- Per-connection byte credit is replenished from the declared downstream
  budget. If even high-priority replaceable state cannot fit, a snapshot is
  deferred. A 200 ms starvation ceiling permits a measured recovery send;
  reliable ownership and control messages never enter this degradation path.

## Separation of concerns

The authority builds a full semantic projection from feature-owned state. The
replication scheduler decides full versus delta, NPC cadence, byte admission,
and recovery. The protocol owns wire validation and materialization. The
client owns bounded base history and presentation application. Neither the
protocol nor client store knows about Flecs entities, Jolt handles, navigation
goals, durable-save records, or Steam services.

## Diagnostics

Authority diagnostics expose delta/full counts, acknowledgements, bytes,
deprioritized NPC updates, budget deferrals, starvation sends, full fallbacks,
maximum relevant entities, and allocated baseline memory. Client diagnostics
expose applied delta/full counts and missing bases.

The intentional-saturation profile uses only 1 KiB/s downstream credit. It
must exercise NPC deprioritization, snapshot deferral, starvation recovery,
and complete fallback while retaining bounded queues and zero base misses.

## Deliberate limits

This is semantic delta compression, not bit packing. Quantized transforms,
field masks, packet coalescing, and entropy compression should be added only
after real product traffic shows they are needed. The current design first
establishes correct base lifetime and overload behavior.
