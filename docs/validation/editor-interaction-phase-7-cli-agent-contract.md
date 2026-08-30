# Editor Interaction Phase 7 — First-Class CLI Agent Contract Validation

**Status:** Implementation, automated, installed Metal, clean-context agent,
and comprehensive manual agent review candidate complete; product-owner stop
review pending

**Date:** 2026-08-30

**Plan:**
[Editor Interaction and Agent Control Plan](../../EDITOR_INTERACTION_AND_AGENT_CONTROL_PLAN.md)

**Prerequisite:**
[EA0.5 accepted](ea0-5-local-developer-endpoint-and-canonical-cli.md)

## Decision Boundary

The product owner eliminated the planned MCP adapter on 2026-08-30. Local
coding agents are guaranteed shell access, and the accepted typed client plus
canonical JSON CLI already provide every required engine capability. Phase 7
therefore makes `incinerator-dev` and its repository-owned skill first-class.

This phase adds no endpoint command, endpoint wire field, schema-digest change,
remote transport, shell evaluator, generic command/property system, or second
mutation authority. The endpoint protocol remains cohort 1. The separate agent
catalog revision describes client usability metadata and does not manufacture
wire incompatibility.

## Acceptance Ledger

| Gate | Status | Evidence |
|---|---|---|
| Product decision | Complete | MCP is eliminated rather than deferred; the CLI is the sole agent-control product for shell-capable local coding agents |
| Agent bootstrap | Complete | `agent bootstrap` validates the current discovery document and publishes lifecycle, run identity, protocol cohort, schema identities/digest, agent-contract revision/catalog digest, and safe next operation IDs |
| Operation catalog | Complete | `agent catalog` works without a live endpoint and describes 22 fixed operations: three local agent/discovery entrypoints and all 19 typed endpoint commands |
| Descriptor quality | Complete | Every operation records stable ID, command tokens, summary, schema, effect, completion, availability, parameters/types/units/sources, preconditions, poll path, terminal follow-up, typed rejections, and a valid example |
| Result guidance | Complete | Every endpoint response is wrapped with agent-contract revision, operation ID, explicit `terminal`, structured `next`, and the complete typed endpoint response; no shell string is manufactured |
| Shell status | Complete | Successful and pending operations exit zero; typed endpoint failures, rejected terminal transactions, failed results, and missing correlated results preserve their JSON response and exit nonzero |
| Dynamic authority meaning | Complete | Catalog and skill distinguish the transaction pose applied at its authority tick from the crate physics body's later simulated pose; committed revision remains the correlation proof |
| Save evidence | Complete | A committed save reports canonical snapshot payload bytes; the fixed slot truthfully reports null generation rather than inventing one |
| Skill | Complete | `skills/incinerator-developer-cli/SKILL.md` owns discovery, effect, result, authorization, and handoff judgment; authoring and persistence/evidence details use progressive references; it copies no command catalog |
| Project routing | Complete | `AGENTS.md` requires the skill before CLI/schema/agent workflow changes or use and explicitly forbids MCP and another mutation path |
| Ownership | Complete | The new concrete descriptor module is explicitly classified as game tooling; the EA0 executable verifier rejects unclassified imports and passes after that classification |
| Editor-disabled boundary | Complete | The CLI remains installed only for editor-enabled products; editor-disabled and headless runtime graphs acquire no endpoint, catalog, skill, or mutable-authoring dependency |
| Automated | Complete | Focused CLI contract/grammar, complete endpoint group, EA0 ownership, editor-on, editor-off, and documentation checks pass as recorded below |
| Installed Metal and agent journey | Complete | Two live installed editor runs exercised all 22 operations, typed failures, selection and camera projection, revisioned move/stale/undo/redo/restoration, pending and terminal frame evidence, durable save, clean shutdown, and stopped discovery |
| Product-owner stop review | Pending | Confirm the catalog and guided JSON make the intended agent workflow understandable; no graphical interaction change requires a new usability walkthrough |

## Implemented Contract

