# EA1-A Practical Textures and Runtime Materials Validation

**Status:** Implementation, architecture/dead-code review, automated validation,
filtered-source packaging, installed-product, and native Metal acceptance
candidate complete on 2026-08-30; product-owner visual/usability review pending

**Plan:**
[Engine Authoring Foundation](../design/engine-authoring-foundation.md)

**Decision:**
[ADR-029](../adr/029-engine-game-authoring-boundary.md)

## Scope Boundary

EA1-A is the import, cooked identity, runtime material, read-only inspection,
and agent-discovery slice. It does not implement metallic/roughness, normal,
occlusion, or emissive inputs. It also does not implement material preview,
live assignment, revert, or durable material commit; those remain EA1-B and
require separate authorization after this human checkpoint.

External glTF dependencies in this measured slice are PNG/JPEG images. GLB BIN
chunks and data-URI buffers are supported; external `.bin` buffer files fail
explicitly as unsupported instead of being discovered by the runtime or
silently ignored.

## Acceptance Ledger

| Gate | Status | Evidence |
|---|---|---|
| Project-owned source assets | Complete | `game/assets/urban_building` supplies a GLB-packed building/environment with embedded PNG; `game/assets/cargo_crate` supplies glTF with a rooted external JPEG. Both have project provenance and no external source material or license grant |
| Safe import | Complete | Offline cooker admits `.gltf`/`.glb`, embedded/external PNG/JPEG, UV0, optional base-color texture, base-color factor, image encoding, color space, and glTF sampler state; absolute/traversal/query/fragment dependency URIs and undeclared dependencies reject |
| Deterministic cooking | Complete | Repeated catalog and four-bundle cooks are byte-identical; image dependency bytes participate in the source digest; installed cohort and exact hashes are frozen in headless manifests |
| Stable identity | Complete | Scene, mesh, material, and texture `AssetId` values derive from game namespace plus semantic bundle/name, never source path, revision digest, GPU handle, or world entity identity |
| Typed catalog | Complete | Read-only entries expose owner, revision, digest, dependency IDs, source container, cook status, residency/last use, material binding, and texture dimensions/encoding/color space/sampler |
| Runtime material | Complete | Cooked sRGB/linear format and min/mag/address state reach renderer-owned textures and per-texture SDL GPU samplers; sampler and texture lifetimes share the renderer registry |
| Real product pressure | Complete | Southwest cooked content uses the 128×128 PNG `UrbanBrickFacade`; southeast uses the 128×128 JPEG `CargoCratePanels`; both authored landmark meshes have non-degenerate UV0 coverage and neutral texture factors, and the resident cargo texture also renders the live physics crate without source-file loading |
| Content Browser | Complete for EA1-A | Search plus kind/owner/cook filters, bundle grouping, separate asset selection, automatic Inspector opening, and typed read-only details are present. Thumbnails/previews remain EA1-B |
| CLI parity | Complete | Protocol cohort 2 and agent-contract revision 2 return the same durable content identities and typed fields through `content list`, asset `inspect`, and content selection; selecting content never replaces world selection |
| Runtime boundary | Complete | `zmesh`, `zstbi`, source URI resolution, and glTF parsing remain host-cooker-only. Editor-disabled, validation, headless, and installed runtime graphs consume cooked bytes only |
| Source package | Complete | Filtered archive contains the new source assets, provenance, cooker/packer, contracts, and tests; extracted execution passes |
| Automated/native | Complete | Focused content/editor/GPU/CLI tests, editor-on/off aggregates, and the inherited installed/native Metal matrix pass as recorded below |
| Product-owner review | Pending | Confirm texture appearance, Content Browser/Inspector usability, asset/world selection distinction, and CLI discovery using the checklist below |

## Measured Content Pressure

The accepted sources are ordinary 128×128 RGB images rather than the historical
fixture pixels:

- `facade.png`: 23,679 source bytes, decoded to 65,536 RGBA8 bytes;
- `panels.jpg`: 6,146 source bytes, decoded to 65,536 RGBA8 bytes;
- southwest GLB-backed cooked bundle: 70,016 bytes;
- southeast glTF/JPEG cooked bundle: 70,008 bytes;
- northwest/northeast unchanged bundles: 4,396 / 4,392 bytes; and
- catalog: 824 bytes.

The resulting measured admission bounds are 512 KiB for a glTF/GLB source, 4
MiB per encoded image source, 256 KiB per cooked district bundle, and 128 KiB
of decoded texture pixels per bundle. They are explicit conformance limits for
this cohort, not a promise that future content will fit them. A future asset
that exceeds a measured bound must produce a repeatable failure and new
pressure evidence before the bound changes.

## Frozen Cooked Cohort

```text
content cohort eb0d4dd0b3f4b7e01d5009e2b888c4f14e61c5cd5197cfdc399a5c3afcae1f6f
catalog        116fb4e45ee7fe634de26a88fb78040f8cf8354214ecf5a1c19b4b87a2e7efc6
southwest      b26ef2bd3da15b02459b2efd8f49aff4abab4b44fdf223715ef5e970f0049da4
southeast      3ed2d4a5b69f668aadd85a04f4e4bfbea005e1db8bae6e5a407ca913a178de8c
northwest      472db8122c7f45dfd5ec191c29fb47b3b3f5c803a60b4d9dec42f0645f6ec3ad
northeast      845baf61116a7424b936a9e2f5154633e65c96dd0aa14f0a19c813e88a2f402a
```

