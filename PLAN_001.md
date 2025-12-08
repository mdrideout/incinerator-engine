# Incinerator Engine - Development Plan

## Goal
Build a GTA III-style MMO game engine using Zig, SDL3, Jolt Physics, and ImGui.

## Rendering Choice: SDL3 GPU API
- Cross-platform abstraction over Vulkan/Metal/D3D12
- Modern shader-based pipeline
- Already part of SDL3 dependency
- Good fit for 3D game with open world

---

## Phase 1: Foundation ✅ COMPLETE

### ✅ Step 1.1: Window + Canonical Game Loop
**Status: COMPLETE**

Files created:
- `src/main.zig` - Entry point with canonical game loop
- `src/timing.zig` - High-precision frame timer (120Hz fixed timestep)
- `src/input.zig` - Buffered input system (keyboard, mouse, events)

Architecture implemented:
```
┌─────────────────────────────────────────────────────────────┐
│ Phase 1: INPUT PUMP (Per-Frame / Uncapped)                  │
│ - SDL_PollEvent drains OS events                            │
│ - Latches input state to InputBuffer struct                 │
├─────────────────────────────────────────────────────────────┤
│ Phase 2: SIMULATION TICK (Fixed 120Hz = 8.333ms)            │
│ - Accumulator pattern: while (accumulator >= TICK_RATE)     │
│ - Physics, gameplay logic consume buffered input            │
├─────────────────────────────────────────────────────────────┤
│ Phase 3: PRESENTATION (Interpolated)                        │
│ - alpha = accumulator / TICK_RATE                           │
│ - Ready for lerp(previous, current, alpha) when needed      │
└─────────────────────────────────────────────────────────────┘
```

### ✅ Step 1.2: SDL3 GPU Initialization
**Status: COMPLETE**

- Created `src/renderer.zig` with SDL_GPU device
- Created `src/sdl.zig` for shared C bindings
- Swapchain attached to window
- Command buffer / render pass pattern working
- Clear-to-color each frame

---

## Phase 2: 3D Rendering Basics ✅ COMPLETE

### ✅ Step 2.1: Shader Pipeline
**Status: COMPLETE**

Files created:
- `shaders/triangle.vert` - GLSL vertex shader
- `shaders/triangle.frag` - GLSL fragment shader
- `src/mesh.zig` - Vertex format, GPU buffer management
- `src/primitives.zig` - Built-in shape factories
- `src/world.zig` - Entity and scene management

Architecture documented in:
- `docs/adr/001-shader-language-and-compilation.md` - Shader strategy
- `docs/adr/002-module-architecture-and-layering.md` - Module organization

Features working:
- GLSL 4.50 shaders with Vulkan semantics
- Build-time compilation: GLSL → SPIR-V → Metal/HLSL
- Platform-aware shader loading via @embedFile
- Graphics pipeline with vertex layout
- Vertex buffer upload to GPU
- RGB gradient triangle rendering
- Layered module architecture (renderer/mesh/primitives/world)

### ✅ Step 2.2: 3D Camera
**Status: COMPLETE**

Files created/modified:
- `src/camera.zig` - First-person camera with yaw/pitch, view/projection matrices
- `src/primitives.zig` - Added createCube() with colored faces
- `src/renderer.zig` - Added uniform buffer support, drawMesh takes MVP matrix
- `src/main.zig` - Camera controls wired up
- `shaders/triangle.vert` - Added MVP uniform buffer

Features working:
- zmath integration for SIMD-optimized math
- Perspective projection with configurable FOV
- View matrix generation from camera position/orientation
- Uniform buffer pushing MVP matrix to shader
- WASD movement (forward/back/strafe)
- Q/E for vertical movement
- Right-click + drag for mouse look
- Unit cube with colored faces (6 colors, one per face)

### ✅ Step 2.3: Mesh Loading (Geometry)
**Status: COMPLETE**

Files created/modified:
- `src/gltf_loader.zig` - GLB/glTF loader using zmesh (wraps cgltf)
- `src/mesh.zig` - Added VertexPNU format, indexed rendering, VertexFormat enum
- `src/renderer.zig` - Dual pipeline (pos_color + pos_normal_uv), depth buffer, indexed draw support
- `shaders/model.vert` - Vertex shader for loaded models (position + normal + UV)
- `shaders/model.frag` - Fragment shader (currently visualizes normals as colors)
- `build.zig` - Added zmesh dependency and model shader compilation
- `build.zig.zon` - Added zmesh from zig-gamedev

