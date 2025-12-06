# ADR-004: Entity Component System Architecture

**Status:** Accepted
**Date:** 2025-12-06
**Decision Makers:** Matt, Claude

## Context

Incinerator Engine is targeting a GTA III-style open world with:
- Hundreds of vehicles on screen simultaneously
- Thousands of physics-enabled debris from explosions
- NPCs, props, and environmental objects
- Dynamic spawning/despawning as players move through the world

Traditional object-oriented hierarchies (e.g., `Vehicle extends Entity`) become problematic at scale:
- **Deep inheritance chains** make it hard to compose behaviors
- **Cache misses** from scattered memory layout kill performance
- **Rigid hierarchies** make it difficult to add/remove capabilities dynamically

We need an architecture that handles 10,000+ entities with good cache utilization.

## Decision

### Framework: flecs via zflecs

We use **flecs** (a high-performance C ECS library) through **zflecs** (Zig bindings from zig-gamedev):

```zig
// build.zig.zon
.zflecs = .{
    .url = "git+https://github.com/zig-gamedev/zflecs#...",
},
```

flecs was chosen over alternatives for its:
- Archetype storage (entities with same components stored contiguously)
- High-performance query system
- Battle-tested in production games
- Active development and excellent documentation

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         GameWorld                                │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                    flecs World                           │   │
│  │  ┌──────────────────────────────────────────────────┐   │   │
│  │  │              Archetype Tables                     │   │   │
│  │  │  ┌────────────────────────────────────────────┐  │   │   │
│  │  │  │ [Pos, Rot, Scale, Renderable] (3 entities) │  │   │   │
│  │  │  │  Entity 1: Cube                            │  │   │   │
│  │  │  │  Entity 2: Woman1                          │  │   │   │
│  │  │  │  Entity 3: Woman2                          │  │   │   │
│  │  │  └────────────────────────────────────────────┘  │   │   │
│  │  │  ┌────────────────────────────────────────────┐  │   │   │
│  │  │  │ [Pos, Rot, Scale, Renderable, Vehicle]     │  │   │   │
│  │  │  │  (future: cars with vehicle tag)           │  │   │   │
│  │  │  └────────────────────────────────────────────┘  │   │   │
│  │  └──────────────────────────────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### Component Design

Components are **pure data structs** with no behavior:

```zig
// Core transform components
pub const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

pub const Rotation = struct {
    x: f32 = 0,  // Euler angles (radians)
    y: f32 = 0,
    z: f32 = 0,
};

pub const Scale = struct {
    x: f32 = 1,
    y: f32 = 1,
    z: f32 = 1,
};

// Render component (references mesh data, doesn't own it)
pub const Renderable = struct {
    mesh: *mesh_module.Mesh,
};
```

**Design principles:**
- Components are small (24-48 bytes typically)
- No pointers to other entities (use flecs relationships instead)
- Helper methods allowed for conversions (e.g., `toVec()`, `toMatrix()`)
- The `Renderable` component stores a pointer, not owned data

### Tags for Categorization

Tags are **zero-size marker components** for filtering:

```zig
pub const Static = struct {};   // Won't move, can be optimized
pub const Vehicle = struct {};  // Is a driveable vehicle
pub const Debris = struct {};   // Explosion debris
```

### GameWorld Wrapper

`GameWorld` wraps the flecs world and provides a high-level API:

```zig
pub const GameWorld = struct {
    world: *flecs.world_t,
    renderable_query: *flecs.query_t,  // Cached query
    entity_count: i32 = 0,

    pub fn init() GameWorld { ... }
    pub fn deinit(self: *GameWorld) void { ... }

    // Spawning
    pub fn spawn(self: *GameWorld, opts: SpawnOptions) flecs.entity_t { ... }
    pub fn spawnRenderable(...) flecs.entity_t { ... }

    // Queries
    pub fn renderables(self: *GameWorld) RenderableIterator { ... }

    // Component access
    pub fn get(self: *GameWorld, entity: flecs.entity_t, comptime T: type) ?*const T { ... }
    pub fn getMut(self: *GameWorld, entity: flecs.entity_t, comptime T: type) ?*T { ... }
};
```

