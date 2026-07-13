# ADR-003: Editor Architecture and Tool System

**Status:** Accepted, implemented, and amended for owned editor state
**Date:** 2025-12-05
**Amended:** 2026-07-13
**Decision Makers:** Matt, Claude

> The tool-oriented editor remains accepted. The 2026 overhaul amendments
> replace the old backend-default and “editor consumes events first”
> assumptions, and replace process-global editor/tool state with one `Editor`
> value owned by the visual host. The engine compiles the exact-pinned zgui SDL3
> GPU sources against its selected SDL 3.4.12 headers, passes the actual
> swapchain format to ImGui, maintains physical input independently, and gates
> gameplay with ImGui `WantCapture*`. The prototype Scene/Gizmo tools and their
> direct world mutation were removed at S0 closure. Authoring returns only
> through persistent IDs and typed feature commands.

## Context

The Incinerator Engine needs a debug UI system for:
- Runtime performance monitoring (FPS, frame times)
- Scene inspection and manipulation (entity hierarchy, property editing)
- 3D gizmos for transform manipulation (translate, rotate, scale)
- Development tools (console, asset browser, etc.)

We need to decide:
1. What UI framework to use
2. How to architect the tool/panel system
3. How to integrate with the existing render loop
4. How to handle conditional compilation (dev vs release)

## Decision

### UI Framework: Dear ImGui via zgui

We use **Dear ImGui** through the **zgui** Zig wrapper with the **SDL3 GPU backend**.

The root build requests zgui without an upstream backend, then the engine-owned
`tools/build/zgui_sdl3_gpu.zig` adapter compiles the pinned ImGui, SDL3, and
SDL GPU backend sources against the same SDL 3.4.12 headers
and target options as the renderer. This avoids a wrapper-owned SDL header split.

### Architecture: Tool-First Pattern

The editor follows a **tool-first architecture** where each debug panel is a self-contained "Tool" that implements a simple interface:

```
src/
├── editor/
│   ├── editor.zig           # Main orchestrator
│   ├── imgui_backend.zig    # SDL3 GPU backend wrapper
│   ├── tool.zig             # Tool interface definition
│   └── tools/
│       ├── stats_tool.zig   # FPS, frame time
│       ├── camera_tool.zig  # Camera inspector
│       └── render_tool.zig  # Presentation settings
```

### Owned Editor and Tool Interface

The visual host owns one `Editor` value. It owns visibility/capture policy,
tool toggles, statistics history, and authoring drafts for exactly its
lifetime. Teardown resets the value after releasing ImGui while the renderer
device/window still exist; sequential application lifecycles cannot inherit
tool state or retained renderer pointers.

Tools declare immutable metadata and a stable identity. The owned editor stores
their runtime visibility and state, then dispatches typed draw functions:

```zig
pub const Descriptor = struct {
    id: ToolId,
    name: [:0]const u8,
    enabled_by_default: bool = true,
};
```

### Shared Context

Tools receive one-frame borrows through `EditorContext`. Engine/authority data
is immutable; mutations leave through bounded typed request buffers. Renderer
settings are borrowed for the current draw only and are never retained:

```zig
pub const EditorContext = struct {
    camera: *const Camera,
    frame_timer: *const FrameTimer,
    developer_snapshot: *const DeveloperSnapshot,
    control_requests: *ControlRequestBuffer,
    render_settings: *RenderSettings,
    wants_mouse: bool = false,
    wants_keyboard: bool = false,
};
```

### Manual Tool Registration

Tools are **explicitly and statically registered** in `editor.zig`; the array
contains owned runtime values rather than pointers to module globals:

```zig
const default_tools = [_]Tool{
    Tool.init(stats_tool.descriptor),
    Tool.init(camera_tool.descriptor),
    Tool.init(render_tool.descriptor),
};
```

This is intentional over auto-discovery because:
- You see exactly what's included
- Control over render order
- Compile errors if a tool is missing
- Easy to enable/disable tools

### Conditional Compilation

The editor is controlled by a build option with smart defaults:

```zig
// build.zig
const default_editor_enabled = optimize == .Debug;
const editor_enabled = b.option(bool, "editor",
    "Enable editor UI") orelse default_editor_enabled;
```

| Build | Default | Override |
|-------|---------|----------|
| `zig build` (Debug) | Editor ON | `-Deditor=false` to disable |
| `zig build -Doptimize=ReleaseFast` | Editor OFF | `-Deditor=true` to enable |

Code uses `@import("build_options").editor_enabled` for compile-time branching:

```zig
const editor = if (build_options.editor_enabled)
    @import("editor/editor.zig")
else
    @import("editor/disabled.zig");
```

### Render Integration

ImGui requires a **separate render pass** from the scene due to SDL3 GPU constraints:

```
Game Loop
    │
    ▼
beginFrame()           ─┐
    │                   │ Render Pass #1 (Scene)
    ▼                   │ - Clears color/depth
drawScene()             │ - Draws 3D geometry
    │                   │
    ▼                   │
endRenderPass()        ─┘
    │
    ▼
editor.draw()          ─┐
    ├─ zgui.render()    │ Finalizes ImGui frame
    ├─ prepareData()    │ Copy pass (uploads vertices)
    └─ renderData()    ─┘ Render Pass #2 (ImGui)
    │                      - LOAD mode (preserves scene)
    ▼                      - No depth buffer needed
submitFrame()             (submits both passes)
```

**Why separate passes?**

ImGui's `prepareDrawData()` uploads vertex/index buffers via a GPU **copy pass**.
SDL3 GPU doesn't allow starting a copy pass inside a render pass. So we must:
1. End the scene render pass
2. Let ImGui do its copy pass
3. Start a new render pass for ImGui (with `LOAD` to preserve the scene)
4. Submit everything together

