# EA3 — Authored lighting implementation and validation

Implemented 2026-09-13/14 under ADR-029 and ADR-030. EA3 delivers direct lighting
and authoring for the industrial game. Human art/lighting tuning remains open;
this ledger does not claim product-owner visual acceptance.

## Run and author

From the repository root:

```sh
INCINERATOR_LIGHTING_ROOT="$PWD/game/industrial" \
zig build run -Deditor=true -Doptimize=ReleaseSafe -- \
  --editor-panels=lighting_lab,world_outliner,content_browser \
  --editor-focus=lighting_lab
```

The initial preset is Dusk. In Lighting Lab, select Day, Dusk or Night and click
**Activate Preset**. The shop is west of the vehicle lineup: the OPEN neon sign
and CORNER MART sign identify it. Street lights, a courtyard lamp, an externally
lit SERVICE sign and the shop's overhead fixtures exercise different emitters.
Night and Dusk enable both headlights on each existing vehicle. The carryable
has a portable lamp rig. Space remains the vehicle handbrake; vehicle tuning and
controls are unchanged by EA3.

Numeric edits preview immediately. **Apply** updates session state; **Clear
Preview** removes the preview. **Undo**, **Redo** and **Revert** operate through
the same revisioned owner. **Commit Asset** writes the selected session value
and active preset atomically to `game/industrial/lighting.iclight`. The panel
shows installed content and commit destination. Without the explicit environment
variable, session authoring works and durable commit is disabled. A restart with
that project root reads the committed library; `zig build` installs it for runs
that use only installed content.

In Free Camera (F3), select a static lighting asset in the outliner or Content
Browser. Its bounded X/Y/Z handles preview emitter translation. Release keeps
the draft; Apply commits it. Escape restores the drag-start draft. Mounted rigs
expose local values instead of moving the vehicle. Editing a static emitter's
position does not relocate its cooked pole/sign building geometry; general
placed-asset editing is EA4. Sun controls expose its emitted direction.

Useful units:

| Value | Meaning |
| --- | --- |
| Directional intensity | Lux |
| Point/spot intensity | Candela; inverse-square distance response |
| Range | Smooth authored cutoff in metres; `null` is unbounded |
| Spot angles | Cone half-angles; degrees in the panel, radians in the asset/CLI |
| Source radius | Near-source intensity regularization, not an area-light model |
| Exposure | Linear multiplier applied once before HDR storage |
| Bloom | Image halo only; it does not illuminate geometry |
| Surface/lens emission | Independent multiplier on the visible emissive material |
| Shadow bias | Normalized projected depth; default 0.00002 |

The field descriptions also appear in `incinerator-dev agent catalog`. Begin an
agent workflow with `incinerator-dev agent bootstrap`, then the catalog. Discover
the current lighting targets/revisions, inspect, submit the typed operation, and
re-inspect its terminal result. The CLI remains the only agent-control product.

## Implementation and ownership

- Engine contracts define directional/point/spot lights, rigid poses,
  environment and display settings without SDL, physics or authoring state.
- `lighting.iclight` contains game fixture identities, placements, presets,
  parent rules, mesh/material emission bindings and revisions. Its ICLIGHTS v1
  envelope validates size and SHA-256. Cooked dependencies and vehicle mounts
  are validated at startup and relocation.
- One host-neutral lighting owner handles preview ownership, stale revisions,
  apply/history and commit. The disk/CLI adapter owns the explicit project root.
  Lighting Lab submits the same typed requests and never mutates the renderer.
- Presentation resolves headlights from the exact interpolated chassis used by
  the color draw. The carryable uses the exact presented prop pose. Parent
  generations participate in instance identity. Static surface-bound lights
  contribute only with their submitted cooked surface, including retained
  visual districts; losing logical authority interest alone does not remove them.
- The renderer collects immutable product draws. Shadows and color consume
  those same meshes, materials and transforms. Off-camera opaque casters remain
  eligible. Vertex-color product geometry receives lighting; debug/HUD paths
  retain their declared display-space behavior.
