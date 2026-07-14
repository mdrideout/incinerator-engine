# MP4-D Relevant NPC Projection

**Status:** implemented and accepted

**Last reviewed:** 2026-07-14

The cold authority bootstraps the full bounded 64-NPC cohort only after both
exact sandbox districts are active. `NpcFeature` remains the sole owner of
goals, routes, district transfer, controller lifecycle, and movement. The
session projects only generational identity, pose, velocity, facing, and the
minimum active/waiting presentation state.

NPC membership is filtered by the acknowledged participant district. A full
baseline replaces relevant NPC membership on join, reconnect, or district
transfer. Steady NPC samples are present at 10 Hz inside the 20 Hz world
snapshot stream; snapshots without an NPC update preserve prior membership.
The lightweight client interpolates those samples and can never submit an NPC
goal or AI decision.

The acceptance gate is `zig build verify-mp4d --summary all`.
