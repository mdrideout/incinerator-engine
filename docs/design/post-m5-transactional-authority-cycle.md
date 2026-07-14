# M6 Transactional Authority Cycle

**Status:** Implemented, independently reviewed, and accepted

**Date:** 2026-07-14

**Prerequisite:** M5 client/authority cohesion

**Current platform scope:** Apple Silicon macOS only; Linux/SteamOS and Windows
remain deferred product ports and add no requirements to this design.

**Accepted prerequisite cohesion work:**
[`M5 Client/Authority Cohesion`](m5-client-authority-cohesion.md)

**Acceptance record:**
[`M6 Transactional Authority Cycle Acceptance`](../validation/m6-transactional-authority-cycle.md)

## Why This Is Separate From M5

M5 makes embedded solo a real placement of the shared client and
authority, removes ordinary local gameplay bypasses, gives graphical support
concerns explicit owners, and makes the existing mutation cycle
completion-aware and fault-latched. Those properties are accepted prerequisites
for this follow-up.

An independent M5 review found a deeper server-runtime pressure point. The
current authority accepts and admits ingress immediately, submits some semantic
work during admission, builds replication while mutating replication cursors,
and publishes messages to the live outbox from several code paths. Durable
capture is correctly owned outside the graphical application, but is requested
outside the authority tick. Treating all of that as one already-transactional
eight-stage tick would be inaccurate.

Forcing storage I/O, physical network delivery, and client acknowledgement into
the fixed simulation tick would also be the wrong abstraction. This follow-up
therefore defines one transactional authority cycle and keeps adapter delivery
and durable storage commit as adjacent owner state machines.

## Accepted Meaning Of Transactional

M6 is a fail-stop atomic-publication transaction, not rollback of an already
stepped Flecs/Jolt world.

- Expected rejection, deferral, quota exhaustion, and capacity failure are
  values. They are detected before authoritative mutation and consume no
  participant slot, ticket nonce, sequence, replication cursor, or durable
  request.
- Once authoritative simulation begins, an unexpected invariant, simulation,
  outcome, extraction, or publication failure latches the first authority
  fault. The cycle publishes nothing, queues no durable capture, and cannot
  advance another tick.
- M6 does not claim to restore arbitrary Jolt solver/contact/constraint state
  to its pre-tick value. That would require a separately designed rollback
  simulation architecture.
- Flecs staging remains the safe mechanism for deferred structural mutation;
  it is not used or described as an authority rollback transaction.

This is the strongest honest guarantee available without introducing a second
world, a full-world snapshot per tick, or rollback-capable physics.

## Accepted M5 Baseline

- The authority clock is fixed at 60 Hz and rejects another simulation delta.
- Embedded and dedicated placements share one private `AuthorityCore`.
- Runtime command, pre-physics, physics, and post-physics phase order is
  executable and observed.
- The authority mutation portion records completion-aware pre-simulation,
  simulation, outcome-drain, and replication-extraction stages.
- The first authority-cycle failure is immutable and prevents another tick.
- Local composition separately records ingress delivery, authority execution,
  authority egress, client application, and acknowledgement ingress.
- Future inputs use a bounded per-target queue; replication acknowledges only
  successfully applied input sequences.
- Action sequence zero is reserved end to end. On transient loss the client
  retains one ambiguous vehicle and interaction correlation, consumes matching
  late results diagnostically, and drops provably older duplicates without
  disturbing a newer pending action. This prevents a reconnect race from
  terminating the client but does not claim delivery-confirmed result replay.
- Persistence capture requires a healthy, quiescent authority and the durable
  owner alone performs envelope construction and atomic slot commit.

These are accepted safety properties and form the prerequisite baseline. They
are not a substitute for transactional ingress and egress publication.

## Target Ownership

```text
Link / socket adapters
        |
        v
bounded authority ingress mailbox
        |
        v
transactional authority cycle
  ingress batch -> admission -> semantic work -> simulation
  -> outcome drain -> immutable extraction -> durable decision
  -> atomic outbox publication
        |
        v
delivery lease -> local link / GNS adapter

durable capture result -> persistence owner -> atomic storage commit
```

