# Editor Interaction Phase 2: Authoritative Automatic Reload Validation

**Status:** Accepted by the product owner on 2026-08-22 after implementation,
automated validation, native Metal validation, architecture/dead-code/
documentation review, and gameplay review

**Date:** 2026-08-22

**Plan:**
[Editor Interaction and Agent Control Plan](../../EDITOR_INTERACTION_AND_AGENT_CONTROL_PLAN.md)

## Outcome

The handgun no longer remains equipped and idle with an empty magazine while
reserve ammunition is available. The final admitted shot now atomically:

1. consumes the final magazine round;
2. remains a normal admitted hit or miss;
3. enters the existing authoritative `reloading` mode when reserve is nonzero;
4. publishes zero magazine rounds, the unchanged reserve, and the ordinary
   reload-completion tick; and
5. completes through the existing authority tick path, transferring
   `min(magazine capacity, reserve)` rounds.

No client, UI, CLI, bot, or presentation layer submits an automatic reload
action as a consequence of depletion. `R` remains the manual tactical-reload
control for a partially filled magazine. When reserve is zero, the handgun can
still become genuinely empty at `0/0`.

## Implementation evidence

- `src/features/ranged_combat/root.zig` owns the transition. The final round
  starts the same timed state used by manual reload without changing the
  admitted-shot disposition.
- `src/session/authority.zig` continues to resolve and publish the final shot.
  Its result now naturally carries `mode=reloading`, `magazine_ammo=0`, the
  reserve count, and the reload deadline from the shared decision.
- `src/session/local_solo.zig` proves the public solo player role observes the
  same final-shot result and the forced reload-completion snapshot.
- `src/main.zig` now validates automatic reload directly. The S14 driver no
  longer forces an extra empty shot or presses reload, and it does not submit
  fire requests while the weapon is reloading.
- `src/hosts/mp2_client.zig` no longer contains the old scripted
  zero-magazine-to-reload fallback.
- Product, editor, listen, and network-client control guides now describe `R`
  as tactical reload.

The existing protocol already carries every required mode, ammo, deadline,
result, snapshot, trace, diagnostic, and incident field. No protocol version,
generic property system, compatibility path, or new state owner was required.

## Rule coverage

The deterministic feature tests prove:

- the final round with reserve remains `shot_admitted` and starts reload;
- fire during that reload returns `reloading` without another shot;
- completion occurs at the exact authored deadline;
- completion transfers only the available/capacity-bounded ammunition;
- the final round without reserve remains equipped at `0/0` and later returns
  `empty`/`no_reserve`;
- manual tactical reload of a partial magazine still works; and
- existing reload cancellation, reset, and invalid-context tests remain green.

The network-authority test additionally proves the final hit and shot event are
published, the result projects the automatic reload, completion reaches
`12/24`, and accepted ingress contains one equip, one fire, and **zero** reload
actions.

## Automated and native evidence

Focused contracts, authority, local-solo, listen, and dedicated placements:

```sh
zig build test-session-contracts test-m6-transaction test-ranged-combat \
  verify-s14-listen verify-s14-dedicated -Deditor=true --summary all
```

Result: `107/107` steps and `174/174` tests passed. The native process proofs
reported:

```text
S14_LISTEN_PROCESS_PASS graphical=2 host_local_link=true guest_real_gns=true authority_hitscan=true observer_shot=true npc_death=true replacement=true
S14_DEDICATED_PROCESS_PASS graphical=2 real_gns=true authority_hitscan=true observer_shot=true npc_death=true replacement=true
```

Installed native Metal journey:

```sh
zig build smoke-installed-s14-macos -Deditor=true --summary all
```

Result: `84/84` steps passed. Both independent schedules proved the new
sequence and shut down cleanly:

- 3,840 frames / 960 ticks at virtual 240 Hz;
- 1,280 frames / 960 ticks at virtual 80 Hz;
- the final depletion shot reported `ammo=0/36` with a nonzero reload deadline;
- completion projected `12/24`; and
- both summaries reported `auto_reload=true/true` with `gpu_driver=metal`.

Complete repository aggregates:

```sh
zig build test -Deditor=true -j1 --summary all
zig build test -Deditor=false -j1 --summary all
```

Results:

- editor enabled: `305/305` steps and `1026/1026` tests passed;
- editor disabled: `302/302` steps and `1026/1026` tests passed.

Both installed-product checks reported the canonical cooked catalog, MSL
shaders, the Metal driver, and the expected editor boundary. `zig fmt --check`
and `git diff --check` also pass for the changed source and documentation.

## Architecture, dead-code, and documentation review

- The deterministic ranged-combat feature remains the only reload rule owner.
- Session authority still owns action admission, shot resolution, and
  publication; it does not duplicate the new transition.
- Client/presentation state remains a tick-ordered projection.
- The admitted final shot is not replaced with `reload_started`; its hit/miss
  evidence remains intact.
- The `empty` and `no_reserve` dispositions remain live for real reserve-zero
  behavior.
- The obsolete S14 empty-shot/manual-reload sequence and MP2 scripted reload
  fallback were removed rather than retained as compatibility behavior.
- Current S14 design, validation, README, startup controls, and Gameplay
  Inspector guidance describe automatic versus tactical reload consistently.

## Accepted product-owner gameplay review

Run:

```sh
zig build run -Deditor=true
```

Then test the normal product:

1. Press `1` to equip. Confirm Gameplay Inspector shows `equipped 12/36`.
2. Aim away from actors and fire with the normal cadence until the magazine
   reaches zero.
3. On shot 12, confirm the shot/tracer still occurs and its result remains
   `fired_miss` (or `fired_hit` if an actor crossed the ray). At the same time,
   confirm the weapon mode becomes `reloading`, ammo reads `0/36`, and a reload
   countdown appears without pressing `R`.
4. Left-click once during the countdown. Confirm no tracer, damage, or ammo
   change occurs and the feedback says `reloading`.
5. Let the countdown finish. Confirm mode returns to `equipped` and ammo becomes
   `12/24`.
6. Fire one round, press `R`, and confirm tactical reload still starts from
   `11/24` and completes at `12/23`.
7. Start another reload and press `1` to holster. Confirm holstering cancels the
   reload rather than refilling the magazine.
8. Optionally exhaust all 48 authored rounds. The first three depleted
   magazines should automatically reload; after the last reserve round has
   already been transferred, the final magazine should end at `0/0`, remain
   equipped, and later fire attempts should report `empty` without another
   reload.

Also confirm the top/product guidance identifies `R` as tactical reload and
that automatic reload did not add any CLI workflow or new editor panel.

The product owner reported that this workflow works and authorized Phase 3 on
2026-08-22. Phase 2 is closed.
