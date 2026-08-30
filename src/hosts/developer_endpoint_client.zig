//! Reusable local client for the versioned Incinerator developer endpoint.
//!
//! The client discovers one editor process, validates its run and schema
//! cohort, then performs one typed request per Unix-domain-socket connection.
//! It has no shell, arbitrary filesystem, or raw object access.

const std = @import("std");
const protocol = @import("sandbox_developer_protocol");

pub const default_discovery_relative_path = "Library/Logs/Incinerator/developer/discovery.json";

pub fn defaultDiscoveryPathAlloc(
    allocator: std.mem.Allocator,
    home_directory: []const u8,
) ![]u8 {
    if (home_directory.len == 0 or home_directory[0] != '/') {
        return error.HomeDirectoryNotAbsolute;
    }
    return std.fs.path.join(allocator, &.{ home_directory, default_discovery_relative_path });
}

pub fn loadDiscovery(
    allocator: std.mem.Allocator,
    io: std.Io,
    discovery_path: []const u8,
) !std.json.Parsed(protocol.DiscoveryDocument) {
    if (discovery_path.len == 0 or discovery_path[0] != '/') {
        return error.DiscoveryPathNotAbsolute;
    }
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        discovery_path,
        allocator,
        .limited(protocol.max_discovery_document_bytes),
    ) catch |err| switch (err) {
        error.StreamTooLong => return error.DiscoveryDocumentTooLarge,
        else => |other| return other,
    };
    defer allocator.free(bytes);
    var discovery = try std.json.parseFromSlice(
        protocol.DiscoveryDocument,
        allocator,
        bytes,
        // The returned Parsed value outlives the temporary file buffer.
        .{ .allocate = .alloc_always },
    );
    errdefer discovery.deinit();
    try discovery.value.validate();
    return discovery;
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    discovery: std.json.Parsed(protocol.DiscoveryDocument),

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        discovery_path: []const u8,
    ) !Client {
        var discovery = try loadDiscovery(allocator, io, discovery_path);
        errdefer discovery.deinit();
        try discovery.value.validate();
        if (discovery.value.lifecycle != .available) {
            return error.DeveloperEndpointUnavailable;
        }
        return .{
            .allocator = allocator,
            .io = io,
            .discovery = discovery,
        };
    }

    pub fn deinit(self: *Client) void {
        self.discovery.deinit();
        self.* = undefined;
    }

    pub fn runId(self: *const Client) protocol.RunId {
        return self.discovery.value.run_id;
    }

    pub fn endpointPath(self: *const Client) []const u8 {
        return self.discovery.value.endpoint_path.?;
    }

    pub fn callCommand(
        self: *Client,
        request_id: u64,
        command: protocol.Command,
    ) !std.json.Parsed(protocol.Response) {
        return self.call(protocol.Request.init(self.runId(), request_id, command));
    }

    /// Performs one request/response exchange. The returned parsed response
    /// owns all string and slice memory and must be deinitialized by the caller.
    pub fn call(
        self: *Client,
        request: protocol.Request,
    ) !std.json.Parsed(protocol.Response) {
        try request.validate();
        if (request.protocol_cohort != self.discovery.value.protocol_cohort) {
            return error.ProtocolCohortMismatch;
        }
        if (!std.meta.eql(request.expected_run_id, self.discovery.value.run_id)) {
            return error.DeveloperRunMismatch;
        }
        var schema_advertised = false;
        for (self.discovery.value.schema_ids) |schema_id| {
            if (std.meta.eql(schema_id, request.schema_id)) {
                schema_advertised = true;
                break;
            }
        }
        if (!schema_advertised) return error.DeveloperSchemaUnavailable;

        const request_json = try protocol.encodeRequestAlloc(self.allocator, request);
        defer self.allocator.free(request_json);

        const address = try std.Io.net.UnixAddress.init(self.endpointPath());
        const stream = address.connect(self.io) catch
            return error.StaleDeveloperEndpoint;
        defer stream.close(self.io);

        var write_buffer: [4096]u8 = undefined;
        var stream_writer = stream.writer(self.io, &write_buffer);
        try protocol.writeFrame(
            &stream_writer.interface,
            .request,
            request.protocol_cohort,
            request.request_id,
            request_json,
        );

        var read_buffer: [4096]u8 = undefined;
        var stream_reader = stream.reader(self.io, &read_buffer);
        var frame = try protocol.readFrameAlloc(self.allocator, &stream_reader.interface);
        defer frame.deinit(self.allocator);
        if (frame.header.kind != .response) return error.ExpectedResponseFrame;
        if (frame.header.protocol_cohort != request.protocol_cohort) {
            return error.ProtocolCohortMismatch;
        }
        if (frame.header.request_id != request.request_id) {
            return error.ResponseRequestMismatch;
        }

        var response = try protocol.parseResponse(self.allocator, frame.payload);
        errdefer response.deinit();
        try protocol.validateResponseForRequest(request, response.value);
        return response;
    }
};

test "default discovery path is explicit and absolute" {
    const path = try defaultDiscoveryPathAlloc(std.testing.allocator, "/Users/tester");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings(
        "/Users/tester/Library/Logs/Incinerator/developer/discovery.json",
        path,
    );
    try std.testing.expectError(
        error.HomeDirectoryNotAbsolute,
        defaultDiscoveryPathAlloc(std.testing.allocator, "relative"),
    );
}

test "available discovery must match the registered schema digest" {
    const catalog = protocol.schemaCatalog();
    var ids: [5]protocol.SchemaId = undefined;
    for (catalog, 0..) |schema, index| ids[index] = schema.id;
    const discovery = protocol.DiscoveryDocument{
        .lifecycle = .available,
        .run_id = .{ .started_wall_unix_ms = 1, .nonce = 2 },
        .endpoint_path = "/tmp/incinerator-test.sock",
        .schema_ids = &ids,
        .schema_digest = protocol.schemaDigest(),
    };
    try discovery.validate();

    var stale = discovery;
    stale.schema_digest.?[0] ^= 0xff;
    try std.testing.expectError(error.SchemaDigestMismatch, stale.validate());
}

test "discovery file read rejects one byte beyond the declared boundary" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const oversized = [_]u8{'x'} ** (protocol.max_discovery_document_bytes + 1);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "oversized.json",
        .data = &oversized,
    });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &root_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}/oversized.json",
        .{root_buffer[0..root_len]},
    );
    try std.testing.expectError(
        error.DiscoveryDocumentTooLarge,
        loadDiscovery(
            std.testing.allocator,
            std.testing.io,
            path,
        ),
    );
}

test "client public surface compiles" {
    std.testing.refAllDecls(Client);
}
