# S15 Four-District Evaluation World

**Status:** Accepted implementation specification

**Parent plan:**
[S15 Content-Rich District Expansion](s15-content-rich-district-expansion.md)

## Spatial Layout

Each district is the existing canonical 16 m half-open cell. The authored
cohort occupies `x ∈ [-8,24)` and `z ∈ [-8,24)`:

```text
z=24  ┌──────────────────────┬──────────────────────┐
      │ northwest (0,1)      │ northeast (1,1)      │
      │ civic/plaza loop     │ station/alley loop   │
z=8   ├──────────────────────┼──────────────────────┤
      │ southwest (0,0)      │ southeast (1,0)      │
      │ player/depot/south   │ market/transit       │
z=-8  └──────────────────────┴──────────────────────┘
     x=-8                   x=8                    x=24
```

The player, vehicle, and carryable retain their readable southwest starting
separation. No wall or invisible containment surface surrounds the cohort.
Sparse space outside authored decoration remains traversable on the continuous
sandbox support plane.

## District Identity

| Semantic ID | Coordinate | Bundle key | Visual identity |
|---|---:|---|---|
| `district.southwest` | `(0,0)` | `district/s15_world_southwest` | player plaza, depot, south landmark |
| `district.southeast` | `(1,0)` | `district/s15_world_southeast` | market, alley, transit yard |
| `district.northwest` | `(0,1)` | `district/s15_world_northwest` | north plaza and civic court |
| `district.northeast` | `(1,1)` | `district/s15_world_northeast` | station concourse and north alley |

South-row source geometry is the accepted project-owned S12 fixture. North-row
bundles deliberately reuse that geometry through an explicit offline root
translation and different recipe/identity/dependency inputs. This proves
deterministic instancing in the cook boundary without introducing runtime
source parsing or a prefab framework.

## Navigation Topology

Every district owns eight world-space nodes and sixteen canonically ordered
directed edges. All edges are reciprocal. One link crosses each shared seam:

- southwest ↔ southeast;
- northwest ↔ northeast;
- southwest ↔ northwest; and
- southeast ↔ northeast.

The complete graph contains 32 nodes and 64 directed edges. The two runtime
traversal gates now represent the south-row and north-row east/west seams;
vertical seams remain open. Closing either horizontal gate retains the opposite
route around the block.

The graph must support:

- clockwise and counter-clockwise block circuits;
- south-to-north travel on both west and east sides;
- alternate travel when one lower-row gate closes;
- content waiting and generation changes under lifecycle validation;
- vehicle displacement re-anchoring in any of the four districts; and
- deterministic equal-cost tie resolution.

## Support and Collision

The continuous composition ground is the only flat support collision. Each
district owns exactly two axis-aligned obstacle boxes with visible proxies.
Cooked decoration is not collision authority. Route and population admission
tests use those exact obstacle boxes.

No S15 geometry claims ramps, stairs, curbs, interiors, roofs, or bridges as
walkable support. Decorative road/sidewalk height remains low enough not to
misrepresent collision.

## Destinations and Population Anchors

Destinations 1–16 retain the south-row S13 identities. Destinations 17–24 add
two slots at each north-row site:

| IDs | Site | Owner |
|---|---|---|
| 17–18 | North Plaza | northwest |
| 19–20 | Civic Court | northwest |
| 21–22 | Station Concourse | northeast |
| 23–24 | North Alley | northeast |

Eight additional spawn slots provide four clear candidates in each north-row
district. At least four ordinary members initially occupy north-row slots, and
all four activity programs include north-row work. The roster remains twelve
ordinary and sixteen physical-stress members; S15 expands world pressure, not
population count.

## Streaming and Presentation

The product pins all four exact route entries after catalog admission. The
existing four-scene GPU registry is therefore exercised at its current real
capacity. Validation profiles use the same slots and one worker to prove
ordered admission, cancellation, independent logical/visual publication,
unload, and drain.

The deterministic environment draws:

- two east/west roads and walks, one in each row;
- north/south connectors across the central seam;
- four readable activity/landmark clusters; and
- explicit district seam markers available in developer visualization.

The global support material remains visually subordinate to authored road and
walk surfaces. It exists so leaving authored decoration is open and debuggable,
not to pretend the surrounding checkerboard is finished city content.

## Required Evidence

- Four installed bundle identities and one catalog fingerprint.
- Exact logical/GPU slot state for every coordinate.
- Route revision/digest/nodes for a cross-axis journey.
- Population member, site, slot, destination, and actor lineage in north-row
  activity.
- Static obstacle body count distinct from the single composition support.
- Resident scene count/bytes and high-water upload state.
- Native Metal screenshots or incident trails showing each district identity.
- Fixed-tick and route-search measurement with 12 ordinary and 16 stress NPCs.

## Deferred

More than four resident scenes, eviction priority, navmesh tiles, crowd
avoidance, vertical city geometry, production art, traffic, interiors, and
separate game packaging remain outside this evaluation world.