The urban texture is PNG, sRGB, linearly filtered, and mirrored-repeat. The
cargo texture is JPEG, sRGB, nearest-filtered, and clamp-to-edge. Cook
verification asserts those exact values and that their materials depend on the
expected stable texture identities. It also rejects a project texture if every
bound surface collapses either UV axis or if the source material factor hides
the authored image behind a tint.

## Native Visibility Correction

The first candidate incorrectly treated successful texture residency and draw
submission as proof that brick detail was visible. Product review found no
recognizable brick wall. A repeatable CLI camera capture isolated the actual
source defect: all 24 landmark UV coordinates were `(0,0)`, so every wall
sampled one texel; the brick material factor then darkened that texel further.

Both project landmark meshes now have ordinary per-face `0..1` UV coverage and
their textured material factors are neutral white. The cooked-content verifier
now rejects collapsed UV spans and non-neutral factors for these project
textures. This catches the concrete failure before GPU acceptance rather than
inferring visibility from residency counters.

The installed native Metal product was then controlled through the canonical
CLI in run `1788134193356:1788134193356282000`:

```sh
./zig-out/bin/incinerator-dev agent bootstrap
./zig-out/bin/incinerator-dev agent catalog
./zig-out/bin/incinerator-dev camera mode free-camera
./zig-out/bin/incinerator-dev camera pose \
  --x 1.5 --y 1.5 --z 8.0 --yaw 0 --pitch 0
./zig-out/bin/incinerator-dev capture-frame
./zig-out/bin/incinerator-dev capture inspect --id 1
```

Capture 1 completed at authority tick 346 / presentation frame 572. Direct
inspection of its product-only frame confirms recognizable brick courses,
windows, and lintels on the southwest depot; the low southwest block also
shows the same facade image rather than a flat sampled texel. Correlated
evidence is under
`2026-08-30T23-56-33.494Z_solo_88616272/anomalies/anomaly-0001` in the local
Incinerator run log.

## Automated Results

All commands ran from the repository root on 2026-08-30:

```sh
zig build test-content test-content-cooker test-district-content-catalog
zig build test-district-scene-adapter test-district-gpu-registry
zig build test-district-streaming-host test-editor-workspace
zig build test-developer-endpoint test-incinerator-dev -Deditor=true --summary all
```

Result: all focused cooker, format, catalog, residency, sampler, editor
selection, installed-content endpoint, and CLI parity tests pass.

```sh
zig build verify-source-package --summary all
```

Result: 2/2 steps pass. The extracted filtered source package also completes
193/193 headless steps with 442/442 tests and 32/32 default steps with 54/54
tests.

```sh
zig build test -Deditor=true --summary all
```

Result: 320/320 steps and 1,256/1,256 tests pass.

```sh
zig build test -Deditor=false --summary all
```

Result: 315/315 steps and 1,112/1,114 tests pass with the two designed
editor-disabled skips.

```sh
zig build verify-s15 -Deditor=true --summary all
```

Result: complete inherited four-district, navigation, population, replay,
incident, installed-product, two-rate Metal, source-package, and validation
matrix passes with the EA1-A cooked cohort: 310/310 steps and 406/406 tests.
The 240 Hz and 80/40 Hz installed Metal runs each load the two new textured
districts with two textures apiece and report 141,184 resident GPU bytes across
the four-scene cohort.

`git diff --check`, formatting, ownership checks, and documentation validation
also pass.

## Product-Owner Manual Checklist

Build and launch the installed editor product:

```sh
zig build install -Deditor=true
./zig-out/bin/incinerator_engine
```

1. Confirm the four-district world still renders and navigation/gameplay remain
   usable. Look specifically for the textured brick/depot environment in the
   southwest and painted cargo surfaces in the southeast.
   For a repeatable depot view, switch to Free Camera and use the exact CLI
   camera pose recorded in `Native Visibility Correction` above.
2. Select the live crate. Confirm it uses the painted cargo texture but remains
   a runtime world instance in World Outliner, with the existing transform
   gizmo and authoring behavior unchanged.
3. Open `Panels` → `Content Browser` if it is not already visible. Search for
   `UrbanBrickFacade` and `CargoCratePanels`.
4. Exercise the kind, owner, and cook-state filters. The two textures should be
   game-owned, valid, and grouped under their cooked district bundles.
5. Select each texture. Inspector should open automatically and show stable
   asset ID, owner, revision, source container, digest, dependencies,
   residency/last-use, 128×128 dimensions, PNG/JPEG encoding, sRGB, and the
   expected sampler state.
6. Select a material and confirm its stable dependency points to its base-color
   texture. Select the live crate again and confirm world selection and content
   selection remain visibly separate rather than replacing one another.
7. In a second shell, follow the first-class agent path:

   ```sh
   ./zig-out/bin/incinerator-dev agent bootstrap
   ./zig-out/bin/incinerator-dev --expected-run "$expected_run" content list
   ./zig-out/bin/incinerator-dev --expected-run "$expected_run" inspect --target content-asset:N:L
   ./zig-out/bin/incinerator-dev --expected-run "$expected_run" select --target content-asset:N:L
   ```

   Set `expected_run` to the token returned by this bootstrap (agent contract 3).
   Copy `N:L` from `content list`; do not guess it. Confirm the CLI fields agree
   with Inspector and that selecting an asset does not deselect the live crate.
8. Restart the installed product from outside the repository working directory
   if desired. The textures must still render from installed cooked content;
   moving or omitting the source `.gltf`, `.png`, or `.jpg` files must never be
   necessary at runtime.

Report visual stretching, incorrect filtering, unclear asset-versus-instance
selection, missing residency/last-use, CLI/UI field disagreement, or any source
path dependency. Acceptance of this checklist closes EA1-A and is the gate for
separately authorizing EA1-B.
