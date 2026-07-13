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
