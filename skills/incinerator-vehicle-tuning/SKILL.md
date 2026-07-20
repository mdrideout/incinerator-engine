---
name: incinerator-vehicle-tuning
description: Measure, diagnose, and tune Incinerator Engine four-wheel vehicle dynamics on the real Jolt adapter. Use for changes to tire friction, braking, steering, suspension, center of mass, drivetrain, wheel layout, handling feel, stopping distance, turn radius, lateral slip, slalom response, skid recovery, or rollover behavior.
---

# Incinerator Vehicle Tuning

Use the deterministic real-Jolt measurement cohort before changing handling.
Do not tune from a single rendered drive or hide behavior inside the Jolt
adapter. Gameplay tuning belongs in `src/features/vehicle/contract.zig`; the
backend-neutral physics shape belongs in `src/engine/contracts/physics.zig`.

## Workflow

1. Read `references/metrics.md` and
   `../../docs/validation/vehicle-dynamics.md` completely.
2. Run `zig build vehicle-dynamics-report -Deditor=false` and preserve the
   legacy/current output with the proposed change.
3. Change the smallest authoritative tuning surface. If a new simulation
   value is required, carry it through validation, persistence, replay, and
   the Jolt adapter explicitly.
4. Re-run the measurement. Compare every metric, not only the desired one;
   handling changes are coupled.
5. Run `zig build test-vehicle-dynamics -Deditor=false`, the vehicle feature
   and physics tests, then the full `zig build test -Deditor=true` gate.
6. Perform a rendered human drive only after deterministic results pass.
   Exercise acceleration, braking, constant-radius turns, alternating slalom,
   hand-brake recovery, collision, and curb/obstacle transitions.
7. Update the vehicle dynamics report with the exact cohort, result table,
   interpretation, and any accepted tradeoff.

## Guardrails

- Keep macOS/Apple Silicon as the current product validation target.
- Never add frame-rate-dependent input or presentation state to authority.
- Do not call a subjective feel change an improvement without measured
  evidence and a stated tradeoff.
- A `potentially_stalled` NPC or a lost wheel contact is diagnostic evidence,
  not permission to teleport or silently correct authority.
- Advance snapshot/replay/wire cohorts when their encoded meaning changes;
  this repository is greenfield and does not retain compatibility decoders.
- The automated rig is a flat, deterministic characterization surface. It is
  not a claim about final tires, terrain, assists, controller curves, or fun.

## Handoff

Report the command, both measurement rows, important deltas, full tests, and
the remaining rendered test list. Link the persistent vehicle dynamics report.