- Editor-disabled solo consumes installed lighting without a mutable editor
  owner. Graphical network clients load/validate the same library and attach
  moving rigs to replicated presentation. Their pre-existing district-proxy
  renderer still does not draw the full cooked shop/sign street; a missing
  surface therefore has no corresponding surface-bound light. Client world
  presentation parity is a separate existing integration need, not a second
  lighting system. Dedicated authority owns no GPU lighting state.

The fixture art is original generated geometry/pixel lettering. The shop has an
actual shallow interior, opening, window-frame solids, ceiling and counter.
Neon and backlit signs combine emission with explicit local illumination;
the SERVICE sign receives an external spotlight. The long driving road and
the accepted FWD/RWD/AWD handling definitions are preserved.

## Renderer choices and measured cost

The pinned SDL/Metal path uses queried RGBA16F scene targets, manual
pre-exposure, Reinhard mapping then sRGB exactly once, and a reduced-resolution
bloom pyramid. Material Lab uses the same response in an independent neutral
environment. Product captures use the same display resolve without requiring
a swapchain. Editor/UI composition follows the product display transform.

Growable fragment-storage arrays have tested 64-byte light and 80-byte shadow
records and explicit generated MSL bindings. D32 depth arrays store a view for
sun/ordinary spots and six views for points/hemispherical spots, with 3×3 PCF.
The sun fits submitted resident casters in a world-anchored projection. There
is no silent nearest-N truncation. The pinned SDL depth attachment's Uint8
layer-address limit is reported as an explicit backend error if exceeded.

On an Apple M2 Max, ReleaseSafe, hidden 1600×900 product rendering with incident
capture and Metal validation enabled, 60 serial completed-frame samples per
preset measured:

| Preset | Mean ms | p50 ms | p95 ms | Active lights | Shadow views | Caster draws | Color draws |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Day | 8.90 | 8.90 | 9.51 | 4 | 19 | 642 | 459 |
| Dusk | 11.51 | 11.06 | 13.65 | 22 | 47 | 1018 | 465 |
| Night | 10.90 | 10.60 | 13.30 | 22 | 47 | 1018 | 465 |

Each sample includes CPU frame work and waits for GPU completion; this is not a
GPU-only timestamp or a general frame-rate guarantee. Authority stays fixed
during the preset samples. A separate earlier 12-frame batched submission run,
waiting at batch boundaries, measured 6.0/7.5/7.3 ms respectively; its overlap
is why those numbers differ. Debug builds are substantially slower and are not
the handling/lighting performance baseline.

The retained shadow allocation is 197,132,288 bytes (47×1024²×4), including
capacity retained when Day uses fewer views. HDR plus the allocated bloom
pyramid uses 15,358,848 bytes. These are allocation sizes, not whole-process GPU
memory. The global forward light loop and per-frame shadow redraw remain the
simple baseline. Per-draw/clustered lists and caching require a measured need;
this scene does not justify introducing them yet. SDL does not currently expose
per-pass GPU timestamps through this integration.

## Repeatable verification

```sh
# Routine complete EA3 check: hidden windows, no focus stealing.
zig build verify-ea3 -Deditor=true

# Individual checks when iterating.
zig build test-lighting-authoring
zig build test-lighting-render -Deditor=true
zig build test-lighting-cli -Deditor=true
zig build test-lighting-world -Deditor=true

# Optimized native measurement and captured reconstruction.
zig build test-lighting-world -Deditor=true -Doptimize=ReleaseSafe -Dincident-capture=true

# Integration boundaries and installed relocation.
zig build test smoke-installed-content check-mp2 -Deditor=true
zig build check-validation verify-headless-boundary verify-headless-linkage -Deditor=false
```

The combined aggregate/integration pass completed **439/439 build steps and
1,348/1,348 tests**, including the real automated CLI journey. The final
oversized-record repair also passed the 1,329-test unit/native/CLI combination
and strict inspection/replay of its newly captured evidence. Native acceptance proves:

