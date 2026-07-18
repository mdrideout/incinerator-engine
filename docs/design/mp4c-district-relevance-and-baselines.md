# MP4-C District Relevance and Join Baselines

**Status:** implemented and accepted

**Last reviewed:** 2026-07-17

The authority loads the exact west/east sandbox district cohort sequentially
and assigns every participant one authoritative relevance district. A transfer
requires the participant (or owned vehicle) to be at least one metre inside an
active destination district, preventing boundary oscillation.

Each connection receives a reliable, bounded full baseline containing a
monotonic baseline ID, the exact relevant district set, district-relevant
characters and NPCs, and the complete current presentable vehicle/carryable
cohort. The client applies and acknowledges the baseline before the server
emits replaceable snapshots scoped to it. Reconnect and relevance transfer
advance the ID and repeat this lifecycle. Snapshots referencing another
baseline are ignored.

Owned characters, occupied vehicles, and held objects are retained as semantic
dependencies even when ordinary position filtering would omit them. Vehicles
and carryables also use a bounded-world interest reason while presentable; the
current maximum cohort is only four of each. A carryable can remain dormant
when its feature-owned district presentation is inactive. Leaving character or
NPC interest removes that entity from the client view; it does not destroy
canonical state. The baseline is a replication projection, never a durable
save image or a content payload.

The former exact-district rule for unowned vehicles and carryables was removed
after a human incident showed an authority-live vehicle disappearing until the
observer changed relevance district. Any future spatial policy for these
objects must have explicit hysteresis, typed inclusion/removal reasons, stable
identity evidence, and a no-pop acceptance journey. Do not restore coordinate
equality as an implicit interest policy.

The acceptance gate is `zig build verify-mp4c --summary all`.
