//! Private C import boundary for Jolt Physics 5.5.
//!
//! Engine and feature code must depend on `physics.zig` or a narrower engine
//! contract rather than importing this module directly.

pub const c = @cImport({
    @cInclude("joltc.h");
});
