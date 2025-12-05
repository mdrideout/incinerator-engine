//! renderer.zig - SDL3 GPU Rendering Backend
//!
//! This module wraps SDL3's GPU API to provide a clean rendering interface.
//! SDL_GPU automatically selects the best backend for your platform:
//! - macOS: Metal
//! - Windows: D3D12 or Vulkan
//! - Linux: Vulkan
//!
//! The render loop follows the modern GPU pattern:
//! 1. Acquire command buffer
//! 2. Acquire swapchain texture (the screen)
//! 3. Begin render pass (clears the screen)
//! 4. Record draw commands
//! 5. End render pass
//! 6. Submit command buffer

const std = @import("std");
const sdl = @import("sdl.zig");

// Use shared SDL bindings to avoid opaque type conflicts
const c = sdl.c;

/// Renderer manages the SDL_GPU device and handles frame rendering.
pub const Renderer = struct {
    device: *c.SDL_GPUDevice,
    window: *c.SDL_Window,

    /// Initialize the GPU renderer for a window.
    /// This creates the GPU device and claims the window for rendering.
    pub fn init(window: *c.SDL_Window) !Renderer {
        // Create GPU device - SDL chooses the best backend automatically
        // We request no specific shader formats, letting SDL pick the native one
        const device = c.SDL_CreateGPUDevice(
            c.SDL_GPU_SHADERFORMAT_SPIRV | c.SDL_GPU_SHADERFORMAT_MSL | c.SDL_GPU_SHADERFORMAT_DXIL,
            true, // debug_mode: enables validation layers
            null, // No specific device preference
        ) orelse {
            std.debug.print("SDL_CreateGPUDevice failed: {s}\n", .{c.SDL_GetError()});
            return error.GPUDeviceCreationFailed;
        };
        errdefer c.SDL_DestroyGPUDevice(device);

        // Log which GPU driver SDL selected
        const driver_name = c.SDL_GetGPUDeviceDriver(device);
        std.debug.print("GPU Device created: {s}\n", .{driver_name});

        // Claim the window for GPU rendering (creates the swapchain)
        if (!c.SDL_ClaimWindowForGPUDevice(device, window)) {
            std.debug.print("SDL_ClaimWindowForGPUDevice failed: {s}\n", .{c.SDL_GetError()});
            return error.GPUWindowClaimFailed;
        }

        return Renderer{
            .device = device,
            .window = window,
        };
    }

    /// Clean up GPU resources
    pub fn deinit(self: *Renderer) void {
        c.SDL_ReleaseWindowFromGPUDevice(self.device, self.window);
        c.SDL_DestroyGPUDevice(self.device);
    }

    /// Render a frame. Currently just clears to the specified color.
    /// Returns false if rendering failed (e.g., window minimized).
    ///
    /// Parameters:
    /// - clear_color: RGBA values (0.0 to 1.0)
    /// - alpha: Interpolation factor from timing (unused for now)
    pub fn renderFrame(self: *Renderer, clear_color: [4]f32, alpha: f32) bool {
        _ = alpha; // Will use for interpolation later

        // Step 1: Acquire a command buffer
        const cmd = c.SDL_AcquireGPUCommandBuffer(self.device) orelse {
            std.debug.print("SDL_AcquireGPUCommandBuffer failed: {s}\n", .{c.SDL_GetError()});
            return false;
        };

        // Step 2: Acquire the swapchain texture (what we render to)
        var swapchain_texture: ?*c.SDL_GPUTexture = null;
        if (!c.SDL_AcquireGPUSwapchainTexture(cmd, self.window, &swapchain_texture, null, null)) {
            std.debug.print("SDL_AcquireGPUSwapchainTexture failed: {s}\n", .{c.SDL_GetError()});
            // Must still submit the command buffer even on failure
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return false;
        }

        // If swapchain_texture is null, window might be minimized - skip rendering
        if (swapchain_texture == null) {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return true; // Not an error, just nothing to render
        }

        // Step 3: Begin render pass with clear color
        const color_target = c.SDL_GPUColorTargetInfo{
            .texture = swapchain_texture,
            .mip_level = 0,
            .layer_or_depth_plane = 0,
            .clear_color = c.SDL_FColor{
                .r = clear_color[0],
                .g = clear_color[1],
                .b = clear_color[2],
                .a = clear_color[3],
            },
            .load_op = c.SDL_GPU_LOADOP_CLEAR, // Clear the texture
            .store_op = c.SDL_GPU_STOREOP_STORE, // Store the result
            .resolve_texture = null,
            .resolve_mip_level = 0,
            .resolve_layer = 0,
            .cycle = false,
            .cycle_resolve_texture = false,
            .padding1 = 0,
            .padding2 = 0,
        };

        const render_pass = c.SDL_BeginGPURenderPass(
            cmd,
            &color_target,
            1, // num_color_targets
            null, // depth_stencil_target (none for now)
        ) orelse {
            std.debug.print("SDL_BeginGPURenderPass failed: {s}\n", .{c.SDL_GetError()});
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return false;
        };

        // Step 4: Draw commands would go here
        // For now, we just clear - drawing comes in Phase 2!

        // Step 5: End render pass
        c.SDL_EndGPURenderPass(render_pass);

        // Step 6: Submit command buffer
        if (!c.SDL_SubmitGPUCommandBuffer(cmd)) {
            std.debug.print("SDL_SubmitGPUCommandBuffer failed: {s}\n", .{c.SDL_GetError()});
            return false;
        }

        return true;
    }

    /// Get the window dimensions (useful for viewport calculations)
    pub fn getWindowSize(self: *const Renderer) struct { width: i32, height: i32 } {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSize(self.window, &w, &h);
        return .{ .width = w, .height = h };
    }
};

// ============================================================================
// Color Constants (for convenience)
// ============================================================================

pub const Colors = struct {
    /// Cornflower blue - the classic XNA/DirectX test color
    pub const CORNFLOWER_BLUE = [4]f32{ 0.392, 0.584, 0.929, 1.0 };

    /// Pure black
    pub const BLACK = [4]f32{ 0.0, 0.0, 0.0, 1.0 };

    /// Dark gray (good for editors)
    pub const DARK_GRAY = [4]f32{ 0.1, 0.1, 0.1, 1.0 };

    /// Forest green
    pub const FOREST_GREEN = [4]f32{ 0.133, 0.545, 0.133, 1.0 };
};

// ============================================================================
// Tests
// ============================================================================

test "Colors are valid" {
    // All color components should be in 0.0-1.0 range
    for (Colors.CORNFLOWER_BLUE) |component| {
        try std.testing.expect(component >= 0.0 and component <= 1.0);
    }
}
