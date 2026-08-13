# RF5 Rich-Fidelity Validation

**Status:** Accepted

**Date:** 2026-08-10

**Roadmap:** [Rich Fidelity Roadmap](../design/rich-fidelity-roadmap.md)

## Outcome

RF0 through RF5 now provide one bounded visual vocabulary and one exact paired
presentation event suitable for deciding whether the target art direction is
worth training. No model was trained or promoted in this phase.

The conventional sandbox now draws:

- player and NPC bodies as six stable T-shaped parts while preserving the
  authority capsule, movement, combat, role colors, death, and respawn;
- a vehicle as eleven stable body/window/bumper/light parts plus the existing
  four authority-driven articulated wheels, without changing Jolt geometry or
  handling; and
- the existing streamed two-district authored environment, basic textured
  surfaces, collision proxies, navigation, population, and incident owners.

The paired RF evaluation event contains 49 stable draws and uses the same
bounded catalog as the default sandbox; it is deliberately controlled evidence,
not a claim that arbitrary live gameplay already exports rich target truth. The engine renders
the cheap six-channel profile at native `160×90`; the Blender adapter renders
the corresponding material/lighting target directly at native `400×225`.
Neither side reads a `1600×900` frame, resizes a larger target, or invents
gameplay state.

## Human review artifacts

The final immutable evidence is external by policy:

```text
~/Library/Application Support/Incinerator/neural-rendering/experiments/
  rf5-native-final-20260811T015200Z/
    acceptance.json
    reproducibility.json
    run-a/evaluation/baselines/frame-00000240/
      native-160x90-to-400x225-review.png
    run-a/evaluation/reports/
      nr4-c-native-sequence-review.png
      segment-00-camera_motion.png
      segment-01-object_motion.png
      segment-02-near_edge.png
      segment-03-wheel_articulation.png
      segment-04-occlusion_disocclusion.png
      segment-05-lighting_effect.png
```

The first sheet is the primary approval surface. It shows native cheap input,
UI-only zoom, direct rich target, and three deterministic resizing baselines.
The second sheet shows all 18 paired frames across six one-cause segments.
The reproducible two-run gate is `verify_rf5.py`; its `acceptance.json` remains
`technical_complete_human_review_pending` until this review is decided.

The product owner accepted this exact rich-target direction on 2026-08-10.
The immutable external acceptance file correctly retains the state it had when
generated; this committed disposition is the later human decision and
authorizes RF6 cumulative training without authorizing model promotion.

## Automated results

| Gate | Result |
|---|---|
| Zig full suite, editor disabled | Pass |
| Blender/Python target contracts | 16/16 pass |
| S2 Metal vehicle product acceptance | 3,840 ready frames; entry, movement, steering, wheel spin/steer, brake, hand brake, collision displacement, exit, and character visibility pass |
| S11 Metal combat product acceptance | 3,840 ready frames; hit, death, retained dead body, respawn, NPC death, health bars, HUD, and visibility oracle pass |
| S13 Metal population product acceptance | 3,840 ready frames; 12 stable NPCs; resident/worker/visitor and traveling/dwelling/waiting states pass with no incomplete frame after full admission |
| Native still | 49 draws; 44 visible target identities; identity IoU 0.928770; direct 400×225 Cycles render 769.100 ms |
| Native sequence | Two reproducible 18/18-frame runs, six exact causal segments; identity IoU 0.928770–0.972320; run-A target renders 15.961 s total |
| Reproducibility | Engine capture, normalized target package, target identity, and target depth are exact across runs; display variation is at most one u8 channel value and normal variation is retained numerically |
| Resolution truth | Native 160×90 cheap input; direct native 400×225 target; exact 5:2 pixel-center mapping; no foreign extent |
| Rights/lineage | Repository-authored procedural content; no external art and no pretrained weights |

## Fail-closed findings during validation

Validation found and corrected three real cohort errors:

1. Player and NPC shared valid catalog part names, but the target adapter
   requires globally unique evidence labels. Adapter labels are now qualified
   as `character/...` and `npc/...`; semantic identity remains shared by entity
   plus stable part ordinal.
2. The causal audit still declared the old two-piece vehicle, one-piece NPC,
   and two emissive objects. It now requires the exact eleven body parts, four
   wheels, six NPC parts, and four emissive surfaces.
3. The first moving cameras exposed marginal one-pixel bumper/headlight
   mismatches between the two rasterizers. The shared authored parts now have
   deliberate wraparound/overhang geometry. The target omission check remains
   strict; no visibility threshold was added.

RF6's first broader camera cohort subsequently exposed the same class of issue
in the nearly coplanar character facing marker. The marker now deliberately
overlaps and protrudes beyond the head face. The failed external RF6 root is
retained as diagnostic evidence; the strict omission gate remains unchanged.

An initial 960-frame S2 invocation also failed because it could not finish the
existing scripted interaction. The canonical 3,840-frame scenario passed; no
product or test rule was changed to accommodate the short run.

## Architectural review

- `src/sandbox_visual_catalog.zig` owns normalized visual parts and surface
  intent only.
- `src/sandbox_visual_resources.zig` owns GPU lifetime and one neutral part
  mesh.
- `src/sandbox_visual_composition.zig` owns the pure conversion from immutable
  extracted poses and dimensions into color/model part plans.
- `src/main.zig` submits those plans and mirrors exact per-part identities into
  the neural adapter.
- `src/hosts/neural_target_fixture.zig` consumes the same catalog and owns the
  validation event's rich material/light intent.
- Jolt bodies, character capsules, navigation, district authority, gameplay
  state, and normal runtime installation remain unchanged.

This is intentionally not a generic prefab system, scene graph, shader graph,
or asset pipeline. RF6 may extract another abstraction only when cumulative
training or a second real content cohort demonstrates the need.

## Human decision

**Accepted 2026-08-10.** RF6 corpus manufacture, random-origin training,
ablation, held-out evaluation, export, and an external live trial are
authorized. Model promotion and NR6 temporal implementation remain separate
decisions.
