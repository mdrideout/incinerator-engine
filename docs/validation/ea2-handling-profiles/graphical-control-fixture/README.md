# Authored graphical control fixture

This is a deliberately authored input schedule, not a captured human incident.
It exercises the mapping-2 graphical replay loader and normal product loop:
walk to Courier, enter, forward, S brake/reverse, W brake/forward, Space with
steering, W+S stop, then exit with Space held. Real SDL queue coverage is a
separate native acceptance test. Graphical timing remains best effort.

From the repository root, after an editor build/install:

```sh
zig build run -Deditor=true -- --replay-incident="$PWD/docs/validation/ea2-handling-profiles/graphical-control-fixture"
```

The run exits after tick 1180 and writes a new incident folder. Ordinary
completion does not materialize a flight recording. Flag an anomaly during
the run to request one; the native driving test separately writes complete
accepted-ingress `.icrp` files for each car.
