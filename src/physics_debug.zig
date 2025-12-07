//! physics_debug.zig - Jolt Physics Debug Visualization
//!
//! DOMAIN: Debug/Visualization Layer
//!
//! This module implements the zphysics DebugRenderer interface to receive
//! draw callbacks from Jolt Physics. When you call physics_system.drawBodies(),
//! Jolt iterates all bodies and calls our callbacks with geometry data.
//!
//! Architecture:
//! 1. Jolt calls our VTable callbacks (drawLine, drawTriangle, drawGeometry)
//! 2. We buffer vertices into ArrayLists
//! 3. At render time, we upload buffers to GPU and draw
//! 4. Buffers are cleared at the start of each frame
//!
//! IMPORTANT: PhysicsDebugRenderer must be an extern struct with vtable as
//! the first field for C ABI compatibility. The actual rendering data is
//! stored separately in RendererData, accessed via a pointer.

const std = @import("std");
const zphysics = @import("zphysics");
const zm = @import("zmath");
const mesh_module = @import("mesh.zig");
const sdl = @import("sdl.zig");

const c = sdl.c;
const Vertex = mesh_module.Vertex;

// ============================================================================
// Configuration
// ============================================================================

/// Initial capacity for line vertex buffer (in vertices, not lines)
const INITIAL_LINE_CAPACITY: usize = 20_000;

/// Initial capacity for triangle vertex buffer
const INITIAL_TRIANGLE_CAPACITY: usize = 30_000;

// ============================================================================
// Debug Draw Settings (exposed to editor)
// ============================================================================

/// Settings for physics debug visualization.
/// These control what gets drawn when debug rendering is enabled.
/// Must be extern struct for C ABI since it's embedded in PhysicsDebugRenderer.
pub const DebugDrawSettings = extern struct {
    /// Master toggle - when false, nothing is drawn
    enabled: bool = false,

    /// Draw collision shapes via drawGeometry callback
    /// NOTE: Currently not rendered - requires implementing geometry batch extraction
    draw_shapes: bool = false,

    /// Draw shapes as wireframe instead of solid
    /// NOTE: Requires draw_shapes to work first
    wireframe: bool = true,

    /// Draw axis-aligned bounding boxes (AABBs) around bodies
    /// AABBs are ALWAYS axis-aligned and expand when objects rotate
    /// This is the main working visualization - shows broad-phase bounds
    draw_bounding_boxes: bool = true,

    /// Draw velocity vectors as arrows from center of mass
    /// Only visible on MOVING bodies
    draw_velocity: bool = false,

    /// Draw center of mass transform as RGB coordinate axes (X=red, Y=green, Z=blue)
    draw_center_of_mass: bool = false,

    /// Draw the world transform as RGB coordinate axes
    draw_world_transform: bool = false,
};

// ============================================================================
// Render Primitive (extern-compatible, stored in pool)
// ============================================================================

/// Simple marker for allocated primitives in the pool.
/// The actual geometry data is captured in drawLine/drawTriangle callbacks.
const RenderPrimitive = extern struct {
    allocated: bool = false,
};

// ============================================================================
// Renderer Data (non-extern, holds actual buffers)
// ============================================================================

/// Holds the actual rendering data. Not extern-compatible because it contains
/// ArrayList and Allocator. Accessed via pointer from PhysicsDebugRenderer.
pub const RendererData = struct {
    allocator: std.mem.Allocator,
    line_vertices: std.ArrayList(Vertex),
    triangle_vertices: std.ArrayList(Vertex),
    line_buffer: ?*c.SDL_GPUBuffer = null,
    line_buffer_capacity: usize = 0,
    triangle_buffer: ?*c.SDL_GPUBuffer = null,
    triangle_buffer_capacity: usize = 0,
    device: *c.SDL_GPUDevice,

    pub fn init(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice) RendererData {
        return .{
            .allocator = allocator,
            .line_vertices = std.ArrayList(Vertex).initCapacity(allocator, INITIAL_LINE_CAPACITY) catch unreachable,
            .triangle_vertices = std.ArrayList(Vertex).initCapacity(allocator, INITIAL_TRIANGLE_CAPACITY) catch unreachable,
            .device = device,
        };
    }

    pub fn deinit(self: *RendererData) void {
        if (self.line_buffer) |buf| c.SDL_ReleaseGPUBuffer(self.device, buf);
        if (self.triangle_buffer) |buf| c.SDL_ReleaseGPUBuffer(self.device, buf);
        self.line_vertices.deinit(self.allocator);
        self.triangle_vertices.deinit(self.allocator);
    }
};

