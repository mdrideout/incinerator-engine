# DR1 Playable Deterministic Visual Fidelity Validation

**Status:** Accepted on Apple Silicon macOS; implementation, automated/native
acceptance, agent-native inspection, and product-owner visual walkthrough complete

**Recorded:** 2026-08-18

**Plan:**
[DR1 playable deterministic visual fidelity](../design/dr1-playable-deterministic-visual-fidelity.md)

**Renderer:** `sdl_gpu_metal_deterministic`, visual schema 1

## Phase ledger

| Phase | Status | Evidence |
|---|---|---|
| DR1-A — baseline and independence | Accepted | Clean-environment native launch, linkage/content audit, defect characterization below |
| DR1-B — one lit product path | Accepted | Normal-bearing product shapes; obsolete flat product factories deleted |
| DR1-C — explicit light/material response | Accepted | Renderer-neutral contracts, reflected 96-byte fragment uniform, shader tests |
| DR1-D — evaluation-world composition | Accepted | Roads, sidewalks, seam, activity/route landmarks, multipart actors and vehicle |
| DR1-E — grounding gate | Accepted without a shadow pass | Lit surfaces, low support markings, occlusion, and authored collision masses are readable at the accepted cameras |
| DR1-F — Render Lab and incident evidence | Accepted | Render Lab, schema-5 `render_state`, capability matrix, strict fresh-agent summary |
| DR1-G — native acceptance and cleanup | Accepted | Editor-on/off aggregates, repaired full journey, replay, screenshot and dependency evidence below, and product-owner visual walkthrough |

## Entry baseline and runtime independence

The pre-DR1 conventional product mixed unlit vertex-color product primitives
with normal-bearing loaded scenes. The model fragment shader owned a hard-coded
light, the sandbox mostly collapsed its visual catalog to flat color, and
incident evidence could not identify the render contract or light/material
state that produced a frame.

The ordinary product was launched with `INCINERATOR_NR_BUNDLE_ROOT`,
`INCINERATOR_NR_EXPERIMENT_ROOT`, and `INCINERATOR_NR_MODEL_PATH` removed. It
selected SDL GPU/Metal, loaded only the installed district catalog and bundles,
and required no model, checkpoint, experiment directory, or learned output.
No `.mlmodel`, `.mlpackage`, `.mlmodelc`, `.pt`, `.safetensors`, or `.onnx`
artifact exists under `zig-out`.

The graphical executable still links Core ML because the paused adapter remains
in the default macOS build closure. This is the already-recorded A-F061 build/
link pressure, not runtime selection. DR1 does not hide it behind a new plugin
or backend abstraction.

## Implemented visual contract

DR1 adds one renderer-neutral `SceneLight`, one bounded `SurfaceMaterial`, a
versioned conventional renderer identity, and per-frame draw-path counts. The
sandbox chooses light and surface policy; the renderer transports values and
owns Metal resources; shaders evaluate the values; gameplay authority remains
unaware of all of them.

Product ground, district scenes, environment markings, carryables, character
parts, vehicle parts, chassis, and wheels now use normal-bearing `VertexPNU`
geometry. Debug lines/fills and intentionally exact markers remain explicit
unlit draws. The old public flat cube, ground, wheel, and capsule product
factories were deleted rather than retained as a compatibility fork.

The reflected model fragment contract is 96 bytes and carries texture/lit
selection, base color, emissive response, sun direction/color/intensity, and
ambient color. Headlights are visibly emissive but remain presentation-only;
hit and death colors override every character part. Non-uniformly scaled parts
use the inverse-transpose normal matrix.

The bounded evaluation composition adds low, visually non-colliding road,
sidewalk, district-seam, activity, route, and building-accent markings. Existing
authored blockers remain the only objects that read and behave as solid
obstacles. The lit scene, support markings, ordinary depth occlusion, and low
decorative pads made contact and ordering readable in agent-native inspection,
so DR1-E deliberately omitted a shadow map. Cascades, AO, fog, post-processing,
and a render graph remain unjustified.

## Metal fence defect found during DR1-A

A focused foreground run initially produced no screenshot completions and no
district GPU-residency completion even though the logical journey continued.
Two concrete defects met at the same boundary:

1. pinned SDL 3.4.14's Metal backend implements `SDL_QueryGPUFence` as
   “is busy,” the inverse of the documented public “is signaled” result; and
2. asynchronous screenshot, semantic-ID, and physics-debug consumers acquired
   a fence from a later empty submission rather than from the command buffer
   that actually contained their downloads/draws.

SDL fixed the Metal inversion upstream in commit
`b340ddcd7b44511f7b49005ba4a91a3c9907f77e`, after the pinned release. The
current macOS-only cohort centralizes the exact 3.4.14 inversion in `sdl.zig`;
the comment names the removal commit so the next cohort upgrade cannot retain
the workaround silently. The renderer now acquires one fence from the real
frame submission and shares it by explicit retain/release ownership with every
post-submit consumer. District uploads continue to own their own exact upload
submission fences. No live path waits for a fence.

A foreground rerun completed 362/362 trail downloads and 31/31 anchors with
zero misses or fence failures, and both cooked districts reached GPU resident
state. The final journey below preserved the same zero-miss result.

## Gameplay-journey defects found during DR1-G

