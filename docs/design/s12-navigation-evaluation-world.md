# S12 Navigation Evaluation World

**Status:** Implemented and automatically validated; human walkthrough pending

**Date:** 2026-07-27

**Parent plan:**
[`s12-destination-driven-navigation.md`](s12-destination-driven-navigation.md)

**Decision:**
[`../adr/023-semantic-destinations-and-navigation-recovery.md`](../adr/023-semantic-destinations-and-navigation-recovery.md)

## Purpose

Replace the current triangle conformance presentation and six-node line with a
coherent, low-poly urban navigation block that makes S12 behavior playable,
visible, scriptable, and diagnosable.

“Higher fidelity” means a readable place with roads, sidewalks, landmarks,
obvious collision, named destinations, alternate routes, and stable visual
orientation. It does not mean production art, a larger city, a new renderer,
or S15 content expansion.

The original S3/S6 triangle fixtures remain narrow cooker conformance inputs.
S12 adds separate product/evaluation content.

## Scope

The world remains inside the existing two adjacent districts:

| District | Bounds |
|---|---|
| West `(0,0)` | X `[-8,8)`, Z `[-8,8)` |
| East `(1,0)` | X `[8,24)`, Z `[-8,8)` |

The total playable block is 32×16 metres. Both normal-product districts remain
warm; the validation composition can still unload/reload one district to prove
waiting and generation recovery.

## Top-Down Layout

```text
                                      NORTH (+Z)

 WEST DISTRICT (depot/plaza)                  EAST DISTRICT (market/yard)

   W0 Player Plaza
      |
   W1 North Junction ---- W4 Depot Junction ---- W5 Forecourt ---- W6
      |                         |                                  ||
      |                    visible central                         || North Gate
      |                       blocker                              ||
   W2 South Junction ---- W3 South Approach --------------------- W7
                                                                  ||
============================== DISTRICT SEAM X=8 ==================||===========
                                                                  ||
   E0 North Gate ---- E1 Market North ---- E2 Market Terminal     ||
                          |                                       ||
                          E7 Alley ---- E3 Midblock                ||
                                           |                      ||
   E6 South Gate ---- E5 South Junction -- E4 Transit Yard        ||

                                      SOUTH (-Z)
```

The coordinate/edge tables below are authoritative; the diagram is a readable
orientation aid.

## Exact Navigation Graph

### West nodes

| Ref | Landmark | Position |
|---|---|---|
| W0 | Player Plaza | `(-5, 0, 5)` |
| W1 | West North Junction | `(-5, 0, 3)` |
| W2 | West South Junction | `(-5, 0, -3)` |
| W3 | South Gate Approach | `(3, 0, -3)` |
| W4 | Depot Junction | `(2, 0, 3)` |
| W5 | Depot Forecourt | `(4, 0, 5)` |
| W6 | North Seam Gate | `(7, 0, 4)` |
| W7 | South Seam Gate | `(7, 0, -3)` |

West reciprocal links:

```text
W0-W1
W1-W2
W1-W4
W2-W3
W3-W7
W4-W5
W5-W6
```

### East nodes

| Ref | Landmark | Position |
|---|---|---|
| E0 | North Seam Gate | `(9, 0, 4)` |
| E1 | Market North Junction | `(13, 0, 4)` |
| E2 | Market Terminal | `(20, 0, 5)` |
| E3 | East Midblock | `(20, 0, 0)` |
| E4 | Transit Yard | `(20, 0, -4)` |
| E5 | South Junction | `(14, 0, -4)` |
| E6 | South Seam Gate | `(9, 0, -3)` |
| E7 | Alley Junction | `(14, 0, 0)` |

East reciprocal links:

```text
E0-E1
E1-E2
E1-E7
E7-E3
E3-E4
E4-E5
E5-E6
```

Cross-district reciprocal links:

```text
W6-E0  North Gate
W7-E6  South Gate
```

This uses exactly eight nodes and sixteen directed edge records per district.
The maximum node degree is three and the longest useful simple route fits the
existing sixteen-node route capacity.

## Semantic Destination Catalog

The initial catalog is deliberately explicit:

| ID/name | Primary anchor | Meaning |
|---|---|---|
| `player_plaza` | W0 | Open player/NPC observation and starting area |
| `depot_forecourt` | W5 | North-route west landmark |
| `south_gate_approach` | W3 | Vehicle-accessible push/recovery zone |
| `market_terminal` | E2 | Long cross-district destination |
| `alley_junction` | E7 | Narrow-route obstruction test |
| `transit_yard` | E4 | South-route destination and recovery landmark |

Names are developer/content metadata. Persistence and replay use stable IDs
inside the exact content fingerprint.

## Route Pressure

The map must prove distinct navigation facts:

| Situation | Expected result |
|---|---|
| Travel from `player_plaza` to `market_terminal` | Deterministic lowest-cost route and one arrival |
| North Gate closes while South Gate remains open | Route invalidation and alternate-route replan |
| Both gates close | `blocked` under runtime traversal state, not structural `unreachable` |
| East district is inactive | `waiting_for_content`, with an active prefix to the seam |
| NPC is pushed from north toward south corridor | Accept pose, select a new reachable anchor, retain destination |
| Vehicle or carryable obstructs an open segment | Suspect, confirm, temporarily exclude edge, replan or remain blocked |
| Complete test graph has no structural path | `unreachable`; this uses a focused fixture, not a fake island in the product map |

## Traversal Gates

The evaluation world owns two bounded seam gates. This is a test-world vertical
slice, not a generic door system.

Each gate owns:

