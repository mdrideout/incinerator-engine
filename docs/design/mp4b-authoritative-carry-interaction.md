# MP4-B Authoritative Carry Interaction

**Status:** implemented and accepted

**Last reviewed:** 2026-07-14

MP4-B extends the existing feature-owned S7 carry transaction through the
multiplayer session without introducing an inventory registry or a client
authority. A reliable, sequenced collect/drop request targets a generational
replicated ID and receives one correlated domain result. The server translates
the admitted request into `InteractionFeature`; only that feature decides
range, carrier state, district ownership, body removal/creation, and rollback.

Snapshots project one backend-neutral carryable pose, extents, velocities, and
optional participant holder. Persistent IDs, Flecs IDs, Jolt handles, district
runtime tickets, and durable records remain private. Remote and local clients
use the same confirmed projection; no speculative inventory exists.

Disconnect teardown is ordered: an admitted transaction settles, a held item
is dropped, vehicle ownership is released, then the character is despawned.
The graphical client renders the item and binds `F` to collect/drop. Reliable
action outcomes survive snapshot loss; replaceable pose state does not.

The acceptance gate is `zig build verify-mp4b --summary all`.
