# MP4-E Acceptance

**Accepted:** 2026-07-14

Run:

```sh
zig build verify-mp4e -j1 --summary all
```

The dedicated saturation proof reported:

```text
MP4E_SATURATION_PASS deltas=57 full_fallbacks=11 acks=68 npc_deprioritized=38 deferred=74 starvation=13 bytes=20559 baseline_memory=36288 relevant_max=35 client_npcs=32
```

The same implementation completed clean, nominal, adverse, and blackout
prediction/vehicle trials plus the real two-client GNS loopback. Existing MP3
traffic fell from roughly 15 KiB/s of downstream full relevant state to about
2.6 KiB/s in representative clean/nominal runs. This is an observation from
the fixed proof world, not a production bandwidth promise.

Acceptance establishes:

- exact acknowledged bases and explicit removals materialize correctly;
- bounded history recovers through periodic full state;
- intentional saturation drops NPC cadence before high-priority state;
- deferral and starvation recovery are visible and bounded;
- no ownership/lifecycle message is converted to replaceable traffic;
- client base misses and authority/client queue overflows remain zero in the
  saturation proof;
- relevant entities and baseline memory remain below declared ceilings.
