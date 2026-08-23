# S14 Ranged Combat Validation

**Status:** Accepted; implementation, automated/native evidence, continuous
mouse-look follow-up, and product-owner promotion are complete

**Started:** 2026-08-18

**Plan:** [S14 Ranged Combat Vertical Slice](../design/s14-ranged-combat.md)

## Phase ledger

| Phase | Status | Evidence |
|---|---|---|
| S14-A — contract and cohort | Accepted | `ranged_combat` owns the pure handgun rules; protocol 16 and replay 17 intentionally break the greenfield cohort; exhaustive rule and wire tests pass. |
| S14-B — authority composition | Accepted | Current-state semantic player/NPC hit volumes, Jolt obstruction, stable nearest-target ordering, vitals firearm damage, exact pending-shot correlation, ammo/deadline state, death/vehicle/carry cleanup, and reconnect are authority-tested. |
| S14-C — client and presentation | Accepted | Solo, listen, and dedicated clients own input sequencing and tick-ordered weapon projection; the ordinary Metal scene draws the handgun and authoritative tracer while HUD/editor surfaces show ammo, mode, cadence, reload, and result state. |
| S14-D — diagnostics and incident evidence | Accepted | Schema-5 timeline/input/state records expose `kind=firearm`, action sequence, identities/incarnations, ammo, deadlines, ray, impact, damage, death, weapon draw, and tracer draw. The canonical and installed incident-diagnostics skill explains correlation and reproduction. |
| S14-E — acceptance and cleanup | Accepted | Focused 167-test session/room gate, real-GNS listen/dedicated graphical journeys, two-rate installed Metal journey, inherited M6/MP6/S11/S13/incident/replay/package gates, clean source audit, native continuous mouse-look acceptance, and product-owner promotion pass. |

## Validation ledger

### Focused contracts and transactional authority

```sh
zig build test-session-contracts test-m6-transaction test-ranged-combat --summary all
```

Result: 56/56 steps and 163/163 tests passed before the final network-host
additions. The final focused session/room/process gate passed 102/102 steps and
167/167 tests:

```sh
zig build test-session-contracts test-m6-transaction test-mp6-hosts \
  verify-s14-listen verify-s14-dedicated --summary all
```

The authority proof covers equip, hit, rejected cadence without ammo loss,
final-shot automatic reload, no synthetic reload ingress, manual tactical
reload, reconnect during reload, completion, miss, four firearm hits, player
death cleanup, and exact accepted-ingress counts. The local-solo proof drains
the full magazine through the public player role and observes the same result
and forced completion snapshot. Protocol tests round-trip and reject malformed
weapon messages. Client/presentation regressions prove an old reliable action
result cannot mask a newer reload-completion snapshot.

### Graphical network placements

```sh
zig build verify-s14-listen verify-s14-dedicated -Deditor=true
```

Both two-window Metal journeys passed. Listen uses a typed host-local link plus
a real-GNS guest; dedicated uses two real-GNS graphical clients. The shooter
equips and fires four authoritative hits, both clients receive shot evidence,
the NPC dies, and both observe its generational replacement. The listen host
now exposes the same manual handgun controls and drains weapon/shot feedback
through its local client boundary.

### Installed Metal journey

```sh
zig build smoke-installed-s14-macos -Deditor=true
```

Both independent presentation schedules passed:

- 3,840 frames / 960 validation ticks at virtual 240 Hz;
- 1,280 frames / 960 validation ticks at virtual 80 Hz.

Each proves equip, twelve committed shots, cooldown rejection, final-shot
automatic reload start/completion, four NPC hits and death, visible death
presentation, safe population replacement, handgun draw, tracer draw, ammo
HUD, and clean shutdown on Metal. The driver submits no extra empty shot or
reload action during the depletion transition.

### 2026-08-22 automatic-reload follow-up