The first final native journey failed honestly in `await_player_death`. Evidence
showed the scripted player parked directly behind the authored hostile at
roughly 1.4 m while the NPC correctly retained its sight cone. The harness had
accidentally become a blind-spot test. It also released the brake too soon
after its vehicle stage; the unoccupied chassis coasted beyond the real
100-by-100-metre support plane and fell while the later journey continued.

The corrected journey now:

- approaches the front of an unengaged hostile and uses one ordinary melee
  attempt to provoke it when in range, rather than bypassing perception;
- accelerates and steers for a short interval, then retains brake/hand-brake
  long enough to settle before exit;
- keeps braking while exit is admitted; and
- explicitly exits, re-enters, and exits again before district travel.

This is test-driver correction, not changed NPC sight, vehicle physics, world
walls, or authority policy. The accepted run ended with the chassis at
`[-1.791, 0.908, -3.427]` instead of below the world.

## Native incident and replay evidence

Accepted run:

```text
/tmp/incinerator-dr1-journey-repair-20260818T030741Z/
  2026-08-18T03-07-42.320Z_solo_b31ebca4
```

The installed editor-enabled Metal product completed at tick 2,256 and frame
3,670. It proved collect/drop, vehicle enter/drive/brake/exit/re-entry/exit,
east/west district traversal, player damage/death/cooldown/respawn, authored
hostile damage/death, safe replacement, resize/restore, four overlapping
incident flags, handoff persistence, and accepted-ingress replay.

Bundle results:

- status complete; 9,784 records in eight stream segments;
- four complete anomalies, sixteen materialized windows, and 386 visuals;
- writer queue high-water 38/1,024, zero dropped records, and durable progress
  3,541/3,541;
- zero screenshot misses, zero fence failures, and no capture rejection;
- replay and LLM handoff both persisted;
- `deterministic_render_state=true` in the capability matrix; and
- accepted-ingress replay verified 2,196 ticks.

The canonical repository diagnostic skill parsed schema 5, population and
navigation state, all four anomaly windows, and `render_state` without special
instructions. Its final sampled render record reported 145 lit product draws,
25 intentional unlit product/marker draws, 170 normal-geometry draws, zero
color-geometry draws, and the exact scene light/material identity.

The 38 one-second recorder samples measured frame-time
`10.091/11.357/37.634 ms` at p50/p95/p99. The `123.528 ms` maximum coincided
with early capture/materialization work and is retained rather than hidden.
This is not an apples-to-apples fidelity delta: the accepted ED1 control ran in
an unfocused/unthrottled desktop state and did not provide a comparable native
sample. The final run reserved 93,312,000 bytes of bounded GPU download storage
for incident capture and wrote a 196 MiB evidence folder. No new performance
limit was invented.

## Automated evidence

The first complete `verify-s13` closure exposed two graphical paths that the
ordinary sandbox aggregates did not compile or exercise: the shared network
client's HUD helper still passed a raw color to the new material API, and the
independent S11/incident visibility pass still required the deleted
position/color product format. The client now converts HUD colors at its
presentation boundary, while semantic visibility consumes the same
normal-bearing product geometry as the visible renderer. Focused MP6
compilation and both installed Metal S11 visibility rates passed before the
complete aggregate was rerun. This is retained as validation evidence rather
than hidden as intermediate churn.

```sh
zig build test-shaders --summary all
# 31/31 steps; 2/2 tests

zig build test -Deditor=false --summary all
# 285/285 steps; 995/995 tests

zig build test -Deditor=true --summary all
# 288/288 steps; 995/995 tests

zig build inspect-incident -- '<accepted-run>'
# INCIDENT_BUNDLE_VALID

python3 skills/incinerator-incident-diagnostics/scripts/summarize_incident.py '<accepted-run>'
# schema 5 and deterministic_render_state recognized

zig build replay-incident -- '<accepted-run>' "$PWD/zig-out/share/incinerator/content"
# 2,196 ticks verified

zig build verify-s13 -Deditor=true -j1 --summary failures
# complete S13/S12/S11/network/headless/incident closure passed
```

Both aggregate profiles include install/package/source/headless, gameplay,
network, replay, S12/S13, renderer/resource, and architecture boundaries. The
M5 closed client dependency gate explicitly classifies the renderer-neutral
render contract and sandbox visual catalog without admitting authority or
physics internals. The final S13 closure also passed all five installed Metal
incident-hardening profiles plus real-GNS two-client listen and dedicated S11
encounter processes.

## Acceptance split

| Question | Result |
|---|---|
| Authority/replay/network truth unchanged by visuals | Automated pass |
| One explicit lit product path and exact unlit debug path | Automated and incident pass |
| Renderer identity/light/material evidence is grep-friendly | Fresh-agent skill pass |
| Native Metal lifecycle, readback, district residency, and replay | Native pass |
| Character/vehicle/carry/combat/death/replacement journey | Scripted native pass |
| Render Lab starts focused under the rendering layout | Agent-native screenshot pass |
| Overall lighting, palette, grounding, motion feel, and surprising artifacts | Product-owner accepted the ordinary product on 2026-08-18 |

The product owner accepted the ordinary deterministic product after the native
and agent-native evidence above was complete. No visual anomaly was retained at
the checkpoint. DR1 is fully accepted; later visual changes are new work rather
than unfinished DR1 scope.
