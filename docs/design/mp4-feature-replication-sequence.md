# MP4 Feature Replication Sequence

**Status:** Future, after MP3 acceptance

**Date:** 2026-07-13

MP4 is split into pressure-driven vertical slices. Each slice must reuse the
MP3 authority, impairment, prediction, diagnostics, and replay contracts; none
may introduce generic ECS replication.

1. **MP4-A vehicle:** authoritative enter/drive/exit, ownership transfer, and
   locally controlled vehicle prediction only if measured latency requires it.
2. **MP4-B interaction:** carry/drop requests, confirmed ownership transitions,
   cancellation, reconnect, and cross-district transfer.
3. **MP4-C district relevance:** admitted cooked catalog cohort, district/cell
   interest, semantic dependencies, join-in-progress, and bounded baselines.
4. **MP4-D NPCs:** lower-rate relevant NPC projections and lifecycle events;
   AI goals and behavior remain authority-private.
5. **MP4-E replication efficiency:** prioritized byte/entity budgets, delta
   baselines, acknowledgement, fallback full snapshots, and measured overload
   degradation.

Each subphase ends with nominal/adverse impairment, save/restart, reconnect,
join-in-progress, bandwidth, and architecture-boundary evidence before the next
feature expands the protocol.