// ============================================================================
// Physics Debug Renderer (extern struct for C ABI)
// ============================================================================

/// Implements zphysics DebugRenderer to receive Jolt's debug draw callbacks.
/// MUST be extern struct with vtable as first field for C ABI compatibility!
pub const PhysicsDebugRenderer = extern struct {
    // VTable pointer - MUST be first field (offset 0) for C ABI!
    vtable: *const zphysics.DebugRenderer.VTable(PhysicsDebugRenderer) = zphysics.DebugRenderer.initVTable(PhysicsDebugRenderer),

    // Pre-allocated primitive pool (matches zphysics test pattern)
    primitives: [64]RenderPrimitive = [_]RenderPrimitive{.{}} ** 64,
    prim_head: i32 = -1,

    // Debug stats
    draw_geometry_count: usize = 0,

    // Pointer to non-extern rendering data (set via setData)
    data_ptr: usize = 0, // Use usize to store pointer in extern struct

    // User-configurable settings
    settings: DebugDrawSettings = .{},

    // ========================================================================
    // Lifecycle (public API)
    // ========================================================================

    /// Set the renderer data pointer. Call this after creating RendererData.
    pub fn setData(self: *PhysicsDebugRenderer, data: *RendererData) void {
        self.data_ptr = @intFromPtr(data);
    }

    /// Get the renderer data. Returns null if not set.
    pub fn getData(self: *PhysicsDebugRenderer) ?*RendererData {
        if (self.data_ptr == 0) return null;
        return @ptrFromInt(self.data_ptr);
    }

    /// Register this renderer as the Jolt debug renderer singleton.
    pub fn registerSingleton(self: *PhysicsDebugRenderer) !void {
        try zphysics.DebugRenderer.createSingleton(self);
    }

    /// Unregister from Jolt.
    pub fn unregisterSingleton() void {
        zphysics.DebugRenderer.destroySingleton();
    }

    // ========================================================================
    // Per-Frame Operations (public API)
    // ========================================================================

    /// Clear buffers at the start of each frame.
    pub fn beginFrame(self: *PhysicsDebugRenderer) void {
        if (self.getData()) |data| {
            data.line_vertices.clearRetainingCapacity();
            data.triangle_vertices.clearRetainingCapacity();
        }
        self.draw_geometry_count = 0;
    }

    /// Render all buffered debug geometry.
    pub fn render(
        self: *PhysicsDebugRenderer,
        gpu_renderer: anytype,
        view_proj: zm.Mat,
    ) void {
        if (!self.settings.enabled) return;

        const data = self.getData() orelse return;

        if (data.line_vertices.items.len >= 2) {
            uploadAndDrawLines(data, gpu_renderer, view_proj);
        }

        if (data.triangle_vertices.items.len >= 3) {
            uploadAndDrawTriangles(data, gpu_renderer, view_proj);
        }
    }

    /// Get the Jolt BodyDrawSettings configured from our settings.
    pub fn getBodyDrawSettings(self: *const PhysicsDebugRenderer) zphysics.DebugRenderer.BodyDrawSettings {
        return .{
            .shape = self.settings.draw_shapes,
            .shape_wireframe = self.settings.wireframe,
            .bounding_box = self.settings.draw_bounding_boxes,
            .velocity = self.settings.draw_velocity,
            .center_of_mass_transform = self.settings.draw_center_of_mass,
            .world_transform = self.settings.draw_world_transform,
            .shape_color = .motion_type_color,
        };
    }

    // ========================================================================
    // VTable Callbacks (called by Jolt via C ABI)
    // These MUST be pub fn for initVTable to find them.
    // ========================================================================

    fn colorToRgb(color: zphysics.DebugRenderer.Color) [3]f32 {
        return .{
            @as(f32, @floatFromInt(color.comp.r)) / 255.0,
            @as(f32, @floatFromInt(color.comp.g)) / 255.0,
            @as(f32, @floatFromInt(color.comp.b)) / 255.0,
        };
    }

    pub fn drawLine(
        self: *PhysicsDebugRenderer,
        from: *const [3]zphysics.Real,
        to: *const [3]zphysics.Real,
        color: zphysics.DebugRenderer.Color,
    ) callconv(.c) void {
        const data = self.getData() orelse return;
        const rgb = colorToRgb(color);
        data.line_vertices.append(data.allocator, .{ .position = from.*, .color = rgb }) catch return;
        data.line_vertices.append(data.allocator, .{ .position = to.*, .color = rgb }) catch return;
    }

    pub fn drawTriangle(
        self: *PhysicsDebugRenderer,
        v1: *const [3]zphysics.Real,
        v2: *const [3]zphysics.Real,
        v3: *const [3]zphysics.Real,
        color: zphysics.DebugRenderer.Color,
    ) callconv(.c) void {
        const data = self.getData() orelse return;
        const rgb = colorToRgb(color);
        data.triangle_vertices.append(data.allocator, .{ .position = v1.*, .color = rgb }) catch return;
        data.triangle_vertices.append(data.allocator, .{ .position = v2.*, .color = rgb }) catch return;
        data.triangle_vertices.append(data.allocator, .{ .position = v3.*, .color = rgb }) catch return;
    }

    pub fn createTriangleBatch(
        self: *PhysicsDebugRenderer,
        triangles: [*]zphysics.DebugRenderer.Triangle,
        triangle_count: u32,
    ) callconv(.c) *zphysics.DebugRenderer.TriangleBatch {
        _ = triangles;
        _ = triangle_count;
        // Use pre-allocated primitive from pool (like zphysics test)
        self.prim_head += 1;
        const idx: usize = @intCast(@mod(self.prim_head, 64));
        const prim = &self.primitives[idx];
        prim.allocated = true;
        return zphysics.DebugRenderer.createTriangleBatch(prim);
    }

    pub fn createTriangleBatchIndexed(
        self: *PhysicsDebugRenderer,
        vertices: [*]zphysics.DebugRenderer.Vertex,
        vertex_count: u32,
        indices: [*]u32,
        index_count: u32,
    ) callconv(.c) *zphysics.DebugRenderer.TriangleBatch {
        _ = vertices;
        _ = vertex_count;
        _ = indices;
        _ = index_count;
        // Use pre-allocated primitive from pool
        self.prim_head += 1;
        const idx: usize = @intCast(@mod(self.prim_head, 64));
        const prim = &self.primitives[idx];
        prim.allocated = true;
        return zphysics.DebugRenderer.createTriangleBatch(prim);
    }

    pub fn destroyTriangleBatch(
        self: *PhysicsDebugRenderer,
        batch: *anyopaque,
    ) callconv(.c) void {
        _ = self;
        const prim: *RenderPrimitive = @ptrCast(@alignCast(batch));
        prim.allocated = false;
    }

    pub fn drawGeometry(
        self: *PhysicsDebugRenderer,
        model_matrix: *const zphysics.RMatrix,
        world_space_bound: *const zphysics.AABox,
        lod_scale_sq: f32,
        color: zphysics.DebugRenderer.Color,
        geometry: *const zphysics.DebugRenderer.Geometry,
        cull_mode: zphysics.DebugRenderer.CullMode,
        cast_shadow: zphysics.DebugRenderer.CastShadow,
        draw_mode: zphysics.DebugRenderer.DrawMode,
    ) callconv(.c) void {
        // Ignore all parameters - we capture geometry via drawLine/drawTriangle instead
        // This matches the zphysics test's approach
        _ = model_matrix;
        _ = world_space_bound;
        _ = lod_scale_sq;
        _ = color;
        _ = geometry;
        _ = cull_mode;
        _ = cast_shadow;
        _ = draw_mode;
        self.draw_geometry_count += 1;
    }

    pub fn drawText3D(
        self: *PhysicsDebugRenderer,
        position: *const [3]zphysics.Real,
        string: [*:0]const u8,
        color: zphysics.DebugRenderer.Color,
        height: f32,
    ) callconv(.c) void {
        _ = self;
        _ = position;
        _ = string;
        _ = color;
        _ = height;
        // Not implemented
    }
};

