# ADR-006: Physics Debug Rendering Architecture

## Status
Accepted

## Context

Debugging physics simulations requires visualizing collision shapes, bounding boxes, velocities, and other physics state. Jolt Physics provides a `DebugRenderer` interface that calls back into user code with geometry to draw.

The challenge: Jolt's callback interface uses different conventions (column-major matrices, column-vector math) than our rendering pipeline (row-major matrices, row-vector math via zmath). Additionally, Jolt's batch system creates geometry once per shape type and reuses it across frames.

## Decision

We implement Jolt's `DebugRenderer` VTable interface with CPU-side vertex transformation and immediate-mode rendering through our existing GPU pipeline.

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Physics Debug Rendering                          │
│                                                                      │
│  ┌──────────────┐    ┌──────────────────┐    ┌─────────────────┐   │
│  │ Jolt Physics │───▶│ PhysicsDebugRenderer │───▶│ GPU Pipeline    │   │
│  │ drawBodies() │    │ (VTable callbacks)    │    │ (lines/tris)   │   │
│  └──────────────┘    └──────────────────┘    └─────────────────┘   │
│                              │                                       │
│                              ▼                                       │
│                      ┌──────────────────┐                           │
│                      │   RendererData   │                           │
│                      │ - line_vertices  │                           │
│                      │ - tri_vertices   │                           │
│                      │ - primitives[64] │                           │
│                      └──────────────────┘                           │
└─────────────────────────────────────────────────────────────────────┘
```

### VTable Implementation

The `PhysicsDebugRenderer` is an `extern struct` (for C ABI compatibility) that implements Jolt's callback interface:

```zig
pub const PhysicsDebugRenderer = extern struct {
    vtable: *const zphysics.DebugRenderer.VTable(PhysicsDebugRenderer),
    renderer_data: ?*RendererData,
    settings: DebugDrawSettings,

    // VTable callbacks:
    // - drawLine(): Buffer line vertices directly
    // - drawTriangle(): Buffer triangle vertices directly
    // - createTriangleBatch(): Store shape geometry for reuse
    // - drawGeometry(): Transform stored geometry and buffer
};
```

### Geometry Batch System

Jolt creates shape geometry once per unique shape type (box, sphere, capsule, etc.) via `createTriangleBatch()`. We store this in a `RenderPrimitive`:

```zig
const RenderPrimitive = struct {
    vertices: ?[]Vertex = null,
    allocator: ?std.mem.Allocator = null,
};
```

When `drawGeometry()` is called each frame, we:
1. Retrieve the stored vertices from the batch
2. Transform each vertex by the body's model matrix
3. Buffer the transformed vertices for rendering

### Matrix Convention Conversion

Jolt uses column-major matrices with column-vector math (`M * v`).
zmath uses row-major matrices with row-vector math (`v * M`).

For equivalent transforms, we transpose Jolt's matrix by copying columns as rows:

```zig
fn rmatrixToZmMat(m: *const zphysics.RMatrix) zm.Mat {
    // zmath row i = Jolt column i (transpose)
    return zm.Mat{
        .{ m.column_0[0], m.column_0[1], m.column_0[2], 0 },
        .{ m.column_1[0], m.column_1[1], m.column_1[2], 0 },
        .{ m.column_2[0], m.column_2[1], m.column_2[2], 0 },
        .{ m.column_3[0], m.column_3[1], m.column_3[2], 1 },
    };
}
```

### Rendering Pipeline Integration

Debug geometry uses the same shaders as regular meshes but bypasses the mesh system:

1. **Frame start**: Clear vertex buffers
2. **Physics step**: Call `physics_world.drawBodies()` which invokes our VTable
3. **VTable callbacks**: Buffer vertices into `line_vertices` / `triangle_vertices`
4. **Render**: Upload buffers to GPU and draw with `SDL_GPU_PRIMITIVETYPE_LINELIST`

### Configurable Visualization

`DebugDrawSettings` controls what gets rendered:

```zig
pub const DebugDrawSettings = extern struct {
    enabled: bool,           // Master toggle
    draw_shapes: bool,       // Collision shape wireframes
    wireframe: bool,         // Wireframe vs solid
    draw_bounding_boxes: bool,  // AABBs
    draw_velocity: bool,     // Velocity vectors
    draw_center_of_mass: bool,  // CoM axes
    draw_world_transform: bool, // World transform axes
};
```

The editor UI exposes these toggles via the Physics tool panel.

## Rationale

### Why CPU Transform vs GPU Instancing?

We transform vertices on CPU rather than using GPU instancing because:
- Debug rendering is not performance-critical
- Simpler implementation (no instance buffer management)
- Works with existing immediate-mode upload pattern
- Shape vertex counts are small (box = 36 verts, sphere = ~200)

### Why Separate from ECS Rendering?

Physics debug draws directly from Jolt's internal state, not ECS:
- No sync delay - shows exact physics state this frame
- Draws shapes that may not have ECS entities (static world geometry)
- Different color coding (body state: static/dynamic/kinematic)

### Why 64-Slot Primitive Pool?

Jolt creates batches once per unique shape type. A typical game has few unique shapes (box, sphere, capsule, convex hull per asset). 64 slots with circular reuse handles this efficiently without dynamic allocation per batch.

### Why extern struct for PhysicsDebugRenderer?

The VTable pointer must be the first field for C ABI compatibility with Jolt's callback system. `extern struct` guarantees field layout matches C expectations.

## Consequences

### Positive
- Visual debugging of collision shapes, AABBs, velocities
- Perfect alignment between debug wireframes and rendered meshes (after rotation fixes)
- Minimal integration with existing render pipeline
- Editor UI controls for toggling visualization layers

### Negative
- CPU transform overhead (acceptable for debug builds)
- Memory for storing batch geometry persists across frames
- Additional draw calls for debug geometry

### Implementation Notes

**Rotation alignment issues encountered:**
1. `quaternionToEuler()` axis mapping was incorrect (Y/Z swapped)
2. `Rotation.toMatrix()` used wrong Euler order (YXZ vs XYZ)
3. `rmatrixToZmMat()` initially extracted rows instead of transposing

All three must be consistent for wireframes to align with rendered meshes.

## File Structure

```
src/
├── physics_debug.zig    # PhysicsDebugRenderer, RendererData, VTable impl
├── physics.zig          # Physics wrapper (calls drawBodies)
└── editor/tools/
    └── physics_tool.zig # UI for DebugDrawSettings
```

## References

- [Jolt Physics DebugRenderer](https://jrouwe.github.io/JoltPhysics/)
- [zphysics bindings](https://github.com/zig-gamedev/zphysics)
- ADR-004: ECS Architecture
- ADR-005: Physics-ECS Integration
