# S14 Ranged Combat Vertical Slice

**Status:** Accepted; implementation, automated/native evidence, mouse-capture
follow-up, and product-owner walkthrough complete

**Date:** 2026-08-18

**Decision:** [ADR-027](../adr/027-authoritative-ranged-combat.md)

**Prerequisites:** Accepted S10/S11 combat lifecycle, S12 navigation, S13
population, ED1 developer workspace, and DR1 deterministic visual fidelity

## Outcome

Deliver one playable authoritative hitscan handgun through solo, listen, and
dedicated placements. A player can equip or holster it, fire, exhaust a
magazine, automatically enter the ordinary timed reload while reserve remains,
manually tactical-reload from a partial magazine, damage and kill NPCs/players,
observe clear feedback, reconnect without weapon-state ambiguity, and retain
enough incident/replay evidence to explain every shot.

This is a product slice, not a firearms framework.

## Product contract

Default controls:

- `1`: equip or holster the handgun;
- left mouse: fire one semi-automatic shot;
- `R` while alive: manually reload a partial magazine; `R` while dead retains
  its existing respawn meaning;
- `Q`: existing melee, unchanged.

The final admitted shot atomically consumes its round and enters `reloading`
when reserve ammunition remains. It preserves the fired hit/miss result and
uses the same authoritative reload deadline as `R`; it does not create another
client action. With zero reserve, the weapon remains genuinely empty.

The first tuning contract is deliberately small and visible in the feature
configuration: 12-round magazine, 36-round reserve, 25 damage, 60-metre range,
12-tick fire cadence, and 90-tick reload. These are authored product values,
not engine limits.

## Ownership map

| Owner | Owns | Must not own |
|---|---|---|
| `ranged_combat` | handgun config; equip/reload/fire admission; ammo and deadlines | sessions, targets, Jolt, health, rendering |
| session authority | participant/incarnation checks; current pose; semantic candidates; occlusion; result/event publication | duplicated weapon rules, health mutation, presentation timers |
| vitals | firearm damage application and exactly-once death | ammo, target selection, cosmetics |
| NPC encounter/population | damage stimulus, reaction, death interruption, safe replacement | firearm validation |
| client/presentation | replicated weapon model, HUD, muzzle/tracer/impact/hit/death readability | ammo/damage truth |
| incident/replay | immutable action, decision, ray, outcome, and presentation evidence | gameplay decisions |

## Phase sequence

### S14-A — Contract and cohort

- Add the backend-neutral handgun state/rule contract with exhaustive unit
  tests for equip, holster, cadence, final-shot automatic reload, genuine
  reserve-zero empty state, tactical reload, cancellation, death reset, and
  invalid context.
- Add protocol actions, results, shot events, and replicated character weapon
  state; advance the protocol cohort without a fallback decoder.
- Add weapon ingress to replay identity and transport policy.

Exit: the contract compiles independently and every new wire value round-trips
with invalid values rejected.

### S14-B — Authority composition

- Compose one weapon state per participant.
- Advance reload deadlines inside authority ticks.
- Resolve current-state horizontal hitscan against live player/NPC semantic hit
  volumes, Jolt obstruction, nearest fraction, then stable identity.
- Route hits through `vitals.Cause.firearm`; resolve the exact pending action
  from the exact vitals outcome.
- Reset/holster at death, respawn, carry, and vehicle boundaries.

Exit: deterministic authority tests prove hit, miss, occlusion, cadence, ammo,
reload, death, replacement, and same-cycle interaction policy.

### S14-C — Client and playable presentation

- Add client sequencing, reconnect retirement, result/event queues, and
  snapshot-authoritative ammo state.
- Add the handgun silhouette to equipped characters.
- Add authority-tick muzzle, tracer, impact, hit, reload, cooldown, and ammo
  feedback to the ordinary product and network client.
- Preserve editor mouse capture, add click-to-capture continuous look in the
  central playable scene, and retain right-drag as the uncaptured fallback.

Exit: the normal product is understandable without reading logs.

### S14-D — Diagnostics and incident evidence

- Add typed gameplay trace records for weapon input, authority admission or
  rejection, ray result, damage, client application, and draw submission.
- Include weapon state and the latest shot in incident state/timeline records,
  with correlation by participant, avatar incarnation, and action sequence.
- Add a Combat Lab panel only if the existing Gameplay Inspector cannot display
  the required fields cleanly; do not create another overlay.

Exit: a fresh agent can answer who fired, from where, with what ammo state,
why it hit/missed/rejected, what damage applied, and what was drawn.

### S14-E — Acceptance and cleanup

- Focused contract/protocol/authority/presentation tests.
- Solo, listen, and dedicated semantic acceptance.
- Deterministic impairment, reconnect, replay, death/respawn, NPC replacement,
  and relevant scale coverage.
- Installed Metal journey: equip, hit, miss, automatic reload, kill,
  replacement, death/respawn, incident flag, and replay verification.
- Run editor-enabled and editor-disabled aggregate gates; delete transitional
  code and reconcile documents.

Exit: the slice is playable, observable, replayable, and accepted with no new
P0/P1 architecture finding.

Implementation, automated/native acceptance, and the ordinary-product
walkthrough meet this exit contract. The exact evidence and
acceptance-discovered repairs are recorded in the
[S14 validation ledger](../validation/s14-ranged-combat.md). S15 was promoted
after that checkpoint was accepted.

## Acceptance matrix

| Concern | Required evidence |
|---|---|
| Source of truth | Client cannot provide target/hit/damage/ammo; authority snapshot/result agrees |
| Determinism | Stable candidate ordering and exact current-state ray tests |
| Network | Protocol round trip, reliable result/event, listen/dedicated process |
| Faults | Transactional authority-cycle fault injection does not partially publish |
| Reconnect | Equipped/ammo/reload state returns from authoritative snapshot |
| Replay | Weapon ingress participates in accepted-ingress digest and verification |
| Gameplay | NPC damage reaction, hostility, death, and replacement reuse S11 owners |
| Presentation | Weapon, muzzle, tracer, impact, health/death, reload, and ammo are readable |
| Incident | Grep-friendly action/decision/ray/outcome/draw correlation |

## Stop conditions

Stop and revise the design if current-state targeting cannot be expressed
without a client-supplied victim, if Jolt query ownership leaks into the weapon
rules, if vitals must be bypassed, or if reliable shot publication cannot fit
the accepted participant delivery ledger. Do not solve those failures with a
generic framework.