// ============================================================================
// GPU Upload and Draw (standalone functions)
// ============================================================================

fn uploadAndDrawLines(data: *RendererData, gpu_renderer: anytype, view_proj: zm.Mat) void {
    const vertices = data.line_vertices.items;
    const byte_size = @sizeOf(Vertex) * vertices.len;

    // Ensure GPU buffer is large enough
    if (data.line_buffer == null or data.line_buffer_capacity < byte_size) {
        if (data.line_buffer) |buf| c.SDL_ReleaseGPUBuffer(data.device, buf);

        const new_capacity = byte_size * 2;
        data.line_buffer = c.SDL_CreateGPUBuffer(data.device, &c.SDL_GPUBufferCreateInfo{
            .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
            .size = @intCast(new_capacity),
            .props = 0,
        });
        data.line_buffer_capacity = new_capacity;

        if (data.line_buffer == null) {
            std.debug.print("Failed to create debug line buffer: {s}\n", .{c.SDL_GetError()});
            return;
        }
    }

    // Upload vertex data via transfer buffer
    const transfer_buffer = c.SDL_CreateGPUTransferBuffer(data.device, &c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = @intCast(byte_size),
        .props = 0,
    }) orelse {
        std.debug.print("Failed to create transfer buffer for lines: {s}\n", .{c.SDL_GetError()});
        return;
    };
    defer c.SDL_ReleaseGPUTransferBuffer(data.device, transfer_buffer);

    const mapped = c.SDL_MapGPUTransferBuffer(data.device, transfer_buffer, false);
    if (mapped == null) {
        std.debug.print("Failed to map transfer buffer: {s}\n", .{c.SDL_GetError()});
        return;
    }
    @memcpy(@as([*]u8, @ptrCast(mapped))[0..byte_size], std.mem.sliceAsBytes(vertices));
    c.SDL_UnmapGPUTransferBuffer(data.device, transfer_buffer);

    const cmd = c.SDL_AcquireGPUCommandBuffer(data.device) orelse {
        std.debug.print("Failed to acquire command buffer: {s}\n", .{c.SDL_GetError()});
        return;
    };

    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        return;
    };

    c.SDL_UploadToGPUBuffer(
        copy_pass,
        &c.SDL_GPUTransferBufferLocation{ .transfer_buffer = transfer_buffer, .offset = 0 },
        &c.SDL_GPUBufferRegion{ .buffer = data.line_buffer.?, .offset = 0, .size = @intCast(byte_size) },
        false,
    );

    c.SDL_EndGPUCopyPass(copy_pass);
    _ = c.SDL_SubmitGPUCommandBuffer(cmd);

    gpu_renderer.drawLines(data.line_buffer.?, @intCast(vertices.len), view_proj);
}