The authority owns semantic mutation and derivative output publication. A link
or socket adapter owns physical delivery. The persistence owner owns blocking
storage. None may retain a mutable pointer into another owner's state.

The implementation uses cohesive private owners inside the current authority
rather than creating another public framework:

- `IngressMailbox` owns copied ingress, arrival ordinals, class reservation,
  and stable-prefix freezing.
- `CycleScratch` owns reusable bounded admission plans, semantic work,
  outcomes, derivatives, and metadata patches for one cycle.
- Prepared publication storage is immutable after preflight and commits as one
  bounded pointer swap with its participant and replication metadata.
- The private live outbox, lease generation, and per-participant replay records
  own published delivery state and application receipts across reconnect.
- `DurableRequestQueue` owns one typed request and returns a value disposition;
  the persistence owner alone performs encoding and blocking storage.

These owners remain behind the existing private authority capability. They are
not a generic event bus, service locator, RPC system, or second simulation.

## Required Cycle Contract

One cycle operates on bounded copied data in this order:

1. Freeze one ingress batch from the mailbox.
2. Admit or reject every envelope without submitting feature work.
3. Translate the admitted batch into bounded semantic authority work.
4. Run the fixed simulation phases.
5. Drain typed outcomes/events and update session ownership.
6. Prepare immutable replication, replay, and diagnostic derivatives without
   publishing them.
7. Evaluate an optional typed durable-capture request at the healthy safe
   point; return a value disposition rather than performing storage I/O.
8. Preflight capacity and atomically publish the prepared output batch.

Expected rejection and durable deferral are values, not authority faults.
Unexpected invariant, capacity-accounting, simulation, outcome, extraction, or
publication failure latches the first authority fault. A later call cannot
advance the simulation until an explicitly designed recovery protocol exists.

## Mailbox and Input Rules

- Connection lifecycle, decoded client messages, malformed/oversized notices,
  and timestamped room admission enter a fixed-capacity mailbox.
- One cycle drains a stable prefix. Messages arriving during a cycle wait for
  the next one.
- Admission and semantic-work batches are capacity-reserved before mutation.
- Fresh admission commits participant allocation, nonce consumption, credential
  issuance, and required semantic work together. A later capacity or feature
  failure may reject the attempt, but may not consume the ticket or leave a
  partially admitted participant.
- Input sequences and target ticks remain distinct. One latest sample per
  target tick is retained; already applied held control is not replaced by a
  later future sample.
- Snapshot acknowledgement advances only after the corresponding input affects
  a completed authoritative tick.
- Control/lifecycle, reliable gameplay, lossy input, and malformed/oversized
  notices receive explicit bounded reservation or deterministic fair service.
  A saturated input producer may not starve handshake, acknowledgement,
  disconnect, or reliable gameplay traffic.
- Every accepted envelope receives a monotonic arrival ordinal. Separate
  internal class queues may be drained deterministically without losing the
  original accepted-ingress evidence order.
- Keep the current single authority owner. Do not add a lock-free mailbox or
  parallel simulation until a second measured producer thread requires it.

## Output and Delivery Rules

- Rejections, reliable action results, observations, baselines, and snapshots
  are prepared in cycle-owned storage.
- Replication histories and cursors commit with the output batch, never before
  it.
- Stage 8 either publishes the complete prepared batch or publishes nothing.
- Adapters read through an outbound delivery lease. Successful delivery commits
  the lease. A failed reliable send leaves it retryable; an unreliable failure
  follows an explicit measured drop policy.
- A rotated reconnect credential commits with confirmed `Welcome` delivery.
  Losing the queued response may not invalidate the only credential known by
  the client. M5's bounded single-previous-token overlap is a recovery guard,
  not a substitute for this delivery-owned commit point.
- Reliable action results retain a bounded replay/disposition record until the
  delivery owner confirms them or an explicit supersession policy retires them.
  M5's one retired client correlation prevents stale-result crashes but cannot
  prove that a result queued or produced during transport loss was delivered.
