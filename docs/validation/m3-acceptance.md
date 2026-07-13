# M3 Pre-Server Readiness Acceptance Record

> **Historical pre-cleanup record.** This document preserves the evidence and
> claims recorded when M3 closed. Its counts and binary inventory describe that
> dated tree. See the [current macOS readiness record](macos-readiness.md) and
> [cleanup plan](../../CLEANUP_PLAN.md) for the consolidated tree.

**Date:** 2026-07-13

**Status:** Complete on Apple Silicon macOS

**Scope:** The final pre-multiplayer gate. S9 multiplayer and every secondary
platform remain deferred.

## Accepted product boundary

`-Dproduct=headless` selects a cold build graph before client dependencies are
resolved. The installed allowlist is exactly:

```text
bin/incinerator_headless
etc/incinerator/headless/config.example.json
share/incinerator/headless/content.json
```

The final Mach-O links only `/usr/lib/libSystem.B.dylib`. The cold graph
resolves Zig's standard library/runtime, the engine/kernel/features, the exact
`zflecs`/Flecs cohort, the engine-owned JoltC/Jolt 5.5 cohort, and required
Darwin system facilities. SDL, Metal/GPU, renderer, editor, ImGui/zgui,
zmath, zmesh, zstbi, shader tools/artifacts, source art, and visual cooked
content are absent from source imports, dependency resolution, final markers,
linkage, and the installed tree.

The S4-only diagnostic fault probe is also absent from the cold Mach-O: its
fixed error name, system name, and constructor markers do not survive product
linking.

The artifact owns exactly one `Simulation` and one external producer router on
one authority thread. It admits bounded exact-schema configuration, logical
content, and save bytes before constructing the world. Linux/SteamOS and
Windows are rejected and create no current abstraction, build, or test duty.

## Authority and capacity evidence

The external seam supports exactly two generational producers, a shared
16-entry ingress FIFO, 16 live transactions, eight pending transactions per
producer, and eight reserved result entries per producer. The integrated M3
soak proves distinct quota-full, ingress-full, transaction-table-full, and
result-capacity-full statuses, recovery, exact owner delivery, clean unregister,
and zero protocol-fault handbacks. Expected non-relocation outcomes are handed
back to and retained by the composition rather than discarded.

Every gameplay feature has a fixed command/outcome/event contract. Full
capacity behavior is intentionally proven by feature-specific tests rather
than falsely attributed to the integrated soak:

- crates: `crate bounded queues reject atomically then drain and recover without allocation`;
- character: `character bounded command reservations drain and recover without allocation`
  plus `character event saturation drops exactly and accepts production events after drain`;
- vehicle: `vehicle bounded command reservations drain and recover without allocation`
  plus `vehicle transition events saturate, drop exactly, and recover after drain`;
- district: `pending command storage is explicitly bounded`, `outcome reservations
  reject admission without fault and recover after drain`, and `full event storage
  drops observability without fault and recovers`;
- interaction: `fixed command and outcome budgets saturate visibly without mutation loss`;
- NPC: `NPC authority queues reserve all outcomes and enforce population capacity`
  plus `actual saturated NPC events retain per-kind drop accounting and recover`;
- router: ingress, reserved-delivery, producer-slot, and shutdown-drain saturation tests;
- authority: exact two-producer completion, retained protocol evidence, full-authority drain, fault closure, and immutable stopped-state tests.

These tests are included in the full engine matrix; the cold product also runs
dedicated router and authority suites. The soak inventories every feature and
router capacity, peak, rejection/drop count, final occupancy, and reservation.

## Installed lifecycle matrix

The real installed product gate covers:

- `fresh`, `restore_required`, and `fresh_or_restore` startup;
- missing, unknown-field, malformed, oversized, stale, and mutually
  incompatible config/content inputs before world acquisition;
- corrupt and oversized save rejection without changing the committed slot;
- stale candidate recovery without promotion;
- injected candidate-creation/storage failure with the prior save unchanged;
- real `SIGTERM` and `SIGINT` during producer traffic, bounded drain, durable
  commit, process exit, and fresh-process restore;
- forced hard lag through `SIGSTOP`/`SIGCONT`, ordered non-success drain, and
  preservation of the prior committed save;
- a closed stdout after durable rename, reported on stderr as degraded
  observability with `save=committed`, followed by successful restore.

Runtime, counter-exhaustion, routing-protocol, unread-output, non-quiescent, or
pre-rename storage faults cannot pass the healthy save boundary. The storage
adapter's injected pre-rename failure tests prove the old slot remains
authoritative. A successful rename followed by an observability or directory
sync warning is never misreported as an uncommitted save.

## Performance and ownership evidence

Three fresh ReleaseFast routine trials and one opt-in long trial are recorded
in [`m3-baseline.md`](../performance/m3-baseline.md). All routine trials ran
32,768 exact ticks; the long trial ran 131,072. The worst routine p99 was
560,500 ns against an 8,333,333 ns ceiling. All trials finished with zero live
allocator bytes, exact producer completion ownership, fully drained shutdown,
and canonical before/after restore bytes. RSS is recorded honestly as absolute
fresh-process `getrusage` max RSS, not a paired delta.

Final integrated ownership is two districts/six district bodies, one character,
one vehicle, one carryable, 64 NPCs, ten native physics bodies, and 65 native
CharacterVirtual controllers before save. After teardown there are zero live
worlds, authorities, queues, transactions, results, renderer/GPU resources, or
native owners.

## Verification commands

```sh
zig fmt --check build.zig build.zig.zon src tools third_party/joltc-zig
zig build -Dproduct=headless test --summary all
zig build -Dproduct=headless -Doptimize=ReleaseFast test --summary all
zig build -Dproduct=headless verify-cold-headless-product --summary all
zig build -Dproduct=headless -Doptimize=ReleaseFast measure-m3 --summary none
zig build -Dproduct=headless -Doptimize=ReleaseFast measure-m3-long --summary none
zig build test -Deditor=false --summary all
zig build test -Doptimize=ReleaseFast -Deditor=false --summary all
tools/verify_source_package.sh
git diff --check
```

The final command counts and independent review disposition are recorded in
the overhaul plan's progress log and the current macOS readiness record.

## Trust, security, and deferred work

This is a bounded local operational product, not an Internet security boundary.
It has exact schemas, checked arithmetic, cohort admission, path/slot
restrictions, generational handles, finite queues, immutable first-fault state,
and fail-closed persistence. It does not claim authentication, authorization,
encryption, remote rate limiting, secrets management, privilege separation,
anti-cheat, distributed durability, or incident operations.

S9 retains protocol framing, remote idempotency/tombstones, transport abuse
controls, replication, prediction/reconciliation, interest distribution,
join/reconnect, service persistence, deployment, and Internet threat modeling.
No transport or speculative multi-platform framework was introduced.

The repository intentionally has no engine license by owner direction.
Distribution remains blocked until a license, dependency notices, and the
remaining release obligations are completed; M3 acceptance grants no
redistribution rights.
