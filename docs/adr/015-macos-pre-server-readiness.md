# ADR-015: Apple Silicon macOS Pre-Server Readiness

**Status:** Accepted, implemented, and validated in M3

**Date:** 2026-07-13

**Platform:** Apple Silicon macOS only

## Context

S0 through S8 establish a feature-oriented, fixed-tick simulation with durable
logical state, exact content cohorts, bounded diagnostics, same-cohort replay,
streamed district ownership, and one representative NPC population. The
existing headless host proves that this authority can run without a renderer,
but a conformance host is not yet an operational server-shaped product.

Before networking is considered, M3 must prove the smaller boundary that a
future authoritative server would depend on: one cold-installed headless
process can admit exact startup inputs, own one world, accept bounded external
work, deliver every accepted completion to its owner, withstand saturation and
long virtual-time workloads, restore durable state, and stop without replacing
a healthy save with faulted state.

The current `zflecs` integration intentionally permits one owned Flecs world at
a time. That restriction prevents atomic old/new world replacement in one
process. It does not prevent the selected M3 model, where one process owns one
authoritative world and replacement happens through a validated process
restart.

M3 is a pre-network capability gate. It must not pull transport, replication,
accounts, distributed storage, secondary platforms, or MMO operations into the
single-player overhaul.

## Decision

### One authoritative world per process

The server-shaped product owns exactly one `Simulation` and one owner thread.
Flecs mutation, Jolt stepping, feature commands, external-producer routing,
outcome delivery, snapshot creation, and final teardown occur on that thread.
Workers may prepare copied bounded data, and a signal handler may publish one
atomic stop flag, but neither may touch world authority.

Startup validates configuration, logical content identity, save-envelope
metadata, save integrity, and snapshot/world compatibility before acquiring
Flecs or Jolt authority. A loaded world is never hot-swapped. Tests may
deinitialize one world and then construct another sequentially, but the
product recovery contract is durable commit, process exit, and fresh-process
restore.

This is a deliberate product constraint, not a generic world manager. A later
need for multiple simultaneous worlds, in-process fork, or zero-downtime world
replacement requires a new decision and may replace or fork the `zflecs`
wrapper.

### A genuinely cold macOS headless product

`-Dproduct=headless` selects the authority build before the client build graph
resolves visual packages. The supported target is native Apple Silicon macOS.
The installed product allowlist is:

- `bin/incinerator_headless`;
- `etc/incinerator/headless/config.example.json`;
- `share/incinerator/headless/content.json`.

The authority graph may contain Zig's standard library/runtime, engine
contracts and feature modules, the exact-pinned Flecs binding/C runtime, the
engine physics adapter, JoltC/Jolt, and macOS system libraries required by that
runtime. It must not resolve, import, link, or install SDL, SDL GPU, Metal
rendering code, renderer/editor modules, ImGui/zgui, zmath, zmesh, zstbi,
shader compilers, shader outputs, source art, or cooked visual bundles.

The installed content file is a small logical admission manifest, not visual
content. It binds the exact two-district semantic catalog, coordinates, recipe
versions, source bundle hashes, and combined content fingerprint needed by the
logical simulation. Visual fixtures and the separately licensed game content
remain outside this product.

### Exact startup admission

The versioned headless configuration is bounded to 64 KiB and rejects unknown
fields. It declares the world namespace and capacities, exact content cohort,
absolute save root and restricted slot identifier, startup policy, fixed-tick
clock policy, shutdown drain budget, and external-producer limits. M3 supports
`fresh`, `restore_required`, and `fresh_or_restore`; none imply schema
migration or hot replacement.

The logical content manifest is bounded to 16 KiB and must match the compiled
M3 catalog contract exactly. A content fingerprint in configuration must equal
the independently validated manifest fingerprint. The host fails before world
construction on a malformed, oversized, unknown, incompatible, or mismatched
startup input.

At M3 acceptance, the durable save was the S5 bounded envelope around
`SnapshotV7`. Its
simulation-build, world-configuration, content, payload-schema, size, and
integrity fields must match before snapshot preflight can construct the sole
world. Stale candidates are discarded explicitly; candidates are never
promoted to committed saves. Later greenfield slices intentionally supersede
that payload cohort; the current value is recorded in the living architecture
review rather than retroactively changing this M3 decision.

### Bounded producer and feature authority

Every externally reachable feature command reserves enough authority-output
capacity before it is accepted. If that reservation cannot be made, admission
returns a typed queue/backpressure result without partially committing a
command. Authority outcomes are not dropped. Observational events may use
bounded best-effort delivery only when loss is counted in diagnostics and
cannot alter logical state.

