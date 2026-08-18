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

/// SDL 3.4.14's Metal backend accidentally implements SDL_QueryGPUFence as
/// "is busy", the inverse of the documented public API. The correction is
/// centralized here so every engine fence owner observes the same contract.
/// Remove the macOS inversion when the exact SDL cohort advances to a release
/// containing upstream commit b340ddcd7b44511f7b49005ba4a91a3c9907f77e.
pub fn gpuFenceSignaled(device: *c.SDL_GPUDevice, fence: *c.SDL_GPUFence) bool {
    return !c.SDL_QueryGPUFence(device, fence);
}