### Query System

Queries are created once and cached for performance:

```zig
// In GameWorld.init()
var query_desc = flecs.query_desc_t{};
query_desc.terms[0] = .{ .id = flecs.id(Position) };
query_desc.terms[1] = .{ .id = flecs.id(Rotation) };
query_desc.terms[2] = .{ .id = flecs.id(Scale) };
query_desc.terms[3] = .{ .id = flecs.id(Renderable) };

self.renderable_query = flecs.query_init(world, &query_desc);
```

### Iterator Pattern with Proper Cleanup

The `RenderableIterator` wraps flecs iteration with proper resource management:

```zig
pub const RenderableIterator = struct {
    iter: flecs.iter_t,
    finished: bool = false,  // Tracks natural exhaustion

    pub fn next(self: *RenderableIterator) ?RenderableEntity {
        // ... iteration logic ...
        if (!flecs.query_next(&self.iter)) {
            self.finished = true;  // Mark as naturally exhausted
            return null;
        }
        // ... return entity data ...
    }

    pub fn deinit(self: *RenderableIterator) void {
        // Only finalize if iteration was interrupted (break)
        // NOT if iterator was fully consumed (would assert)
        if (!self.finished) {
            flecs.iter_fini(&self.iter);
        }
    }
};
```

**Critical:** Always use `defer iter.deinit()` when iterating:

```zig
var iter = world.renderables();
defer iter.deinit();  // Handles both early-break and full consumption
while (iter.next()) |entity| {
    if (some_condition) break;  // Safe - deinit handles cleanup
}
```

### Entity Spawning

Entities are spawned with optional components:

```zig
const entity = world.spawnRenderable(
    "Cube",                        // Debug name
    .{ .x = 0, .y = 0, .z = 0 },  // Position
    .{ .x = 0, .y = 0, .z = 0 },  // Rotation
    .{ .x = 1, .y = 1, .z = 1 },  // Scale
    &cube_mesh,                    // Mesh pointer (must be stable!)
);
```

**Critical:** Mesh pointers must point to stable memory. Spawning must happen after the owning struct (e.g., `App`) is fully constructed:

```zig
pub fn main() !void {
    var app = try App.init();    // App owns meshes
    defer app.deinit();
    app.spawnEntities();          // NOW safe - app.cube_mesh has stable address
    app.run();
}
```

### Render Integration

The main render loop queries all renderables:

```zig
fn render(self: *App, alpha: f32) void {
    // ... setup ...

    var iter = self.game_world.renderables();
    defer iter.deinit();
    while (iter.next()) |entity| {
        const model_matrix = entity.getModelMatrix();
        const mvp = zm.mul(model_matrix, view_proj);
        self.gpu_renderer.drawMesh(entity.mesh, mvp);
    }
}
```

Each `RenderableEntity` computes its own model matrix:

```zig
pub fn getModelMatrix(self: RenderableEntity) zm.Mat {
    const translation = zm.translation(self.position.x, self.position.y, self.position.z);
    const rotation = self.rotation.toMatrix();
    const scl = self.scale.toMatrix();
    // Order: Scale → Rotate → Translate
    return zm.mul(zm.mul(scl, rotation), translation);
}
```

## Rationale

### Why ECS Over Traditional OOP?

| Aspect | OOP Hierarchy | ECS |
|--------|---------------|-----|
| **Memory Layout** | Objects scattered in heap | Components contiguous by archetype |
| **Cache Performance** | Poor - pointer chasing | Excellent - sequential access |
| **Flexibility** | Rigid inheritance | Add/remove components freely |
| **Scalability** | Degrades with entity count | Designed for 10K+ entities |
| **Composition** | Diamond inheritance problems | Natural composition |

### Why flecs?

| ECS Library | Pros | Cons |
|-------------|------|------|
| **flecs (chosen)** | Archetype storage; queries; relationships; mature | C library; some binding overhead |
| entt (C++) | Fast; popular | C++; no Zig bindings |
| zig-ecs | Native Zig | Less mature; fewer features |
| Bevy ECS (Rust) | Modern design | Rust; not embeddable |

