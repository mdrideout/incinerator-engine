# MP4-D Relevant NPC Acceptance

**Accepted:** 2026-07-14

- One authority owns 64 live NPCs: 32 in each active district.
- Two real-GNS clients reconstruct 32 relevant NPCs from JIP/reconnect
  baselines; west-to-east transfer replaces membership without canonical
  despawn.
- NPC updates run at the declared 10 Hz rate and retain identity/membership
  across interleaved 20 Hz character/vehicle/carryable snapshots.
- Clean, nominal, adverse, and blackout impairment trials retain bounded NPC
  membership and update counts while the older prediction/replay checks remain
  green.
- The Metal client renders only the replicated presentation state. Goals,
  routes, navigation references, controllers, Flecs IDs, and Jolt handles never
  cross the protocol.
- Moving the 512-entry semantic outbox to authority-owned heap storage removed
  a multi-megabyte stack aggregate while preserving fixed capacity.