This adds minimal overhead since both passes use the same command buffer.

The ImGui pipeline uses `SDL_GetGPUSwapchainTextureFormat` from the claimed
window; it does not assume BGRA8. Scene and editor pipelines therefore agree on
the active backend's real color target format.

Each frame also reads `SDL_GetWindowPixelDensity` and forwards a finite positive
framebuffer scale to ImGui, falling back to `1.0` only when SDL reports an
invalid value. Retina scaling is host presentation policy and never changes
simulation or input authority.

### Event Processing

Every event is forwarded to ImGui, but backend recognition is not a routing
decision. The input layer first preserves physical state, including releases
and focus loss, and separately maintains gameplay-visible state:

```zig
// input.zig
while (c.SDL_PollEvent(&event)) {
    const route = editor.processEvent(&event); // always feeds ImGui
    applyCapture(editor.wantsKeyboard(), editor.wantsMouse());
    updatePhysicalState(event);                // never skipped
    updateGameplayState(event, route);         // capture-filtered
}
```

Reserved editor shortcuts are reported explicitly through `EventRoute`.
Gameplay capture uses `WantCaptureKeyboard` and `WantCaptureMouse`; a held input
that becomes captured stays suppressed until its physical release. Main-window
focus loss clears held state, while secondary editor-window lifecycle events do
not masquerade as game-window events.

## Rationale

### Why Dear ImGui?

| Option | Pros | Cons |
|--------|------|------|
| **Dear ImGui (chosen)** | Industry standard; huge ecosystem; immediate mode = simple | C++ library; some Zig wrapping overhead |
| Custom UI | Full control; native Zig | Massive time investment; reinventing the wheel |
| egui (Rust) | Modern; Rust safety | Language boundary; no SDL3 backend |
| Nuklear | Small; C library | Less features; smaller community |

Dear ImGui is the de-facto standard for game engine debug UIs. The zgui wrapper provides idiomatic Zig bindings.

### Why SDL3 GPU Backend?

zgui offers multiple backends. We chose `sdl3_gpu` because:
- Uses the same GPU API as our renderer (no OpenGL/Vulkan context conflicts)
- Single GPU device for both scene and UI
- Matches our existing SDL3 investment

### Why Tool-First Architecture?

The pattern provides:
1. **Isolation** - Each tool is self-contained, easy to add/remove
2. **Composability** - Tools can be toggled independently
3. **Testability** - Tools can be unit tested in isolation
4. **Discoverability** - Tools menu shows all available panels

### Why Manual Registration Over Auto-Discovery?

| Auto-Discovery | Manual Registration |
|----------------|---------------------|
| Magic - tools appear automatically | Explicit - you see the list |
| No compile-time errors for missing tools | Compile error if import fails |
| Harder to control order | Easy ordering |
| Requires build system or comptime tricks | Simple array literal |

For a small number of tools (< 20), the overhead of one line per tool is negligible compared to the clarity benefits.

### Why Conditional Compilation?

Editor code (ImGui and future authoring extensions) adds significant binary size. Release builds typically don't need debug UI. By stripping it at compile time:
- Smaller release binaries
- No runtime overhead checking "is editor enabled"
- Clear separation of debug vs production code

## Consequences

### Positive

- **Extensible**: Adding new tools is trivial (create file, register, done)
- **Familiar**: Developers with Unity/Unreal experience know ImGui patterns
- **Lightweight**: Only compiled into debug builds by default
- **Integrated**: Same command buffer as scene, proper input handling
- **No stuck controls**: physical releases and focus transitions survive capture changes

### Negative

- **C++ Dependency**: ImGui is C++, compiled via zgui's build system
- **Binary Size**: ImGui adds ~2-3MB to debug builds
- **Learning Curve**: ImGui's immediate mode paradigm differs from retained mode UIs
- **Two Render Passes**: SDL3 GPU requires ImGui to use a separate render pass (copy pass constraint)

### Neutral

- Tool state is ephemeral (resets on restart). Persistent state requires separate save/load logic.

## Implementation Notes

### Adding a New Tool

1. Create `src/editor/tools/my_tool.zig`:
```zig
const zgui = @import("zgui");
const tool_module = @import("../tool.zig");

pub const descriptor = tool_module.Descriptor{
    .id = .my_tool,
    .name = "My Tool",
    .enabled_by_default = false,
};

fn draw(ctx: *tool_module.EditorContext) void {
    if (zgui.begin("My Tool", .{})) {
        zgui.text("Hello!", .{});
    }
    zgui.end();
}
```

2. Add the identity to `ToolId`, dispatch its draw function, and register its
   owned runtime value in `src/editor/editor.zig`:
```zig
const my_tool = @import("tools/my_tool.zig");

const default_tools = [_]Tool{
    Tool.init(stats_tool.descriptor),
    Tool.init(my_tool.descriptor),
};
```

### Deferred Scene Editing and Gizmos

S0 deliberately excludes Scene and Gizmo tools. Their prototype
implementations selected raw Flecs IDs and mutated `GameWorld`/Jolt state
directly, bypassing feature commands, persistent identity, persistence, and
undo semantics. Those files and ImGuizmo compilation are removed rather than
kept as a compatibility path.

The tooling slice may restore selection and transform authoring only after it
can submit the same typed commands used by gameplay, identify targets by
persistent ID, and define save/undo behavior. Stats, Camera, and Render tools
remain useful read-only/debug controls in the meantime.

## References

- [Dear ImGui](https://github.com/ocornut/imgui)
- [zgui - Zig ImGui bindings](https://github.com/zig-gamedev/zgui)
- [ImGuizmo - 3D Gizmos](https://github.com/CedricGuillemet/ImGuizmo)
- [ADR-002: Module Architecture](./002-module-architecture-and-layering.md)
