# Deterministic Rendering Resumption Audit

**Status:** Complete; engine audit, automated evidence, and the S12/S13
product-owner checkpoint are accepted. DR1 implementation and agent-native
acceptance are complete and tracked separately; its product-owner visual
walkthrough remains.

**Recorded:** 2026-08-17

**Active plan:**
[DR1 playable deterministic visual fidelity](../design/dr1-playable-deterministic-visual-fidelity.md)

**Paused adjacent track:**
[Neural Rendering Product-Track Pause](../design/neural-rendering-pause.md)

## Purpose

This audit reconciles the completed RF10 neural-rendering proof with the active
conventional product after neural work was paused. It answers four questions:

1. Is the ordinary game still authoritative and playable without a learned
   model or experiment folder?
2. Did RF10 change shared renderer behavior that the deterministic product
   should not inherit?
3. Do the S12 navigation, S13 population, combat, network, incident, package,
   and native Metal gates still pass together?
4. What is the next bounded deterministic-rendering phase?

## Repository reconciliation

The completed RF10 branch was fast-forwarded into the canonical local `master`
history. RF10 remains an external, unpromoted technical trial. No model,
checkpoint, training corpus, experiment run, or learned bundle was copied into
installed game content.

The pause record is authoritative. Historical neural plans remain evidence and
are not an active backlog. DR1 is the implemented deterministic-rendering
successor to this audit.

## Default-runtime audit

The installed ordinary product was launched with every `INCINERATOR_NR_*`
variable absent.

Verified:

- `configureNeuralRendering` returns before constructing neural input,
  inference, capture, target-frame, or evaluation hosts;
- no `.mlmodel`, `.mlpackage`, `.mlmodelc`, `.pt`, `.safetensors`, or `.onnx`
  artifact is installed under `zig-out`;
- the exact installed district catalog and bundles remain the only game
  content required by `--verify-install`;
- no model path, digest, experiment root, or learned output is selected by the
  ordinary runtime; and
- semantic gameplay authority, replay, and network placement remain
  independent of the learned presentation experiment.

The ordinary macOS graphical binary still links Foundation and Core ML and the
default graphical build still compiles neural-input shaders. That is recorded
as A-F061 in the living architecture review. It is dormant build/link
reachability, not runtime model selection. It remains a measured follow-up
before distribution or a new platform—not authorization to resume or refactor
the paused experiment.

## Shared-path defects found and corrected

### Conventional scene was pinned to the experiment extent

The native run exposed a defect that offscreen semantic visibility did not:
the deterministic world occupied an unscaled centered `640×360` rectangle in
the `1600×900` drawable, surrounded by black. RF10 had made its fixed source
extent the renderer default even when neural mode was inactive.

The renderer now follows the acquired drawable extent by default and recreates
its scene/depth pair transactionally when that extent changes. Only explicit
neural experiment activation pins the conventional scene to the historical
`640×360` extent. A pure contract test distinguishes drawable and fixed modes.

A fresh native Metal launch verified a full-window conventional scene with the
editor both visible and hidden. Product HUD feedback exposed death, cooldown,
ready, and successful respawn state; no learned asset or host was active.

### Incident walkthrough depended on a coincidental encounter

The first resumption run failed only the `visual_budget` incident-hardening
profile while waiting for player death. Its schema-5 evidence showed the
explicit hostile population member P01 alive and presented, but its activity
had moved it outside perception range while the scripted player remained
motionless. The test was waiting for an accidental meeting rather than driving
the promised combat journey.

The shared scripted journey now approaches the stable P01 population identity
in both its await-death and fight stages. It uses ordinary camera/movement and
melee inputs; it does not teleport the player, force NPC state, or bypass
authority. All five incident-hardening profiles then passed.

## Acceptance evidence

Commands and final results:

```sh
zig build install -Deditor=true --summary all
# 71/71 steps succeeded

zig build verify-incident-hardening -Deditor=true -j1 --summary all
# 63/63 steps succeeded

zig build test -Deditor=true -j1 --summary all
# 286/286 steps succeeded; 987/987 tests passed

zig build verify-s13 -Deditor=true -j1 --summary all
# 265/265 steps succeeded; 341/341 tests passed
```

The S13 aggregate includes:

- focused S12 navigation and S13 population ownership;
- 12-member product, 16-controller physical, and 64-record synthetic cohorts;
- installed Metal population at 240 and 40 virtual render Hz;
- installed Metal combat/death/respawn visibility at 240 and 80 virtual render
  Hz;
- clean, nominal, adverse, blackout, reconnect, replay, and interaction gates;
- real GameNetworkingSockets listen and dedicated process acceptance;
- extracted source, cold headless, package, and install verification; and
- all five schema-5 incident failure/hardening profiles.

The repository-wide suite includes the retained neural contract tests, but it
does not train a model, require a trial bundle, or activate neural inference.

## Native walkthrough status

Agent-controlled native inspection confirmed:

- the installed Metal product opens at `1600×900`;
- the deterministic scene fills the drawable rather than inheriting RF10's
  fixed viewport;
- editor UI remains a swapchain overlay outside the product scene;
- editor hide/show works;
- death is shown as a red retained body with explicit HUD text; and
- `R` returns the player to an alive presentation with an explicit
  `respawned` result.

The automated product journeys cover movement, vehicle, carry/drop, combat,
NPC death/replacement, room placement, and incident capture. The product owner
accepted the complementary perceptual S12/S13 checkpoint on 2026-08-17 after
reviewing the ordinary product.

## Outcome and next step

The deterministic engine boundary is healthy after the two corrections. The
neural proof changes no authority or source-of-truth decision and supplies no
reason to redesign gameplay architecture.

The S12/S13 checkpoint cleared DR1 to begin. DR1's completed implementation and
agent-native evidence are recorded in
[its validation ledger](dr1-playable-deterministic-visual-fidelity.md). Do not
resume neural work or introduce a generic render graph, PBR framework, or
shadow stack without a later product slice demonstrating a concrete need.
