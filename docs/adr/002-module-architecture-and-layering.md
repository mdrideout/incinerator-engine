# ADR-002: Module Architecture and Layering

**Status:** Accepted
**Date:** 2025-12-05
**Decision Makers:** Matt, Claude

## Context

As the engine grows beyond a simple "hello triangle" demo, we need a clear organization for code. Without intentional structure, rendering code, game logic, and asset management tend to become tangled, making the codebase difficult to understand, modify, and extend.

We need to decide:
1. How to organize source files into logical modules
2. What responsibilities each module should have
3. How modules should communicate (dependencies)
4. How to balance simplicity against future scalability

## Decision

### Layered Architecture

We adopt a layered architecture where higher layers depend on lower layers, but not vice versa:

```
┌─────────────────────────────────────────────────────────────────┐
│                     APPLICATION LAYER                           │
│                       (main.zig)                                │
│         Orchestration, game loop, system wiring                 │
├─────────────────────────────────────────────────────────────────┤
│                       SCENE LAYER                               │
│                      (world.zig)                                │
│            Entities, transforms, scene management               │
├─────────────────────────────────────────────────────────────────┤
│                       ASSET LAYER                               │
│              (mesh.zig, primitives.zig)                         │
│          Geometry, textures, materials, loading                 │
├─────────────────────────────────────────────────────────────────┤
│                     RENDERING LAYER                             │
│                    (renderer.zig)                               │
│           GPU device, pipelines, shaders, draw calls            │
├─────────────────────────────────────────────────────────────────┤
│                      PLATFORM LAYER                             │
│               (sdl.zig, timing.zig, input.zig)                  │
│              OS abstraction, windowing, input                   │
└─────────────────────────────────────────────────────────────────┘
```

### Module Responsibilities

| Module | Domain | Responsibilities | Does NOT |
|--------|--------|------------------|----------|
| `main.zig` | Application | Game loop, init/shutdown, wiring systems | Game logic, rendering details |
| `world.zig` | Scene | Entity storage, transforms, iteration | Rendering, asset ownership |
| `mesh.zig` | Asset | Vertex format, GPU buffer management | Know what shapes exist |
| `primitives.zig` | Asset | Built-in shape factories (triangle, cube) | Track or cache meshes |
| `renderer.zig` | Rendering | GPU device, pipelines, draw operations | Know about entities |
| `timing.zig` | Platform | Frame timing, fixed timestep | Game state |
| `input.zig` | Platform | Event buffering, key/mouse state | Game actions |
| `sdl.zig` | Platform | Shared C bindings | Business logic |

### Dependency Rules

1. **Downward only:** Modules may only import from layers below them
2. **No cycles:** If A imports B, B cannot import A
3. **Platform is foundation:** All modules may use platform layer
4. **Renderer is low-level:** Only main.zig orchestrates renderer calls

```
main.zig ──imports──→ world.zig ──imports──→ mesh.zig
    │                     │
    └──imports──→ renderer.zig ──imports──→ mesh.zig (for Vertex type)
    │                     │
    └──imports──→ primitives.zig ──imports──→ mesh.zig
```

### Current File Structure

```
src/
├── main.zig           Application layer - entry point, game loop
├── renderer.zig       Rendering layer - GPU abstraction
├── mesh.zig           Asset layer - geometry types
├── primitives.zig     Asset layer - built-in shapes
├── world.zig          Scene layer - entity management
├── timing.zig         Platform layer - frame timing
├── input.zig          Platform layer - input handling
└── sdl.zig            Platform layer - SDL3 bindings
```

## Rationale

### Why Layered Architecture?

1. **Predictable dependencies:** Easy to understand what each module can access
2. **Testability:** Lower layers can be tested in isolation
3. **Flexibility:** Can swap implementations (e.g., different renderer) without touching higher layers
4. **Onboarding:** New developers can understand scope of each file quickly

### Why Not ECS (Entity Component System)?

ECS is a more advanced pattern used by engines like Bevy, Unity DOTS, and Flecs. We chose not to use it initially because:

1. **Premature optimization:** We don't yet have the entity counts that benefit from ECS cache efficiency
2. **Learning curve:** ECS requires understanding archetypes, queries, and systems
3. **Simplicity first:** A simple entity array is easier to debug and reason about

**Future:** We may migrate to ECS when:
- Entity counts exceed ~1000
- We need complex component queries
- We want parallelizable systems

### Why Separate mesh.zig and primitives.zig?

- `mesh.zig` defines the Mesh type and vertex format (data structure)
- `primitives.zig` contains actual vertex data for shapes (data instances)

This separation means:
- Adding new primitives doesn't touch the Mesh type
- mesh.zig can be used for loaded meshes (OBJ, glTF) without primitive baggage
- Clear distinction between "what a mesh is" vs "built-in meshes"

### Why renderer.zig Doesn't Know About Entities?

The renderer is intentionally "dumb" - it only knows how to draw a Mesh at a position. Benefits:

1. **Reusability:** Same renderer works for game entities, UI, debug visualization
2. **No coupling:** Changing entity structure doesn't require renderer changes
3. **Testing:** Can test renderer with mock meshes, no world needed

## Consequences

### Positive

- **Clear ownership:** Each module has explicit responsibilities
- **Minimal coupling:** Changes in one module rarely affect others
- **Readable code:** Following imports tells you the dependency story
- **Extensible:** Easy to add new modules at appropriate layer

### Negative

- **Boilerplate:** Some ceremony in passing data between layers
- **Indirection:** Must trace through multiple files to understand full flow
- **Discipline required:** Easy to break layering rules without enforcement

### Neutral

- Future game logic will need a `game.zig` module at the Application layer
- Materials/textures will extend the Asset layer
- Physics will likely be a peer to the Scene layer

## Future Modules (Planned)

```
src/
├── game.zig           Application - game-specific logic (future)
├── transform.zig      Scene - math types, Mat4, Vec3 (future, or use zmath)
├── material.zig       Asset - shader parameters, textures (future)
├── camera.zig         Scene - view/projection matrices (future)
└── physics.zig        Simulation - Jolt integration (future)
```

## References

- [Game Programming Patterns - Component](https://gameprogrammingpatterns.com/component.html)
- [Clean Architecture](https://blog.cleancoder.com/uncle-bob/2012/08/13/the-clean-architecture.html)
- [Bevy ECS Introduction](https://bevyengine.org/learn/book/getting-started/ecs/)