- Linear HDR values above one, single exposure, matching offscreen display
  transform, bloom on/off, exposure-independent overlays, neutral material preview.
- Inverse-square/range/cone response against CPU reference values on both mesh
  formats; point cube faces, both sides of a cube-face boundary, hemispherical
  spots, directional shadows and an off-camera blocker.
- Day/Dusk/Night installed content, static-fixture selection and full emission
  references. Filling the actual shop opening reduced exterior direct-light
  probe energy from 6751.496 to 452.359 (6.7% residual from the broad sampling
  region and filtered edges); changing ambient/bloom cannot pass that isolated test.
- A normal player-admitted drive and steering journey travelled over 57 m, with
  360 comparisons of headlight parents/emitter poses against fractional-tick
  chassis draws. The window remained hidden and did not acquire keyboard focus.
- Native SDL handle ownership, Escape restoration, focus-loss cleanup, plus
  deterministic editor routing/gizmo tests.
- Real CLI bootstrap/catalog/list/inspect, preview/clear, apply, stale rejection,
  undo/redo/revert, preset activation and durable commit. The isolated native host
  reloads every committed value from disk before exiting; assets, diagnostics and
  discovery all live under a temporary test root.
- Pure owner tests cover rejected persistence, producer-owned previews, corrupt
  payloads, exact save/restart and unchanged state on rejected requests. Installed
  relocation validates lighting references against the actual world/vehicle catalogs.

Native images are generated as `zig-out/ea3-street-{Day,Dusk,Night}.ppm`,
`ea3-neighborhood.ppm`, `ea3-headlights.ppm` and `ea3-driving-night.ppm`.
The world test writes a fresh incident under `zig-out/lighting-runs/` and
preserves captured lighting libraries there. The CLI test records its native
output at `zig-out/ea3-cli-acceptance.log`.

## Evidence and coordinated breaking changes

EA3 advances incident schema to **6**, conventional visual schema to **3**,
developer protocol and agent contract to **6**, and industrial recipe to **11**.
The lighting asset/evidence schema is **1**. Headless logical content hashes and
replay fixture fingerprints were regenerated from recipe 11 and cooked bundles.
Network authority/snapshot/vehicle handling semantics are unchanged.

Schema-6 incidents record effective lighting frames, resolved emitter/parent
poses, inclusion reasons, shadow counts, emission bindings and typed changes.
Every presented library change, including preview, has an immutable
SHA-256-addressed `lighting-assets/*.iclight` snapshot. Complete lighting edits that
exceed the old 4 KiB inline telemetry slot transfer an exact owned payload to
the writer, preserving full before/candidate/after records. Empty unflagged
runs initialize their anomaly index so absence is not mistaken for corruption. The native test reconstructs
the exact live edit at its recorded tick/frame and proves that the lighting edit
did not change accepted authority ingress. It also attaches the normal
accepted-ingress replay for independent semantic verification.

The strict inspector and repository diagnostics summarizer accepted the new
run with all 50 typed lighting changes, zero drops, zero writer failures and
zero warnings. Independent
accepted-ingress replay verified 613 ticks. Use those tools against each new run.
Earlier incident schemas are not silently upgraded. Graphical re-execution
loads captured lighting state; missing/corrupt lighting evidence is an error.
It still requires matching installed geometry/materials and remains best effort
for SDL cadence, worker timing and GPU scheduling. Lighting-state reconstruction,
authority replay and pixel/perceptual confirmation are separate claims.

## Visual review and next boundary

Review street-pool softness, neon/store-sign readability, interior/exterior
contrast, headlight aim and sun-shadow stability while driving. Night's ambient
fill intentionally keeps car bodies readable. All these values can be tuned
live and committed without rebuilding physics or changing handling.

EA4 owns general map placement/construction. Global illumination, reflection
probes, automatic exposure, advanced glass, volumetric beams, player-controlled
light switches, weather and continuous time-of-day gameplay are not EA3 features.