Features working:
- GLB binary format loading via zmesh/cgltf
- Indexed mesh rendering (shared vertices with index buffer)
- Two graphics pipelines: primitives (pos+color) and models (pos+normal+uv)
- Depth buffer for proper 3D occlusion
- Multiple model rendering with transforms
- UVs extracted and passed to shader (ready for textures)

Test models loaded:
- `assets/models/blonde-woman.glb` - 32,870 vertices, 50K triangles
- `assets/models/blonde-woman-hunyuan.glb` - 1,544 vertices, 1.8K triangles

### ✅ Step 2.4: Texture Loading
**Status: COMPLETE**

Files created/modified:
- `src/texture.zig` - GPU texture creation utilities (createTexture, createPlaceholderTexture)
- `src/gltf_loader.zig` - Extract textures from GLB materials via zstbi
- `src/mesh.zig` - Added `diffuse_texture: ?Texture` field
- `src/renderer.zig` - Added sampler, placeholder texture, texture binding in drawMesh
- `shaders/model.frag` - Added texture sampler and basic diffuse lighting
- `build.zig` - Added zstbi dependency
- `build.zig.zon` - Added zstbi from zig-gamedev

Features working:
- PNG/JPEG texture decoding via zstbi (stb_image wrapper)
- Embedded GLB textures extracted from buffer views
- Texture upload to GPU via transfer buffer pattern
- Linear filtering sampler for smooth texture sampling
- Placeholder white texture for untextured meshes
- Basic ambient + diffuse lighting in fragment shader

Test results:
- `assets/models/blonde-woman.glb` - 4096x4096 diffuse texture
- `assets/models/blonde-woman-hunyuan.glb` - 4096x4096 diffuse texture

---

## Phase 3: Engine Systems ✅ COMPLETE

### ✅ Step 3.1: ImGui Integration
**Status: COMPLETE**

Files created:
- `src/editor/editor.zig` - Main editor orchestrator, tool registry, menu bar
- `src/editor/imgui_backend.zig` - SDL3 GPU backend wrapper
- `src/editor/tool.zig` - Tool interface and EditorContext definition
- `src/editor/tools/stats_tool.zig` - FPS, frame time, graph
- `docs/adr/003-editor-architecture.md` - Architecture decision record

Files modified:
- `build.zig` - Added `-Deditor` build option, `build_options` module, zgui SDL3 GPU backend
- `src/main.zig` - Editor init/deinit, split render pass flow for ImGui
- `src/input.zig` - Editor event processing before game input
- `src/renderer.zig` - Added `endRenderPass()`, `submitFrame()`, `getSwapchainTexture()`

Features working:
- zgui with SDL3 GPU backend (`.backend = .sdl3_gpu`)
- Conditional compilation: editor on by default in Debug, off in Release
- Tool-first architecture with manual registration
- Stats tool showing FPS, frame time, tick info, frame time graph
- Main menu bar with Tools and View menus
- F1 to toggle editor, F2 to toggle ImGui demo window
- Proper two-pass rendering (scene pass → ImGui copy pass → ImGui render pass)
- Input handling: editor consumes events before game

**Additional tools implemented:**
- ✅ Camera tool (position, rotation, FOV, direction vectors)
- ✅ Input passthrough mode (F3 toggle) - move camera while editor visible
- ✅ F1 toggle fix - properly shows/hides editor
- ✅ "Press F1" hint when editor hidden

**Remaining for Step 3.1 (optional enhancements):**
- ✅ Scene tool (entity hierarchy, inspector) - MOVED TO Step 3.3
- ✅ Wireframe mode toggle (F4 toggle, render_tool.zig)
- ✅ Texture rendering toggle (render_tool.zig)

### ✅ Step 3.2: Physics Integration
**Status: COMPLETE**

Files created/modified:
- `src/physics.zig` - Jolt physics world wrapper via zphysics
- `src/physics_debug.zig` - PhysicsDebugRenderer implementing Jolt's VTable interface
- `src/ecs.zig` - RigidBody component, physics-ECS sync, quaternion-based Rotation
- `src/editor/tools/physics_tool.zig` - Debug visualization toggles
- `docs/adr/005-physics-ecs-integration.md` - Physics-ECS sync architecture
- `docs/adr/006-physics-debug-rendering.md` - Debug renderer architecture
- `build.zig` / `build.zig.zon` - Added zphysics dependency