The fixed per-world feature budgets are:

| Feature | Commands | Authority outcomes | Observational events |
|---|---:|---:|---:|
| Crates | 128 | 128 | none |
| Character | 128 | 128 | 256, counted best-effort |
| Vehicle | 128 | 128 | 256, counted best-effort |
| District | 16 | 32 | 16, counted best-effort |
| Interaction | 16 | 16 | none |
| NPC | 128 | 128 | 256, counted by event class |

A district load reserves its immediate acknowledgement and eventual terminal
completion. Cancellation reserves its own acknowledgement while the original
load reservation becomes the terminal `cancelled` result; unload reserves one
result. The invariant is
`unread outcomes + retained reservations <= 32`.

M3 introduces one narrow composition-owned external router for crate
relocation. It has two generational producer slots, 16 ingress entries, 16
transaction entries, a quota of eight pending transactions per producer, and
eight result slots per producer. Registration, submission, retry,
terminal-rejection, shutdown, polling, and stale-handle outcomes are typed.
Accepted transactions reserve completion delivery before reaching the world.

The router is not a generic message bus. It recognizes only the transaction
shape proved by S5, maps exactly one final crate-relocation outcome back to the
registered producer, and hands unrelated, unknown, duplicate, or mismatched
outcomes back to the composition. A host must never blindly drain and discard
an outcome it does not own. A future producer or feature command requires an
explicit routing contract and its own measured capacity.

Duplicate detection covers live and unread transactions. Polling a terminal
result releases that identifier; M3 has no lossy transport and therefore no
retry tombstone. A networked S9 must define bounded idempotency before remote
retry is admitted.

### Fixed-tick operation and shutdown

Simulation remains 120 Hz. Real time is converted to a rational due-tick
count; authoritative ticks are never skipped. One sample grants at most eight
catch-up ticks. At eight ticks of lag the host closes new external admission,
retains already-accepted router ingress without pumping it, and grants only
authority catch-up ticks until lag recovers. At 120 ticks of lag it begins an
orderly stop, then drains retained accepted work under the shutdown budget,
rather than claiming that it can preserve real-time service. Virtual mode
executes an exact configured tick count through the same bounded grant loop and
is the canonical M3 soak mode.

`SIGINT` and `SIGTERM` install one macOS adapter whose handler performs only a
lock-free atomic store. Configuration, logging, allocation, filesystem I/O,
world access, producer draining, saving, and teardown remain on the owner
thread.

Orderly shutdown has one authority order:

1. stop admitting new external work;
2. drain already accepted ingress and world transactions within the declared
   tick budget;
3. deliver and consume every reserved producer result;
4. require quiescent feature/worker/output ownership;
5. serialize and durably commit only a healthy world;
6. deinitialize features, physics, and runtime in reverse ownership order.

If the runtime has an immutable first fault, a tick fails, accepted work cannot
be drained, serialization fails, or durable commit is not known to have
succeeded, the process exits nonzero and does not overwrite the previous
healthy committed slot. A post-rename directory-sync warning is reported as a
committed save with reduced durability evidence, never as a fictional rollback
to the old slot.

## Authority and Trust Inventory

### Authoritative state

The durable authority is the canonical simulation snapshot: completed tick,
fixed delta, namespace, persistent-identity cursor, feature tuning, and crate,
character, vehicle, district, interaction, and NPC logical records. The exact
world and content fingerprints determine whether those bytes may be admitted.

Flecs entity values, runtime tokens, Jolt body/controller/vehicle handles,
district load tickets, worker storage, presentation history, diagnostics UI,
external producer handles, transaction-table entries, and queue storage are
process-local. They are reconstructed, drained, or discarded only after their
declared lifecycle; none is a persistence identity.