Editor Interaction Phase 2 moved empty-magazine convenience into the existing
authoritative ranged-combat rule. The final shot now retains its hit/miss
result while projecting `reloading`, zero magazine rounds, finite reserve, and
the normal deadline. The focused solo/listen/dedicated gate passed `107/107`
steps and `174/174` tests; the two-rate installed Metal journey passed `84/84`
steps with `auto_reload=true/true`; and repository aggregates passed
`305/305` editor-enabled and `302/302` editor-disabled steps with `1026/1026`
tests in each configuration. Full evidence and the pending human walkthrough
are in the [Phase 2 validation record](editor-interaction-phase-2-authoritative-automatic-reload.md).

### Complete aggregate

```sh
zig build verify-s14 -Deditor=true --summary all
```

Result: 283/283 steps and 354/354 tests passed. This includes the S13/S11
gameplay lineage, M6 transaction and MP6 lifecycle/fault coverage,
accepted-ingress replay, headless/package boundaries, five installed
incident-hardening profiles, graphical listen/dedicated S14 journeys, and the
two-rate S14 Metal smoke.

The ordinary repository aggregates also pass with the editor both present and
compiled out:

```sh
zig build test -Deditor=true --summary all
zig build test -Deditor=false --summary all
```

Current results after the continuous-look follow-up: editor-enabled 292/292
steps and 1,003/1,003 tests; editor-disabled 289/289 steps and 1,003/1,003
tests.

### Continuous mouse-look follow-up

```sh
zig build test-mouse-capture-macos --summary all
```

Result: 7/7 native SDL steps passed. The proof uses a real macOS window and
verifies that the first unconsumed scene click enters per-window relative mode
without firing, a subsequent captured click reaches gameplay, Escape releases
capture without quitting, and Escape while free retains the quit contract.

## Defects found by acceptance

1. The initial graphical driver counted only misses while draining the
   magazine. A moving NPC crossing the ray could consume valid ammo without
   advancing the driver. It now counts committed hit or miss outcomes and
   selects a deterministic ray clear of living NPCs for the depletion phase.
2. Reload completed in authority but the client never refreshed weapon fields
   from snapshots, while `combat_presentation` permanently overrode newer
   state with the earlier `reload_started` result. Weapon results now carry an
   authority tick, client result/snapshot state is ordered by that tick, and
   latest results are feedback rather than a second state owner.
3. The MP4 accepted-ingress replay tool had no exhaustive mapping for the new
   weapon kinds. Equip, fire, and reload now replay through the same current
   protocol path; the complete MP4 impairment suite passes.
4. The private-listen local client adapter did not drain weapon results or shot
   events and offered no manual handgun controls. It now has parity with the
   remote graphical client, and the S14 listen observer proves receipt.

No compatibility decoder or legacy weapon path was retained.

## Product-owner walkthrough

Run:

```sh
zig build run -Deditor=true
```

Then verify:

1. Press `1`; the handgun silhouette appears and the Gameplay Inspector shows
   `equipped`, `12/36`.
2. Click the playable scene to capture continuous mouse-look, aim without
   holding a button, then left-click an NPC four times with the cadence. Confirm
   the captured-state hint says `ESC releases`; tracer, hit feedback, health
   loss, red death presentation, and replacement should remain readable.
3. Fire away from actors, confirm misses still consume ammunition, and exhaust
   the magazine. Confirm the final shot is visible, the HUD immediately enters
   the timed reload without pressing `R`, and the countdown ends at `12/24`.
   Fire once during the reload and confirm it is rejected as `reloading`.
4. Fire one or more rounds, press `R`, and confirm manual tactical reload still
   fills the partial magazine from finite reserve.
5. Enter a vehicle or collect the carryable and confirm the handgun holsters;
   exit/drop, re-equip, and fire again.
6. Allow player death and press `R` after the respawn countdown; the new avatar
   starts holstered with the authored loadout.
7. Open Gameplay Inspector and Incident Capture, flag any anomaly, and confirm
   the bundle contains `kind=firearm` records plus weapon/ray/draw evidence.

The product owner promoted the roadmap to S15 on 2026-08-18 after the
continuous mouse-look corrective follow-up. S14 is closed.