Features working:
- Jolt physics world with ground plane
- Falling cubes with tumbling physics
- Debug wireframe rendering (collision shapes, AABBs, velocity vectors)
- Physics-ECS sync with direct quaternion copy (no Euler conversion)
- RigidBody component linking entities to physics bodies
- Editor UI toggles for debug visualization layers
- CPU-side vertex transformation for debug geometry

### ✅ Step 3.3: Entity/Component System
**Status: COMPLETE**

Files created/modified:
- `src/ecs.zig` - GameWorld, components (Position, Rotation, Scale, Renderable), cached queries
- `src/main.zig` - Migrated to ECS, entity spawning after App construction
- `src/editor/tool.zig` - Updated EditorContext for ECS (GameWorld, u64 entity IDs)
- `src/editor/tools/scene_tool.zig` - Entity hierarchy browser with selection and inspector
- `docs/adr/004-ecs-architecture.md` - Architecture decision record
- `build.zig` / `build.zig.zon` - Added zflecs dependency

Files deleted:
- `src/world.zig` - Replaced by ecs.zig

Features working:
- flecs ECS via zflecs (archetype storage, high-performance queries)
- Components: Position, Rotation, Scale, Renderable (mesh pointer)
- Tags: Static, Vehicle, Debris (zero-size markers for filtering)
- Cached query system for efficient iteration
- RenderableIterator with proper cleanup (handles early break and full consumption)
- Scene tool: entity list, selection, transform/mesh inspector
- Entity spawning with stable mesh pointer handling

---

## Phase 4: Game Features (Future)
- Asset pipeline (models, textures, audio)
- Networking foundation for MMO
- Open world streaming/chunking
- Character controller
- Vehicles (GTA-style)

### Discussion Needed: NPC Character Strategy
Before implementing NPC systems, need to decide on asset strategy for large NPC populations:
- **Base mesh approach**: Few body types (male/female, thin/average/heavy) with texture variations
- **Texture atlas**: Clothing/skin variations via texture swapping on shared geometry
- **LOD considerations**: Simpler meshes for distant NPCs
- **Instancing**: GPU instancing for crowds with per-instance texture/color data
- **Memory budget**: Trade-off between mesh variety and texture variety

This affects skinned mesh implementation, asset pipeline, and rendering architecture.

---

## Phase 5: Generative AI Interface (Future)

LLM-powered world manipulation and content generation system.

### Core Capabilities
- **Entity Spawning**: Natural language commands to spawn objects, NPCs, vehicles
  - "Spawn 10 pedestrians walking down the street"
  - "Add a red sports car at the intersection"
  - "Create a stack of physics crates here"
- **World Manipulation**: Modify existing entities via conversation
  - "Make all the cars blue"
  - "Move the player to the rooftop"
  - "Delete all debris entities"
- **Scene Composition**: High-level scene building
  - "Set up a traffic jam scenario"
  - "Create an ambush with 5 NPCs behind cover"

### Architecture Considerations
- **Tool/Function Calling**: LLM invokes typed engine commands (spawn, delete, modify, query)
- **Context Awareness**: Feed current scene state (entity counts, player position) to LLM
- **Safety/Sandboxing**: Rate limits, entity caps, restricted operations
- **Async Execution**: Queue commands, handle streaming responses
- **Editor Integration**: Chat panel in ImGui, command history, undo support

### Implementation Steps
1. Define engine command schema (JSON/structured format)
2. Build command executor that maps LLM output to ECS operations
3. Implement context serializer (scene → prompt context)
4. Add HTTP client for LLM API calls (Claude API)
5. Create editor chat UI with command preview
6. Add conversation history and multi-turn support

### Use Cases
- Rapid prototyping and level design
- Dynamic game master for MMO events
- Procedural content generation
- Debugging and testing scenarios
- In-game NPC dialogue with world awareness

---

## Current File Structure