`src/hosts/sandbox_developer_cli_contract.zig` is a read-only, manually
registered descriptor catalog. It imports only the concrete sandbox protocol.
Its exhaustive command switch makes a new protocol command a compile-time
maintenance obligation rather than an undocumented CLI capability.

The installed client exposes:

```sh
./zig-out/bin/incinerator-dev agent bootstrap
./zig-out/bin/incinerator-dev agent catalog
```

The catalog is authoritative for exact commands. The repository skill remains
small and teaches non-obvious rules:

- bind every operation to the current run;
- discover rather than guess identities;
- distinguish world instances from durable assets;
- inspect before a revisioned mutation;
- distinguish admission from terminal completion;
- poll and re-inspect through structured next operations;
- keep editor presentation, session authority, durable persistence, and
  evidence capture distinct; and
- stop on typed failure rather than guessing another command.

Every non-help CLI operation emits JSON; help remains human-readable text.
`--json` is an optional, catalogued explicit flag. The CLI returns a nonzero
shell status after printing a typed failed or rejected result so shell
automation cannot silently continue through failure.

## Automated Results

All commands ran from the repository root on 2026-08-30:

```sh
zig build test-developer-cli-contract test-incinerator-dev -Deditor=true --summary all
```

Result: 6/6 build steps and 9/9 tests pass.

```sh
zig build test-developer-endpoint -Deditor=true --summary all
```

Result: 67/67 build steps and 40/40 tests pass. The focused persistence owner
also passes 6/6 tests.

```sh
zig build verify-ea0-ownership -Deditor=true --summary all
```

Result: 3/3 build steps pass with
`EA0_OWNERSHIP_PASS owners=4 manifest=explicit tooling=backend_neutral runtime_content=cooked_only`.

```sh
zig build test -Deditor=true --summary all
```

Result: 318/318 build steps and 1,247/1,247 tests pass.

```sh
zig build test -Deditor=false --summary all
```

Result: 313/313 build steps and 1,107/1,109 tests pass with the same two
designed editor-disabled skips.

The Skill passed the system `quick_validate.py` validator using a temporary
PyYAML dependency because neither the system nor bundled Python includes that
validator dependency.

## Installed Metal and Clean-Context Agent Journey

The editor-enabled installed product ran with save root
`/tmp/incinerator-phase7-saves` and incident run:

```text
/Users/matt/Library/Logs/Incinerator/runs/2026-08-30T17-54-49.445Z_solo_85f1776f
```

Observed evidence:

1. Bootstrap reported `available`, protocol cohort 1, a concrete run identity,
   and four safe next operations.
2. Offline catalog JSON parsed and contained 22 unique operations from
   `agent.bootstrap` through `frame.inspect`.
3. `world.list` returned the same run identity and discovered the crate as
   `persistent-entity:1:1`, revision 0.
4. `crate.set-position` emitted `terminal: false` and structured
   `transaction.inspect` for transaction 1.
5. Transaction 1 reached `accepted`; structured guidance required
   `target.inspect`, which reported revision 1 and the live physics position.
6. Frame capture 1 initially reported `pending` and continued to recommend only
   `frame.inspect`; it terminated as `captured` at authority tick 2652 and
   presentation frame 4407 under `anomalies/anomaly-0001`.
7. Undo admitted transaction 2, reached `accepted`, and reinspection reported
   revision 2 at the restored original position.
8. Save request 1 reached `committed` for slot `sandbox` in the temporary save
   root. This proves the write, not ordinary graphical cold restore.
9. The Metal product shut down cleanly after 5,626 frames and 3,400 simulation
   ticks.
10. Bootstrap after shutdown reported `stopped` and suggested only offline
    catalog and discovery inspection, never live owner operations.

## Comprehensive Manual Review and Repairs

The full installed surface was manually reviewed again on 2026-08-30 in this
native Metal run:

```text
/Users/matt/Library/Logs/Incinerator/runs/2026-08-30T18-22-12.740Z_solo_6e807804
```

This review exercised all 22 catalogued operations rather than only the happy
path:

