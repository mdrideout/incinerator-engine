//! sdl.zig - Shared SDL3 C Bindings
//!
//! This module provides a single source of truth for SDL3 C bindings.
//! All engine modules should import SDL types from here to avoid
//! the "different opaque types" issue that occurs when @cImport is
//! called from multiple files.
//!
//! Usage:
//!   const sdl = @import("sdl.zig");
//!   const c = sdl.c;  // Access all SDL functions/types

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

// Re-export commonly used types for convenience
pub const Window = c.SDL_Window;
pub const Event = c.SDL_Event;
pub const GPUDevice = c.SDL_GPUDevice;
pub const GPUTexture = c.SDL_GPUTexture;
pub const GPUCommandBuffer = c.SDL_GPUCommandBuffer;
pub const GPURenderPass = c.SDL_GPURenderPass;
pub const Scancode = c.SDL_Scancode;
