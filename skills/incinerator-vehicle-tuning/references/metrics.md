# Vehicle dynamics metric contract

The executable `tools/vehicle_dynamics.zig` runs each scenario in a fresh real
Jolt world at 120 Hz on a 1,000 m square static support surface. It compares an
explicit pre-tuning profile named `legacy` with the authoritative defaults
named `current`.

- **Stopping distance:** accelerate to at least 15 m/s, apply full service
  brake, and integrate horizontal displacement until speed is below 0.25 m/s.
- **Steady-state turn radius:** after six seconds of constant throttle and
  steering, divide sampled path length by accumulated yaw change over the next
  six seconds.
- **Lateral slip:** angle between chassis-forward and horizontal velocity.
  The turn reports a mean; slalom and skid report peaks.
- **Slalom response:** alternate steering every 0.8 seconds. Report horizontal
  X excursion, peak yaw rate, and peak slip. Excursion is scenario-specific,
  not a universal agility score.
- **Skid recovery:** induce a 1.25-second steering/hand-brake event, release to
  low throttle and neutral steer, and measure until slip remains below three
  degrees for 0.5 seconds.
- **Rollover tendency:** accelerate, hold a high-speed full-steer input, report
  maximum chassis-up tilt, and fail if chassis-up crosses the horizon.

Interpret the metrics together. A larger radius can come from reduced steering
lock rather than poor grip; more lateral excursion can coexist with lower slip
because the vehicle carries more controlled speed. Preserve the exact input,
tick rate, thresholds, and legacy profile when comparing cohorts.
