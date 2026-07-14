//! Focused test root for the visual district-streaming host.
//!
//! The production client and this test root intentionally share the existing
//! `src/` visual module boundary while that renderer graph still uses relative
//! imports for SDL, meshes, textures, and streamed scene residency.

const std = @import("std");
const district_streaming_host = @import("hosts/district_streaming_host.zig");

test "district streaming host declarations and tests are discovered" {
    std.testing.refAllDecls(district_streaming_host);
}