1. Help, live bootstrap, offline catalog, discovery, endpoint description, all
   five schemas, world listing, the truthfully empty pre-EA1 content listing,
   crate inspection, and gameplay-entity inspection returned one run identity.
2. Selection set/clear was confirmed by crate reinspection. Free Camera mode,
   exact pose, focus, inspection, and return to Character mode all projected
   synchronously.
3. Correlated capture 1 visually showed the selected crate, auto-opened
   Inspector, selection bounds, and translate gizmo. Capture 2 showed the
   restored crate after authoring. Capture 3 showed that Character mode retains
   semantic selection while hiding both bounds and gizmo.
4. A relocation committed revision 1. A deliberately stale transaction was
   retained as `rejected/stale_revision`. Undo committed revision 2, redo
   revision 3, and the final undo revision 4 at the original position.
5. Save request 1 committed `sandbox.isav` in the isolated temporary save root.
   Missing transaction/save/capture IDs and a camera-pose request in Character
   mode all returned their expected typed failures.
6. The engine shut down cleanly after 30,356 presentation frames and 18,265
   simulation ticks. Bootstrap then reported `stopped`, and a live world query
   failed rather than attaching to stale state.

The manual review found and repaired four agent-usability problems:

- The skill incorrectly required a later dynamic-body inspection position to
  equal the transaction's committed pose. It now requires revision agreement
  and explains physical evolution after the authority tick.
- Typed endpoint and terminal failures printed valid JSON but exited zero. They
  now print the same JSON and exit 1; successful and pending operations remain
  exit 0.
- `--json` was accepted by the parser and shown ambiguously in help but omitted
  from the machine catalog. Help and catalog now agree that every non-help
  operation emits JSON, human help remains text, and the flag is optional.
- Committed save results left `payload_bytes` null. The persistence owner now
  forwards the canonical snapshot size already known during commit, without
  exposing envelope bytes or adding another persistence path.

The repaired installed product was then rechecked in:

```text
/Users/matt/Library/Logs/Incinerator/runs/2026-08-30T18-31-19.472Z_solo_f784d4e9
```

Final observed evidence:

- catalog digest
  `9093e2ae2ceb4041ac7e7ec6f773b8ae773050efd44464e11fbc262b1b23e087`
  describes 22 operations and both global options;
- Character-mode exact-pose failure exits 1 with
  `owner_unavailable` JSON;
- terminal stale-revision inspection exits 1 with the complete rejected
  transaction and structured `target.inspect` follow-up;
- the accepted move exits 0, final undo exits 0, and reinspection reports
  restored revision 2 and the original physical position;
- save request 1 commits with `payload_bytes: 21059`, `generation: null`, and a
  21,251-byte owner-internal envelope file; and
- a missing frame result exits 1 while an admitted/captured frame exits 0 and
  retains its correlated artifact; and
- an explicit absolute discovery document reports the stopped run, while a
  relative discovery path exits 1 with `DiscoveryPathNotAbsolute` JSON.

## Product-Owner Checkpoint

No viewport or gameplay behavior changed. The remaining review is the installed
agent experience:

1. Build editor-enabled and run the product with an absolute temporary save
   root.
2. Run `incinerator-dev agent bootstrap`. Confirm the output makes the current
   run and safe starting operations obvious.
3. Run `incinerator-dev agent catalog`. Inspect a read-only operation, a camera
   operation, `crate.set-position`, `world.save`, and `frame.capture`. Confirm
   their effects and synchronous/admitted completion differences are clear.
4. Move the crate using a revision obtained from inspection. Confirm the first
   response says `terminal: false`, names only `transaction.inspect`, and the
   terminal transaction names `target.inspect`.
5. Confirm the repository skill would prevent guessing a target/revision,
   treating admission as completion, confusing the crate with an asset, or
   claiming that a committed save was cold-restored.
6. Stop the product and rerun bootstrap. Confirm `stopped` exposes no live
   mutation suggestion.

Product-owner confirmation closes Phase 7 and promotes Phase 8 / EA1-A.
