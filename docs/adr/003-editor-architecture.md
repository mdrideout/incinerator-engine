# ADR-003: Editor Architecture and Tool System

**Status:** Accepted
**Date:** 2025-12-05
**Decision Makers:** Matt, Claude

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

```zig
// build.zig
const zgui = b.dependency("zgui", .{
    .shared = false,
    .with_implot = true,
    .backend = .sdl3_gpu,  // Uses SDL3's GPU API for rendering
});
```

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
│       └── scene_tool.zig   # Entity hierarchy
```

### Tool Interface

Tools implement a minimal interface - just a draw function and metadata:

```zig
pub const Tool = struct {
    name: [:0]const u8,           // Window title (null-terminated for ImGui)
    enabled: bool = true,          // Visibility toggle
    draw_fn: *const fn (*EditorContext) void,
    shortcut: ?u32 = null,         // Optional hotkey
};
```

### Shared Context

Tools receive an `EditorContext` with read-only engine state and mutable editor state:

```zig
pub const EditorContext = struct {
    // Read-only engine references
    camera: *const Camera,
    world: *const World,
    frame_timer: *const FrameTimer,

    // Mutable editor state
    selected_entity: ?usize = null,
    gizmo_mode: GizmoMode = .translate,
    gizmo_space: GizmoSpace = .world,

    // Input capture flags
    wants_mouse: bool = false,
    wants_keyboard: bool = false,
};
```

### Manual Tool Registration

Tools are **explicitly registered** in `editor.zig`:

```zig
var tools = [_]*Tool{
    &stats_tool.tool,
    &camera_tool.tool,
    &scene_tool.tool,
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
    struct { pub fn init() void {} pub fn draw() void {} };
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

### Event Processing

Editor gets first chance to handle input events:

```zig
// input.zig
while (c.SDL_PollEvent(&event)) {
    // Editor sees events first
    if (editor.processEvent(&event)) {
        continue;  // Editor consumed it
    }
    // Otherwise game processes it
    switch (event.type) { ... }
}
```

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

Editor code (ImGui, gizmos) adds significant binary size. Release builds typically don't need debug UI. By stripping it at compile time:
- Smaller release binaries
- No runtime overhead checking "is editor enabled"
- Clear separation of debug vs production code

## Consequences

### Positive

- **Extensible**: Adding new tools is trivial (create file, register, done)
- **Familiar**: Developers with Unity/Unreal experience know ImGui patterns
- **Lightweight**: Only compiled into debug builds by default
- **Integrated**: Same command buffer as scene, proper input handling

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

pub var tool = tool_module.Tool{
    .name = "My Tool",
    .enabled = false,  // Start hidden
    .draw_fn = draw,
};

fn draw(ctx: *tool_module.EditorContext) void {
    if (zgui.begin("My Tool", .{})) {
        zgui.text("Hello!", .{});
    }
    zgui.end();
}
```

2. Register in `src/editor/editor.zig`:
```zig
const my_tool = @import("tools/my_tool.zig");

var tools = [_]*Tool{
    &stats_tool.tool,
    &my_tool.tool,  // Add here
};
```

### Future: ImGuizmo Integration

For 3D gizmos (translate, rotate, scale handles), we'll add ImGuizmo:

```zig
// Future: in gizmos.zig
pub fn manipulateTransform(
    transform: *Transform,
    view: zm.Mat,
    proj: zm.Mat,
    mode: GizmoMode,
) bool {
    // Render 3D gizmo and return true if user modified transform
}
```

This requires adding `with_gizmo = true` to the zgui dependency.

## References

- [Dear ImGui](https://github.com/ocornut/imgui)
- [zgui - Zig ImGui bindings](https://github.com/zig-gamedev/zgui)
- [ImGuizmo - 3D Gizmos](https://github.com/CedricGuillemet/ImGuizmo)
- [ADR-002: Module Architecture](./002-module-architecture-and-layering.md)