- one stable gate ID;
- open/closed authority state;
- the exact reciprocal edge pair it controls;
- one visible barrier state;
- matching collision state;
- one monotonic topology revision change;
- persistence/replay state; and
- a developer/scenario command.

Logical traversal, visible barrier, and collision must change transactionally.
If that cannot be achieved with the current authority cycle, the phase stops;
it must not ship a gate that looks open while pathfinding or collision treats
it as closed.

The normal product starts with both gates open. Validation and the developer
Navigation Lab may close either gate.

## Visual Scene

Add:

```text
fixtures/s12_world_west/
fixtures/s12_world_east/
fixtures/s12_world_catalog/
```

Each district uses the existing cooker and a self-authored embedded glTF:

- one combined surface mesh for asphalt, sidewalks, plaza panels, parking
  lines, and district-seam markings;
- one small instanced landmark mesh for depot/market blocks, bollards, signs,
  and destination beacons;
- four opaque materials: asphalt, concrete, landmark body, landmark accent;
- one small embedded palette/pattern PNG tinted by material base color;
- district-specific accent colors and recognizable silhouettes; and
- no external source assets.

Initial geometry target per district:

| Resource | Target | Existing ceiling |
|---|---:|---:|
| Nodes | 8 | 8 |
| Meshes | 2 | 2 |
| Primitives/materials | 4 / 4 | 4 / 4 |
| Textures | 1 | 2 |
| Vertices | 70–96 | 128 |
| Indices | 120–180 | 384 |
| GPU instances | about 16 | 32 |
| Cooked file | below 64 KiB | 64 KiB |

No renderer/content capacity is raised until the authored scene proves one is
actually exceeded.

## Collision And Visual Truth

Logical collision remains the canonical district recipe. Each district keeps
the existing support surface plus two meaningful blocker boxes, avoiding a new
body-count or collision-binding program.

- Every blocker retains an always-visible proxy.
- Decorative meshes may add readable form but never claim authoritative
  collision.
- Roads and navigation segments must pass the canonical swept-capsule
  clearance test.
- Default character, vehicle, carryable, NPC, and replacement positions must
  pass the same clearance catalog.
- The composition-private `sandbox_block` may not remain an invisible obstacle
  outside the canonical recipe. It must either move into the recipe or leave
  the normal S12 product.

This preserves the hard lesson from human testing: inability to move must
always have a visible, inspectable cause.

## Default Playable Cohort

The world starts with:

- player at Player Plaza;
- vehicle in the plaza parking apron, clear of W0-W1;
- carryable beside the plaza, clear of both vehicle and route;
- one combined destination-travel/hostile NPC. A second automatic traveler was
  deliberately not added before S13 population ownership; Navigation Lab can
  retarget the existing stable NPC for evaluation.

Exact positions are finalized by clearance and camera/readability tests.
Automated navigation journeys use a controlled non-hostile fixture; ordinary
product play separately proves encounter interruption and destination resume.

## Navigation Lab

The editor gains one read-only/control window scoped to this evaluation:

- select an NPC by stable identity;
- assign one catalog destination;
- open/close North Gate;
- open/close South Gate;
- enable graph, destination, route, progress, obstruction, and district
  overlays through the existing Debug Visualization owner;
- show the last destination/plan/replan/status transition;
- use the existing Gameplay Inspector and Incident Capture windows for
  trace/freeze/copy/handoff workflows.

East-district unload/reload remains a scripted validation-composition
capability exercised by the installed S8/S12 smoke. It is not duplicated as a
normal-product world-streaming override.

UI controls are the accepted macOS path. S12 does not require a new function
key or global shortcut.

## Visual Language

| Evidence | Color |
|---|---|
| Admitted/open graph edge | muted cyan |
| Current committed route | bright green |
| Current segment | white |
| Inactive-content edge/frontier | amber |
| Runtime-disabled gate/edge | magenta |
| Suspected/confirmed physical block | red |
| Structurally unreachable destination | red cross plus text |
| Destination marker | destination-specific beacon |
| Re-anchor/displacement vector | blue |

Colors are accompanied by text/status in the inspector. Color alone is not the
semantic contract.

## Human Evaluation Walkthrough

1. Select the traveler and assign `market_terminal`.
2. Observe the chosen route, destination beacon, route revision, and arrival.
3. Reset, close North Gate during travel, and observe one replan through South
   Gate.
4. Push the NPC off its path with the vehicle. Confirm no snap-back,
   disappearance, identity change, or destination loss.
5. Park the vehicle across a route. Confirm `blocked` is visible and
   inspectable; move the vehicle and observe recovery.
6. In the validation product, unload east. Confirm waiting at the seam, then
   reload and observe a generation-triggered replan and arrival.
7. Trigger incident capture during one replan. Confirm the bundle contains the
   destination, route revisions, trigger, topology/ticket state, and visual
   anchors.

## Acceptance

- The scene is recognizably one urban test block rather than isolated debug
  primitives.
- Every collision object that can stop the player/NPC is visible.
- Both cross-district corridors are playable and vehicle-accessible where
  intended.
- The graph, destinations, static collision, spawns, cooker output, installed
  catalog, headless recipe, and replay all use one exact cohort.
- The complete map remains within declared CPU, GPU, body, content, and
  incident budgets.
- The original conformance fixtures remain narrow and deterministic.

## Explicit Deferrals

- More than two districts or a larger city footprint.
- Production buildings, characters, vegetation, lighting, shadows, weather,
  traffic, or animation.
- Artist-authored collision binding or automatic nav generation.
- Navmesh integration, crowds, procedural roads, or runtime map editing.
- Population roles and activities; S13 owns that pressure.
