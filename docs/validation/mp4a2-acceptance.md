# MP4-A2 Vehicle Prediction Acceptance

**Status:** Automated, installed-product, repository, and extracted-package
acceptance passed; human feel check remains manual

**Date:** 2026-07-13

## Automated command

```bash
zig build verify-mp4 --summary all
```

The focused gate includes predictor contracts, client integration, the
deterministic clean/nominal/adverse/blackout matrix, real-GNS two-client seat
contention and reconnect, MP3 regressions, and accepted-ingress replay.

Focused result: 68/68 build steps and 41/41 tests passed.

## Prediction results

| Profile | Seeds | Maximum position error | Maximum orientation error | Soft / hard corrections | Horizon clamps |
|---|---:|---:|---:|---:|---:|
| Clean | 1 | 0.032 m | 0.23 deg | 0 / 0 | 0 |
| Nominal | 13, 31, 53 | 0.348-0.354 m | 0.22 deg | 6-8 / 0 | 0 |
| Adverse | 109, 223, 313 | 0.484-0.705 m | 0.27-0.42 deg | 11-12 / 0 | 2-4 |
| One-second blackout | 409 | 21.442 m raw divergence | 0.29 deg | 9 / 2 | 61 |

The blackout's raw divergence measures where an unbounded approximation would
have gone. Visible prediction stopped at 12 ticks; the eventual authority
sample intentionally caused a hard correction. Reliable enter/exit still
survived and the session converged.

Every non-blackout trial remained below the 2.5 m / 45 degree hard thresholds
with zero hard corrections. Soft-correction rates remained below the declared
180/minute ceiling. Repeating nominal seed 13 reproduced link and prediction
diagnostics exactly.

## Lifecycle and collision evidence

- Local throttle changes the owned vehicle presentation before a server sample.
- Acknowledged inputs are removed and unacknowledged inputs are reapplied.
- Prediction cannot advance beyond the 200 ms authority-relative horizon.
- Static collision-stop correction remains continuous and decays below 1 cm.
- A dynamic-impact-sized divergence snaps instead of preserving false motion.
- Exit and ownership loss clear prediction.
- Real GNS transport loss clears prediction; reconnect with the same participant
  and seat initializes it again from authority.
- Five exit candidates are tried in deterministic order. A teardown-only
  abandon transition is available only after all candidates are blocked.

## Installed macOS smoke

The installed server and graphical product were launched directly:

```bash
zig build install-mp2
./zig-out/bin/incinerator_mp2_server --port 27020
./zig-out/bin/incinerator_mp2_client \
  --connect 127.0.0.1:27020 --account 7001 --max-frames 180
```

The client created a native Metal device and swapchain, joined the authority,
rendered 180 frames, and shut down cleanly. This launch smoke proves the
installed graphical path; the controls below remain the human feel check.

## Repository and package results

The complete editor-free repository graph passed in both modes:

```bash
zig build test -Deditor=false --summary all
zig build test -Deditor=false -Doptimize=ReleaseFast --summary all
```

Each mode completed 201/201 build steps and 628/628 tests. The apparent
physics-debug `OutOfMemory` lines are intentional fault-injection evidence;
the aggregate results pass.

The filtered source-package gate also passed from its fresh extracted tree:

- extracted headless/content/tool graph: 98/98 steps and 196/196 tests;
- cold dependency/product/lifecycle graph: 32/32 steps and 52/52 tests; and
- headless source, logical-content, linkage, Mach-O, signal, restart, lag, and
  recovery boundaries all passed.

## Manual playtest

Run the server and one or two clients as documented in the README. For one
client:

1. walk to the blue vehicle and press `E`;
2. drive a loop with `W/S/A/D`, `Space`, and `Left Shift`;
3. press `P` repeatedly while steering to compare predicted and
   interpolation-only presentation;
4. press `F8` while driving and confirm the client reconnects, retains the
   confirmed seat, and resumes from authority without stale motion; and
5. press `E` to exit and confirm on-foot controls/camera return.

With a second client, confirm it sees the same chassis/driver and receives an
`unavailable` action result if it presses `E` while the seat is occupied.

## Nonclaims

- There is no client collision world or rollback.
- The simple predictor is not expected to reproduce Jolt suspension or impacts.
- Automated correctness and the installed launch smoke are not substitutes
  for the manual feel check.
- District collision/relevance remains MP4-C; MP4-B carry interaction is next.
