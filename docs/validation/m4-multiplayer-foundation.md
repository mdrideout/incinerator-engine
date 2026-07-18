# M4 Multiplayer Foundation Gate

**Status:** Accepted on native Apple Silicon macOS

**Date:** 2026-07-14

Run the automated gate:

```sh
zig build verify-m4 -j1 --summary all
```

This composes the MP4 gameplay/fault/delta closeout, MP5 room admission, real
two-client GNS loopback, cold authority and validation boundary checks, the
installed 64-NPC Metal smoke, and static architecture checks.

## Manual playable test

Use Zig 0.16.0, then open three terminals:

```sh
zig build install-mp2
./zig-out/bin/incinerator_mp2_server --port 27020
./zig-out/bin/incinerator_mp2_client --connect 127.0.0.1:27020 --account 1
./zig-out/bin/incinerator_mp2_client --connect 127.0.0.1:27020 --account 2
```

The two client windows share one authority. Controls are WASD/Space for the
character; E enters/exits the vehicle; driving uses W/S throttle, A/D steering,
Space brake, and Left Shift handbrake; F collects/drops the carryable; P toggles
vehicle prediction; F8 manufactures a disconnect/reconnect; Escape quits.

Walk or drive east across the district boundary to observe relevance transfer:
the relevant character and NPC cohort changes while the bounded vehicle and
carryable cohort remains continuously projected. Occupied vehicles and held
objects are also retained as semantic dependencies. A second client can
contend for the vehicle and carryable; the authority alone resolves ownership.

The 2026-07-14 acceptance originally expected unowned vehicles and carryables
to disappear at this seam. Human incident evidence showed that exact-district
policy created a visible pop, so the expectation was corrected on 2026-07-17.
This bounded-world policy is deliberately simpler and safer for the current
four-vehicle/four-carryable budgets.

## Accepted boundaries

- Solo uses an embedded authority and typed local client/session link.
- Remote clients use the lightweight replicated world; the graphical network
  client imports no authoritative Simulation, Flecs, or Jolt world.
- Dedicated direct-IP GNS is the executable multiplayer placement on macOS.
- Listen remains a compatible placement contract, not a productized or tested
  NAT/relay path. Host migration remains deferred.
- Durable saves, replication snapshots/delta history, prediction history, and
  accepted-ingress replay remain distinct artifacts.
- Steam is an optional identity/routing adapter boundary. The open core has no
  Steamworks dependency.

No unrecorded P0, P1, or P2 finding remains in the M4 foundation scope. This is
not a claim of production Internet readiness: accounts, entitlement, public
hosting, DDoS protection, secret rotation, matchmaking operations, moderation,
and MMO partitioning remain later programs.

At M4 acceptance, one previously recorded architectural pressure point remained
outside this network gate: `local_solo.zig` presented a broad embedded-authority
administration facade to the graphical `App` for editor, persistence,
streaming, replay, and diagnostics. Player input used the session boundary and
the remote graphical client could not access authority state, but the physical
`App`/authority decomposition items remained open. This paragraph preserves the
M4 acceptance boundary; it is not the current M5 implementation description.

## Subsequent M5 work

That retained pressure point is closed by the accepted
[`M5 Client/Authority Cohesion`](../design/m5-client-authority-cohesion.md)
gate and its [acceptance record](m5-client-authority-cohesion.md). M4 remains
accepted as the multiplayer network foundation; M5 separately accepts the
embedded-solo semantic, clock, persistence, and physical ownership boundary.

M5 replaces the flat local facade and ordinary
vehicle/carry bypasses with an opaque embedded placement over the shared
authority core, role-scoped capabilities, replicated player-facing state, and
explicit district-streaming/persistence owners. That implementation does not
change this historical M4 result; it is accepted by the separate M5 record.
