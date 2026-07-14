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
the old district's unowned vehicle/carryable disappear, the owned dependency
is retained, and the relevant NPC cohort changes. A second client can contend
for the vehicle and carryable; the authority alone resolves ownership.

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

One previously recorded architectural pressure point remains outside this
network gate: `local_solo.zig` still presents a broad embedded-authority
administration facade to the legacy graphical `App` for editor, persistence,
streaming, replay, and diagnostics. Player input uses the session boundary and
the remote graphical client cannot access authority state, but the physical
`App`/authority decomposition items in MP1 remain open. New gameplay should
not widen that facade; close those MP1 items before treating every graphical
subsystem as a fully remote-capable client.
