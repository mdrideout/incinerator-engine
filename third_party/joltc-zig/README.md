# Incinerator JoltC Build Package

This package adapts [`jrdurandt/joltc-zig`](https://github.com/jrdurandt/joltc-zig) commit `c7ff571d475ae4ef26e327e6ffcd81f158e93d97` so all transitive source URLs are immutable.

It builds:

- Jolt Physics `5.5.0` at commit `23dadd0e603f1b321142d4c74df07fce85064989`;
- `amerkoleci/joltc` at commit `52d8c98df523f449eb3e01b1060a0fde052970d1`.

The ABI policy is explicit: 32-bit object layers, single-precision world
coordinates, exceptions disabled, and JoltC's compile-time ABI assertions
enabled. Cross-platform deterministic compilation is an explicit build option
and is disabled by the engine today; an authoritative server does not require
client-side lockstep, and the performance/behavior tradeoff must be measured
before enabling it.

The wrapper build logic remains under its original MIT license in `LICENSE`. Jolt Physics and JoltC retain their respective upstream licenses in the fetched packages.
