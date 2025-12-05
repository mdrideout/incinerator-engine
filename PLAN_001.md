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

Features working:
- SDL3 window (1280x720, resizable)
- Fixed 120Hz simulation tick rate
- Input buffering (keys_down, keys_pressed, keys_released)
- Mouse tracking (position, delta, buttons, wheel)
- Debug output (FPS, frame time, tick count)
- Clean shutdown with stats

### ⏳ Step 1.2: SDL3 GPU Initialization ← **UP NEXT**
- Replace SDL_Renderer with SDL_GPU device
- Create swapchain for the window
- Basic clear-to-color each frame
- Proves GPU rendering pipeline works before adding shaders

---

## Phase 2: 3D Rendering Basics

### Step 2.1: Shader Pipeline
- Write basic vertex + fragment shaders (SDL_GPU shader format)
- Create graphics pipeline
- Render a colored triangle

### Step 2.2: 3D Camera
- Perspective projection matrix
- View matrix (camera position/rotation)
- Render a 3D cube with camera controls (WASD + mouse look)

### Step 2.3: Mesh Loading
- Basic OBJ or glTF loader
- Vertex buffers, index buffers
- Texture loading and sampling

---

## Phase 3: Engine Systems

### Step 3.1: ImGui Integration
- zgui with SDL3 GPU backend
- Debug windows (FPS graph, entity inspector, console)

### Step 3.2: Physics Integration
- Jolt physics world setup
- Ground plane + falling objects
- Debug visualization (wireframe colliders)

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

## Current File Structure

```
src/
├── main.zig      # Entry point, App struct, game loop
├── timing.zig    # FrameTimer, TICK_RATE, TICK_DURATION
├── input.zig     # InputBuffer, Key constants, MouseButton
└── root.zig      # Library root (unused for now)
```

---

## Next Task: Step 1.2 - SDL3 GPU Setup

### What we'll do:
1. Replace `SDL_Renderer` with `SDL_GPUDevice`
2. Create swapchain attached to window
3. Each frame: acquire texture → begin render pass → clear → end → present
4. This is the foundation for all 3D rendering

### SDL3 GPU APIs to learn:
- `SDL_CreateGPUDevice()` - Create the GPU device
- `SDL_ClaimWindowForGPUDevice()` - Attach swapchain to window
- `SDL_AcquireGPUSwapchainTexture()` - Get texture to render to
- `SDL_BeginGPURenderPass()` / `SDL_EndGPURenderPass()` - Render pass
- `SDL_SubmitGPUCommandBuffer()` - Submit work to GPU