```
src/
├── main.zig          # Entry point, App struct, game loop
├── renderer.zig      # SDL3 GPU device, dual pipelines, depth buffer, texture binding
├── camera.zig        # First-person camera, view/projection matrices
├── mesh.zig          # Vertex/VertexPNU structs, indexed Mesh type, texture field
├── texture.zig       # GPU texture creation utilities
├── gltf_loader.zig   # GLB/glTF loader with texture extraction
├── primitives.zig    # Built-in shapes (triangle, cube)
├── ecs.zig           # ECS via zflecs (GameWorld, components, queries, physics sync)
├── physics.zig       # Jolt physics world wrapper via zphysics
├── physics_debug.zig # PhysicsDebugRenderer (Jolt VTable implementation)
├── timing.zig        # FrameTimer, TICK_RATE, TICK_DURATION
├── input.zig         # InputBuffer, Key constants, MouseButton, editor event integration
├── sdl.zig           # Shared SDL3 C bindings
├── root.zig          # Library root (unused for now)
└── editor/           # ImGui debug UI system
    ├── editor.zig        # Main orchestrator, tool registry, menu bar, input passthrough
    ├── imgui_backend.zig # SDL3 GPU backend wrapper
    ├── tool.zig          # Tool interface, EditorContext
    └── tools/
        ├── stats_tool.zig   # FPS, frame time, graph
        ├── camera_tool.zig  # Camera position, rotation, FOV inspector
        ├── scene_tool.zig   # Entity hierarchy, selection, inspector
        ├── physics_tool.zig # Physics debug visualization toggles
        └── render_tool.zig  # Wireframe mode, texture toggle

shaders/
├── triangle.vert     # GLSL vertex shader for primitives (pos + color)
├── triangle.frag     # GLSL fragment shader for primitives
├── model.vert        # GLSL vertex shader for models (pos + normal + uv)
├── model.frag        # GLSL fragment shader for models (texture + lighting)
└── compiled/         # (gitignored) SPIR-V + Metal output

assets/
└── models/           # GLB model files for testing
    ├── blonde-woman.glb
    └── blonde-woman-hunyuan.glb

docs/adr/
├── 001-shader-language-and-compilation.md
├── 002-module-architecture-and-layering.md
├── 003-editor-architecture.md
├── 004-ecs-architecture.md
├── 005-physics-ecs-integration.md
└── 006-physics-debug-rendering.md
```

---

## Phase 2 Complete!

All 3D rendering basics are now implemented:
- Shader pipeline with GLSL → SPIR-V → Metal cross-compilation
- First-person camera with WASD + mouse look
- GLB mesh loading with indexed rendering
- Texture loading with diffuse sampling and basic lighting

## Step 3.1 Complete!

ImGui debug UI is now integrated:
- zgui with SDL3 GPU backend
- Tool-first architecture for extensible debug panels
- Stats tool with FPS, frame time, and graph
- Conditional compilation (Debug = editor on, Release = editor off)

## Step 3.3 Complete!

Entity Component System is now implemented:
- flecs ECS via zflecs (archetype storage for cache efficiency)
- Components: Position, Rotation, Scale, Renderable
- Tags: Static, Vehicle, Debris
- Cached queries for efficient iteration
- Scene tool: entity hierarchy, selection, transform/mesh inspector
- Proper iterator cleanup (handles early break and full consumption)

## Phase 3 Complete!

All engine systems are now implemented:
- Jolt physics via zphysics with ground plane + falling objects
- Debug wireframe rendering (collision shapes, AABBs, velocities)
- Physics-ECS sync with direct quaternion copy
- RigidBody component linking entities to physics bodies
- Editor UI for debug visualization toggles

---

## What's Next?

**Option A: More Editor Tools**
- ✅ Wireframe mode toggle for meshes
- ✅ Texture rendering toggle
- ImGuizmo 3D gizmos for transform manipulation

**Option B: Rendering Enhancements**
- Shadow mapping
- Normal mapping
- PBR materials

**Option C: Character Controller**
- Player entity with physics capsule
- WASD movement with physics response
- Jump, ground detection

**Option D: Vehicles**
- Jolt vehicle constraint system
- Wheel physics, suspension
- Basic car handling

**Option E: Ragdoll / Skeleton Physics**
- Skinned mesh rendering (vertex skinning in shader)
- Jolt ragdoll constraint system for articulated bodies
- Skeleton extraction from GLB armature data
- Bone hierarchy with joint limits
- Physics-driven character death/ragdoll transitions
- Potential for procedural animation blending

---

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| WASD | Move camera |
| Q/E | Move down/up |
| Right-click + drag | Look around |
| F1 | Toggle editor visibility |
| F2 | Toggle ImGui demo window |
| F3 | Toggle input passthrough (camera works while editor visible) |
| F4 | Toggle physics debug rendering |
| ESC | Quit |
