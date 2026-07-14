# MP4-C District Relevance and Join Baselines

**Status:** implemented and accepted

**Last reviewed:** 2026-07-14

The authority loads the exact west/east sandbox district cohort sequentially
and assigns every participant one authoritative relevance district. A transfer
requires the participant (or owned vehicle) to be at least one metre inside an
active destination district, preventing boundary oscillation.

Each connection receives a reliable, bounded full baseline containing a
monotonic baseline ID, the exact relevant district set, and only the projected
character/vehicle/carryable dependencies for that set. The client applies and
acknowledges the baseline before the server emits replaceable snapshots scoped
to it. Reconnect and relevance transfer advance the ID and repeat this
lifecycle. Snapshots referencing another baseline are ignored.

Owned characters, occupied vehicles, and held objects are retained as semantic
dependencies even when ordinary position filtering would omit them. Leaving
interest removes an entity from the client view; it does not destroy canonical
state. The baseline is a replication projection, never a durable save image or
a content payload.

The acceptance gate is `zig build verify-mp4c --summary all`.
