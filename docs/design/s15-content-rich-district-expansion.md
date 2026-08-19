# S15 Content-Rich District Expansion

**Status:** Accepted; implementation, automated/native evidence, and human walkthrough complete

**Decision:**
[ADR-028](../adr/028-content-rich-four-district-cohort.md)

**Evaluation world:**
[S15 Four-District Evaluation World](s15-four-district-evaluation-world.md)

**Validation:**
[S15 Validation Ledger](../validation/s15-content-rich-district-expansion.md)

## Outcome

Deliver one materially larger deterministic sandbox in which the player can
walk and drive around a four-district block, twelve authored pedestrians use
destinations on both spatial axes, and the same exact cohort works in solo,
listen, and dedicated authority placements. The slice must make content,
streaming, navigation, population, support ownership, diagnostics, replay, and
Metal presentation agree without introducing a generic world framework.

## Ownership Contract

| Owner | S15 responsibility |
|---|---|
| Sandbox district recipe | Four installed coordinates, obstacle boxes, graph fragments, destinations, presentation policies, and exact route validation |
| Offline cooker/catalog | Source glTF translation, deterministic dependency closure, cooked bytes, and canonical catalog identity |
| District feature | Four logical lifecycle slots and collision entities for district-owned obstacles |
| Sandbox composition | The one continuous flat support body/visual plus deterministic road and landmark decoration |
| Streaming host/GPU registry | Four exact content slots, decoded ownership, upload/publication, diagnostics, and clean drain |
| Navigation planner/NPC | 32-node bounded route derivation, execution, recovery, and evidence |
| Population catalog/runtime | North-row sites, slots, spawn candidates, and revised activity intent |
| Session authority | Four-district bootstrap/publication and identity routing; no path or activity policy |
| Developer/incident hosts | Four-slot state, route/content evidence, timing, and anomaly correlation |

## Phases

### S15-A — Decision and cohort closeout

- Close S14's product-owner checkpoint and make S15 active.
- Accept ADR-028 and this phased contract.
- Advance exact recipe, snapshot, replay, protocol/content, and population
  cohorts without compatibility fallbacks.
- Replace two-entry assumptions with the canonical installed coordinate list.

Acceptance: documentation and constants name one current cohort, historical
documents remain historical, and no code path silently assumes two entries.

### S15-B — Four-district cook and admission

- Cook southwest, southeast, northwest, and northeast bundles from project-
  owned source content.
- Add an explicit root-translation cooker input so reused source geometry can
  be placed without mutating runtime transforms or inventing repository paths.
- Install provenance for every S15 bundle and one four-entry catalog.
- Validate the complete dependency diamond, logical shape, deterministic
  repeated cook, relocation, and headless content manifest.

Acceptance: fresh and repeated bundles/catalogs are byte-identical, exact
lookups and closures pass, and installed admission succeeds from `/tmp`.

### S15-C — Logical world and support ownership

- Expand district feature/replay/diagnostic capacity to the exact four-entry
  cohort.
- Remove district floor boxes; retain the composition ground as the only flat
  support authority.
- Add distinct obstacle layouts for the north row and preserve open traversal
  beyond authored decoration.
- Bootstrap all four districts in host-managed and dedicated placements.

Acceptance: four district records and obstacle bodies restore transactionally,
the support-body count is singular, and no collision/presentation perimeter is
introduced.

### S15-D — Cross-axis navigation and authored activity

- Author four reciprocal graph fragments with a complete block circuit.
- Grow planner route/search storage to the exact 32-node graph.
- Add eight north-row semantic destinations, four activity sites, eight
  activity slots, and eight spawn slots.
- Revise the twelve-member programs/placement so ordinary activity crosses
  both X and Z seams.

Acceptance: catalog preflight proves every route edge and population pose;
live NPCs travel to north-row activity and retain S12 recovery semantics.

### S15-E — Product presentation and diagnostics

- Expand deterministic road, sidewalk, plaza, and landmark composition across
  the 2×2 block.
- Expose four exact streaming slots through existing developer panels and
  incident state.
- Publish all four installed district identities in the bounded client
  baseline and draw their collision proxies in network clients.
- Keep `full_world` NPC publication and existing anomaly capture semantics.

Acceptance: ordinary Metal play has no district/NPC distance pop, all four
districts are distinguishable, and route/stream evidence aligns with wall
time, tick, and frame.

### S15-F — Measurement, acceptance, and cleanup

- Add focused four-district contract/content/navigation/population tests.
- Add a headless four-district traversal/replay proof and installed Metal
  journey at two presentation rates.
- Record cook sizes, residency peaks, fixed-tick cost, route-search work, draw
  count, and process memory in an S15 baseline.
- Run inherited S12/S13/S14, listen/dedicated, incident, replay, package, and
  editor-on/off gates.
- Audit dead two-district constants, doc drift, source packaging, and teardown.

Acceptance: the S15 validation ledger is complete, no actionable P0/P1/P2
finding remains, and the human walkthrough is ready.

## Stop/Review Triggers

Stop and review instead of hiding a problem if:

- a valid route needs more than the admitted 32-node storage;
- obstacle geometry cannot be represented without a walkable polygon model;
- a pedestrian requires teleportation or snap-back to recover;
- four pinned scenes exceed existing measured GPU/resource ownership;
- the single content worker causes repeatable product-visible admission lag;
- local NPC congestion, not path topology, prevents progress; or
- support needs ramps, stairs, bridges, interiors, or multiple vertical layers.

Those are evidence for a follow-up decision. They are not authorization to add
a navmesh, crowd solver, larger registry, or generic terrain system inside
S15.

## Human Walkthrough

1. Run `zig build run -Deditor=true`.
2. Walk and drive a full circuit through all four districts.
3. Verify south and north rows have distinct landmarks and no hidden perimeter.
4. Observe residents, workers, and visitors using north-row activity sites.
5. Push an NPC off its route, then confirm it retains its destination and
   replans without disappearing or snapping back.
6. Enter/exit the vehicle, carry/drop the object, fight an NPC, use the handgun,
   and observe death/replacement across district seams.
7. Inspect Navigation Lab, Population Lab, diagnostics, and the four streaming
   slots; flag any anomaly and provide the incident folder.