| Input or component | Trust before validation | Authority after admission | Failure policy |
|---|---|---|---|
| Executable and compiled cohorts | Release/build input | Defines schemas, schedule, physics ABI, and compiled limits | Exact pins and cold-build/linkage gates; no mixed cohort |
| CLI paths and configuration bytes | Operator-controlled, structurally untrusted | Operational policy only after exact V1 validation | Reject before content, storage, Flecs, or Jolt |
| Logical content manifest | Deployment input, structurally untrusted | Binds the only admitted logical content cohort | Exact field/hash/fingerprint match or reject before world |
| Committed save bytes | Filesystem input, untrusted | Durable logical authority only after envelope, integrity, cohort, and snapshot preflight | Reject; never fall through from `restore_required` to fresh |
| Save candidate and path entries | Untrusted filesystem state | Never authoritative | Reject symlinks; remove a stale candidate; never promote it |
| External producer handle and relocation | Untrusted transient ingress | May become one feature command only after handle, transaction, quota, capacity, and command validation | Typed reject/retry with no partial commit |
| District worker completion | Internal asynchronous input, not authority by itself | May become district state only after ticket/generation/build validation on owner thread | Ignore or fault according to typed stale/invalid contract; never mutate from worker |
| Monotonic clock sample | OS operational input | Determines how much already-defined fixed-tick work is due, not gameplay data | Backwards/range error stops; soft lag sheds; hard lag stops |
| `SIGINT` / `SIGTERM` | OS control input | Requests orderly lifecycle transition only | Atomic flag; all consequential work remains on owner thread |
| Diagnostics and replay | Evidence derived from authority | Observational; replay is admitted only within its exact cohort | Bounded loss is visible; neither path mutates live authority |

### Dependency trust

| Dependency | M3 role and pin | Boundary or residual risk |
|---|---|---|
| Zig | Exact `0.16.0` toolchain and standard library | Compiler/runtime trust root; no “or later” compatibility promise |
| `zflecs` / Flecs | Exact package commit `9c2771cf0cae508db622821bb7deac6e9370a9de` | Mutable ECS backend behind `Runtime`; current wrapper enforces one live owned world |
| Jolt Physics | `5.5.0`, commit `23dadd0e603f1b321142d4c74df07fce85064989` | Native physics backend; reconstructed from logical records and not a byte-stable persistence or cross-platform lockstep contract |
| JoltC | Commit `52d8c98df523f449eb3e01b1060a0fde052970d1` through the engine-owned build package | C ABI is compile-time asserted and exposed only through the narrow physics adapter |
| macOS/Darwin runtime | Apple Silicon macOS system calls, threading, signals, and `F_FULLFSYNC` | Sole supported operational platform; final Mach-O linkage remains an acceptance artifact |
| SDL, zgui, zmath, zmesh, zstbi, shader and visual-content tools | No M3 authority role | Must remain unresolved/absent from the cold build, installed tree, imports, markers, and final linkage |

The repository is still intentionally unlicensed. Dependency license notices
and an engine license remain release obligations; M3 readiness does not grant
redistribution rights.

## Security and Fault Model

M3 is a local operational harness, not an Internet-facing security boundary.
It nevertheless treats serialized and producer inputs as hostile enough to
require bounded parsing, exact schemas, checked arithmetic, cohort admission,
generational handles, capacity reservation, path/slot restrictions, and
fail-closed world construction.

The configured save root is an operator-trusted absolute path. M3 does not
sandbox filesystem access or protect an operator from deliberately pointing
the process at sensitive data. The process has no privilege separation, secret
store, authentication, authorization, encryption, rate limiting by identity,
remote audit trail, anti-cheat, exploit containment, or denial-of-service
protection beyond its local fixed capacities and catch-up/load-shed policy.
Those are S9 or deployment decisions if a networked product is selected.

An infrastructure failure freezes the immutable first-fault record and makes
the live world ineligible for durable overwrite. Domain rejections and
capacity pressure remain healthy typed outcomes. Observational event loss is
not promoted into an authority fault, but its counters are part of acceptance
evidence. Cleanup failures that would lose the only native owner remain
terminal invariant violations.

## Consequences

- A future transport has a bounded authority ingress to adapt to, but no
  transport abstraction is created in advance.
- One-world restart semantics align with the current wrapper and durable-save
  design while making the limitation explicit.
- The cold product proves dependency separation more strongly than a headless
  runtime flag inside the client graph.
- Backpressure is a normal typed product behavior rather than an allocation or
  world fault.
- Accepted work must be drained before save, so shutdown latency is bounded by
  an explicit policy and may fail rather than silently lose a completion.
- Exact build/content cohorts and greenfield schemas deliberately reject stale
  deployments and saves; no migration promise is introduced.

## Explicit Nonclaims

This decision does not introduce sockets, protocol serialization, connection
state, authentication, authorization, replication, prediction,
reconciliation, interest management, client interpolation, join/reconnect,
distributed persistence, cloud saves, service discovery, orchestration,
metrics shipping, remote administration, anti-cheat, Linux server support,
Windows support, cross-platform determinism, multiple simultaneous worlds, or
MMO operations. S9 multiplayer and every secondary platform remain deferred
until explicitly selected after M3 is complete and reviewed.
