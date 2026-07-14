//! Presentation-only surface for the MP2 graphical client. This composition
//! intentionally exposes rendering capabilities and no simulation authority.

pub const sdl = @import("sdl.zig");
pub const renderer = @import("renderer.zig");
pub const primitives = @import("primitives.zig");
pub const mesh = @import("mesh.zig");
pub const camera = @import("camera.zig");

pub const c = sdl.c;