fn uploadAndDrawTriangles(data: *RendererData, gpu_renderer: anytype, view_proj: zm.Mat) void {
    const vertices = data.triangle_vertices.items;
    const byte_size = @sizeOf(Vertex) * vertices.len;

    if (data.triangle_buffer == null or data.triangle_buffer_capacity < byte_size) {
        if (data.triangle_buffer) |buf| c.SDL_ReleaseGPUBuffer(data.device, buf);

        const new_capacity = byte_size * 2;
        data.triangle_buffer = c.SDL_CreateGPUBuffer(data.device, &c.SDL_GPUBufferCreateInfo{
            .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
            .size = @intCast(new_capacity),
            .props = 0,
        });
        data.triangle_buffer_capacity = new_capacity;

        if (data.triangle_buffer == null) {
            std.debug.print("Failed to create debug triangle buffer: {s}\n", .{c.SDL_GetError()});
            return;
        }
    }

    const transfer_buffer = c.SDL_CreateGPUTransferBuffer(data.device, &c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = @intCast(byte_size),
        .props = 0,
    }) orelse {
        return;
    };
    defer c.SDL_ReleaseGPUTransferBuffer(data.device, transfer_buffer);

    const mapped = c.SDL_MapGPUTransferBuffer(data.device, transfer_buffer, false);
    if (mapped == null) return;
    @memcpy(@as([*]u8, @ptrCast(mapped))[0..byte_size], std.mem.sliceAsBytes(vertices));
    c.SDL_UnmapGPUTransferBuffer(data.device, transfer_buffer);

    const cmd = c.SDL_AcquireGPUCommandBuffer(data.device) orelse return;

    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        return;
    };

    c.SDL_UploadToGPUBuffer(
        copy_pass,
        &c.SDL_GPUTransferBufferLocation{ .transfer_buffer = transfer_buffer, .offset = 0 },
        &c.SDL_GPUBufferRegion{ .buffer = data.triangle_buffer.?, .offset = 0, .size = @intCast(byte_size) },
        false,
    );

    c.SDL_EndGPUCopyPass(copy_pass);
    _ = c.SDL_SubmitGPUCommandBuffer(cmd);

    gpu_renderer.drawDebugTriangles(data.triangle_buffer.?, @intCast(vertices.len), view_proj);
}
