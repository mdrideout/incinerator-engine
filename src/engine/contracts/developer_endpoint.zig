//! Contract-only lifecycle and discovery values for the future local
//! developer-control endpoint. EA0 defines no socket, transport, or client.

const std = @import("std");
const authoring = @import("authoring.zig");
const assets = @import("assets.zig");

pub const max_endpoint_path_bytes: usize = 256;
pub const max_schemas: usize = 16;

pub const Lifecycle = enum(u8) {
    disabled,
    declared,
    starting,
    available,
    stopping,
    stopped,
    failed,
};

pub const SchemaId = struct {
    namespace: u32,
    local: u32,

    pub fn validate(self: SchemaId) !void {
        if (self.namespace == 0) return error.InvalidDeveloperSchemaNamespace;
        if (self.local == 0) return error.InvalidDeveloperSchemaLocal;
    }
};

pub const Path = struct {
    bytes: [max_endpoint_path_bytes]u8 = @splat(0),
    len: u16 = 0,

    pub fn init(value: []const u8) !Path {
        if (value.len == 0 or value.len > max_endpoint_path_bytes) {
            return error.InvalidDeveloperEndpointPath;
        }
        if (value[0] != '/') return error.DeveloperEndpointPathNotAbsolute;
        var result = Path{};
        @memcpy(result.bytes[0..value.len], value);
        result.len = @intCast(value.len);
        return result;
    }

    pub fn slice(self: *const Path) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Discovery = struct {
    lifecycle: Lifecycle,
    run_id: authoring.RunId,
    protocol_cohort: u16,
    endpoint_path: ?Path = null,
    schema_ids: [max_schemas]SchemaId = @splat(.{ .namespace = 0, .local = 0 }),
    schema_count: u8 = 0,
    schema_digest: ?assets.Digest = null,

    pub fn validate(self: Discovery) !void {
        try self.run_id.validate();
        if (self.protocol_cohort == 0) return error.InvalidDeveloperProtocolCohort;
        if (self.schema_count > max_schemas) return error.TooManyDeveloperSchemas;
        for (self.schema_ids[0..self.schema_count]) |id| try id.validate();
        if (self.schema_digest) |digest| try assets.validateDigest(digest);

        switch (self.lifecycle) {
            .disabled, .declared, .stopped, .failed => {},
            .starting, .available, .stopping => if (self.endpoint_path == null) {
                return error.ActiveDeveloperEndpointPathMissing;
            },
        }
        if (self.lifecycle == .available and self.schema_digest == null) {
            return error.AvailableDeveloperSchemaDigestMissing;
        }
    }
};

test "declared endpoint discovery needs no transport path" {
    const discovery = Discovery{
        .lifecycle = .declared,
        .run_id = .{ .started_wall_unix_ms = 1, .nonce = 2 },
        .protocol_cohort = 1,
    };
    try discovery.validate();
}

test "available endpoint requires absolute path and schema digest" {
    var discovery = Discovery{
        .lifecycle = .available,
        .run_id = .{ .started_wall_unix_ms = 1, .nonce = 2 },
        .protocol_cohort = 1,
        .endpoint_path = try Path.init("/tmp/incinerator-dev.sock"),
    };
    try std.testing.expectError(
        error.AvailableDeveloperSchemaDigestMissing,
        discovery.validate(),
    );
    var digest: assets.Digest = @splat(0);
    digest[0] = 1;
    discovery.schema_digest = digest;
    try discovery.validate();
    try std.testing.expectEqualStrings(
        "/tmp/incinerator-dev.sock",
        discovery.endpoint_path.?.bytes[0..discovery.endpoint_path.?.len],
    );
}

test "endpoint path rejects relative discovery" {
    try std.testing.expectError(
        error.DeveloperEndpointPathNotAbsolute,
        Path.init("incinerator-dev.sock"),
    );
}

test "endpoint path admits the declared maximum length" {
    var bytes: [max_endpoint_path_bytes]u8 = @splat('a');
    bytes[0] = '/';
    const path = try Path.init(&bytes);
    try std.testing.expectEqual(max_endpoint_path_bytes, path.slice().len);
}
