# MP4-B Carry Interaction Acceptance

**Accepted:** 2026-07-14

The dedicated `verify-mp4b` gate passed 71/71 build steps and 44/44 inherited
tests on macOS/Apple Silicon with Zig 0.16.0.

- Clean, nominal, repeated nominal, and adverse-blackout trials completed a
  reliable collect/drop pair with exact client/server action accounting.
- Repeated nominal trials matched completion tick, impairment diagnostics, and
  accepted-ingress fingerprint.
- A graceful disconnect while holding preserved the carryable and recorded one
  forced interaction cleanup before character teardown.
- The real GameNetworkingSockets loopback admitted two clients contending for
  one item: one collect and drop succeeded, the competing collect was rejected,
  and ownership was never duplicated.
- The installed Metal client renders confirmed carryables; `F` collects/drops.
- Protocol payload, session queues, feature queues, and replicated arrays remain
  compile-time bounded.
