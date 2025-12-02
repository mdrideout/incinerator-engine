# Incinerator Engine - Initial Setup Plan

## Goal
Build a GTA III-style MMO game engine using Zig, SDL3, Jolt Physics, and ImGui.

## Rendering Choice: SDL3 GPU API
- Cross-platform abstraction over Vulkan/Metal/D3D12
- Modern shader-based pipeline
- Already part of SDL3 dependency
- Good fit for 3D game with open world

---

## Phase 1: Foundation (Start Here)

### Step 1.1: Window + Game Loop
Create `src/main.zig` with:
- SDL3 window initialization (1280x720, resizable)
- Proper game loop with fixed timestep (60 Hz physics, uncapped render)
- Basic input handling (ESC to quit)
- Clean shutdown

**Key concepts to learn:**
- SDL3 initialization and event polling
- Fixed timestep pattern (accumulator-based)
- Delta time for frame-independent updates

### Step 1.2: SDL3 GPU Initialization
- Create GPU device
- Create swapchain for the window
- Basic clear-to-color each frame (cornflower blue like the original instructions)

**This proves GPU rendering works before adding complexity.**

---

## Phase 2: 3D Rendering Basics

### Step 2.1: Shader Pipeline
- Write basic vertex + fragment shaders (SDL_GPU shader format)
- Create graphics pipeline
- Render a colored triangle

### Step 2.2: 3D Camera
- Perspective projection matrix
- View matrix (camera position/rotation)
- Render a 3D cube with camera controls

### Step 2.3: Mesh Loading
- Basic OBJ or glTF loader
- Vertex buffers, index buffers
- Texture loading and sampling

---

## Phase 3: Engine Systems

### Step 3.1: ImGui Integration
- zgui with SDL3 GPU backend
- Debug windows (FPS, entity inspector, console)

### Step 3.2: Physics Integration
- Jolt physics world setup
- Ground plane + falling objects
- Debug visualization

### Step 3.3: Entity/Component System
- Simple archetypal ECS or component bags
- Transform, Mesh, Physics components
- Scene graph for hierarchical transforms

---

## Phase 4: Game Features (Future)
- Asset pipeline (models, textures, audio)
- Networking foundation for MMO
- Open world streaming/chunking
- Character controller
- Vehicles (GTA-style)

---

## First Task: Canonical Game Loop with SDL3

### Architecture: Fixed Timestep with Interpolation

```
┌─────────────────────────────────────────────────────────────┐
│ Phase 1: INPUT PUMP (Per-Frame / Uncapped)                  │
│ - SDL_PollEvent drains OS events                            │
│ - Latches input state to InputBuffer struct                 │
├─────────────────────────────────────────────────────────────┤
│ Phase 2: SIMULATION TICK (Fixed 120Hz = 8.333ms)            │
│ - Accumulator pattern: while (accumulator >= TICK_RATE)     │
│ - Physics, gameplay logic consume buffered input            │
│ - Store previous state for interpolation                    │
├─────────────────────────────────────────────────────────────┤
│ Phase 3: PRESENTATION (Interpolated)                        │
│ - alpha = accumulator / TICK_RATE                           │
│ - Render state = lerp(previous, current, alpha)             │
│ - Smooth visuals at any framerate                           │
└─────────────────────────────────────────────────────────────┘
```

### Why 120Hz tick rate?
- Lower input latency than 60Hz
- Smoother physics simulation
- MMO server can run different rate (20-60Hz) for network sync
- Local simulation stays responsive

### SDL3 APIs we'll use:
- `SDL_GetPerformanceCounter()` / `SDL_GetPerformanceFrequency()` - High-precision timing
- `SDL_PollEvent()` - Drain event queue
- `SDL_GetKeyboardState()` - Continuous key polling
- `SDL_GetMouseState()` - Mouse position/buttons

### Files to create/modify:

1. **`src/main.zig`** - Entry point, owns the loop
2. **`src/input.zig`** - InputBuffer struct, event processing
3. **`src/timing.zig`** - FrameTimer, accumulator, delta calculations

### Debug/Test Tools (Phase 1):
- Frame time graph (via ImGui later, console print for now)
- Tick count per frame counter
- Input event log (debug print keypresses)

### Implementation approach:
1. Create timing module with high-precision frame timer
2. Create input module with buffered input state
3. Main loop structure:
   ```
   while running:
       frame_timer.begin_frame()

       // Phase 1: Input
       input.pump_events()  // SDL_PollEvent loop
       if input.quit_requested(): break

       // Phase 2: Simulation (fixed timestep)
       accumulator += frame_timer.delta
       while accumulator >= TICK_DURATION:
           simulation.tick(input.consume())
           accumulator -= TICK_DURATION

       // Phase 3: Render
       alpha = accumulator / TICK_DURATION
       renderer.present(alpha)  // interpolated

       frame_timer.end_frame()
   ```
4. For now, simulation.tick() and renderer.present() are stubs
5. Debug output: FPS, tick count, input events to console