flecs offers the best combination of performance, features, and C interoperability.

### Why Archetype Storage?

Archetype storage groups entities by their component signature:

```
Archetype [Position, Rotation, Scale, Renderable]:
  Position[]  = [pos1, pos2, pos3, ...]  // Contiguous
  Rotation[]  = [rot1, rot2, rot3, ...]  // Contiguous
  Scale[]     = [scl1, scl2, scl3, ...]  // Contiguous
  Renderable[] = [rnd1, rnd2, rnd3, ...]  // Contiguous
```

Benefits:
- **Cache-friendly iteration** - Components stored sequentially
- **Efficient queries** - Only iterate matching archetypes
- **Automatic SoA layout** - Structure-of-Arrays without manual management

### Why Cached Queries?

Creating a query is O(archetypes), but iterating a cached query is O(matching entities):

```zig
// BAD: Creates query every frame
for (entities) |e| {
    if (world.has(e, Position) and world.has(e, Renderable)) { ... }
}

// GOOD: Query created once, iteration is fast
var iter = world.renderables();  // Uses cached query
while (iter.next()) |entity| { ... }
```

### Why Track Iterator Exhaustion?

flecs iterators have specific cleanup requirements:
- **Fully consumed** (next returns false): Iterator auto-cleans, calling `iter_fini` would assert
- **Early break**: Must call `iter_fini` to prevent memory leak

The `finished` flag lets `deinit()` handle both cases safely.

## Consequences

### Positive

- **Performance** - Archetype storage enables cache-efficient iteration over thousands of entities
- **Flexibility** - Components can be added/removed at runtime
- **Scalability** - Architecture ready for GTA-scale worlds (vehicles, NPCs, debris)
- **Query Efficiency** - Cached queries make render loops fast
- **Industry Standard** - ECS is the modern game architecture pattern

### Negative

- **Learning Curve** - ECS thinking differs from OOP (data-oriented vs object-oriented)
- **C Dependency** - flecs is a C library, compiled separately
- **Indirection** - Component data accessed through queries, not direct object fields
- **Debugging** - Entity IDs less intuitive than object instances

### Neutral

- **Pointer Stability** - Mesh pointers must be stable; requires awareness but is solvable
- **Query Cost** - Initial query creation has overhead; amortized over many frames

## Future Work

### Systems (Not Yet Implemented)

flecs supports declarative systems that run automatically:

```zig
// Future: Physics system runs at fixed timestep
flecs.system(world, "PhysicsUpdate", .{
    .query = .{ Position, Velocity, RigidBody },
    .callback = physicsUpdate,
    .interval = 1.0 / 120.0,  // 120Hz
});
```

Currently we iterate manually; systems will be added when complexity warrants.

### Relationships

flecs supports entity relationships for hierarchies:

```zig
// Future: Wheel is child of Car
flecs.add_pair(world, wheel, flecs.ChildOf, car);

// Query all wheels of a specific car
var iter = flecs.query(world, .{ Wheel, .{ flecs.ChildOf, car } });
```

This enables car → wheel hierarchies, inventory systems, etc.

### Prefabs

flecs prefabs enable entity templates:

```zig
// Future: Vehicle prefab
const vehicle_prefab = flecs.prefab(world, "Vehicle", .{
    Position{},
    Rotation{},
    Scale{ .x = 1, .y = 1, .z = 1 },
    Vehicle{},
});

// Instantiate from prefab
const car = flecs.instantiate(world, vehicle_prefab);
```

## File Structure

```
src/
├── ecs.zig              # GameWorld, components, queries
├── main.zig             # Uses GameWorld for entity management
└── editor/
    └── tools/
        └── scene_tool.zig  # Iterates entities for UI
```

## References

- [flecs Documentation](https://www.flecs.dev/flecs/)
- [zflecs - Zig bindings](https://github.com/zig-gamedev/zflecs)
- [Data-Oriented Design](https://www.dataorienteddesign.com/dodbook/)
- [ADR-002: Module Architecture](./002-module-architecture-and-layering.md)
- [ADR-003: Editor Architecture](./003-editor-architecture.md)