- Physical GNS encoding/send and local client application are outside the
  authority mutation cycle.

Reliable delivery has three distinct commit points:

1. the authority publishes the semantic message;
2. the local/GNS adapter accepts the leased bytes or typed value; and
3. the client applies the semantic message and acknowledges its delivery ID.

GameNetworkingSockets transport acceptance is not proof that the client
application observed the result. Control and gameplay are separate reliable
lanes, so each receives its own monotonically increasing delivery ID and
cumulative applied acknowledgement. Reliable ordering is assumed only within
one lane. Cross-lane dependencies are explicit: a reconnecting client applies
`Welcome` and synchronization control before replayed gameplay results.

The client deduplicates replayed delivery IDs. A compact bounded server record
is retained until application acknowledgement or an explicit typed
supersession policy retires it. Unreliable snapshots continue to use their
existing baseline/snapshot acknowledgement rules rather than this ledger.

## Durable Rules

- A privileged producer queues one typed capture request; it never receives
  `Simulation`, canonical mutable state, or `SaveSlots`.
- Stage 7 returns `not_requested`, a typed deferral, a captured immutable
  payload, or a typed operation failure.
- The persistence owner performs envelope encoding and blocking atomic commit
  after the cycle.
- Any failure preserves the previously committed slot.

## Implementation Sequence

1. [x] Add the class-reserved mailbox and migrate local/GNS lifecycle plus decoded
   ingress while retaining accepted-ingress ordinals.
2. [x] Split admission decisions from semantic-work application with reusable
   bounded scratch batches and preflight every expected capacity failure.
3. [x] Stage immutable derivative outputs and replication metadata patches; make
   publication an infallible operation after successful preflight.
4. [x] Replace pop-before-send APIs with generational outbound delivery leases.
5. [x] Add per-reliable-lane application delivery IDs, cumulative receipts,
   deduplication, reconnect replay, and welcome/token confirmation.
6. [x] Queue durable capture requests and return typed stage-seven dispositions.
7. [x] Expand the authority trace and fault probes across all eight stages.
8. [x] Run the full M5/M4/macOS regression before accepting M6.

Each step must preserve bounds and may not introduce an unbounded event bus,
generic RPC framework, service locator, second authority world, or storage I/O
inside the fixed tick.

## Acceptance

- Exact successful stage order, including nested runtime phases.
- Test-only failure before every stage proves the completed prefix, failed
  stage, absent suffix, immutable first fault, and refusal to advance again.
- Real simulation failure and post-simulation outcome failure are both covered.
- Future input sequencing, same-target coalescing, held-control continuity, and
  jump-edge single application are covered.
- Extraction/outbox saturation cannot partially publish state or advance a
  replication cursor.
- Reliable adapter failure leaves the message recoverable.
- Gameplay/input saturation cannot starve control traffic.
- Adapter acceptance followed by transport loss before application receipt
  replays the reliable message after reconnect; duplicate replay is
  idempotent.
- Repeated transport loss before `Welcome` confirmation neither strands the
  participant nor permits an unbounded reconnect-token history; confirmed
  delivery retires the prior credential.
- Admission failure at credential issuance, semantic-work reservation, or
  publication leaves both participant capacity and ticket nonce unchanged.
- Durable `not_requested`, deferral, capture, encode failure, and storage
  failure preserve their ownership and prior-commit invariants.
- Existing embedded, dedicated two-client, replay, save/restore, cold authority,
  and installed Metal scenarios remain green.

The final-tree commands, results, limitation audit, and independent closeout are
recorded in the linked M6 acceptance document.

## Reference Influences

- [Flecs systems and staging](https://www.flecs.dev/flecs/md_docs_2Systems.html)
  documents deferred structural mutation and merge behavior; M6 deliberately
  adds an engine-owned authority publication contract around it rather than
  treating deferral as rollback.
- [GameNetworkingSockets send, receive, and lane contracts](https://github.com/ValveSoftware/GameNetworkingSockets/blob/master/include/steam/isteamnetworkingsockets.h)
  distinguish queued transport work from application observation and guarantee
  reliable ordering only within one lane.
