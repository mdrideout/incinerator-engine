//! macOS-local Unix-domain transport for the typed developer endpoint.
//!
//! The transport thread owns only socket bytes and request/response
//! correlation. It never receives the graphical `App`, simulation, renderer,
//! editor, persistence, or feature owners. The composition polls typed values
//! on its main thread and responds after routing them through those owners.

const std = @import("std");
const engine = @import("engine_contracts");
const protocol = @import("sandbox_developer_protocol");

pub const Config = struct {
    /// Absolute private directory containing the atomic discovery document.
    developer_directory: []const u8,
    run_id: protocol.RunId,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    run_id: protocol.RunId,
    developer_directory: []u8,
    discovery_path: []u8,
    discovery_lock_path: []u8,
    endpoint_path: engine.developer_endpoint.Path,
    listener: ?std.Io.net.Server = null,
    thread: ?std.Thread = null,

    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    lifecycle: protocol.Lifecycle = .starting,
    stopping: bool = false,
    active_stream: ?std.Io.net.Stream = null,
    pending_request: ?protocol.Request = null,
    pending_taken: bool = false,
    response_json: ?[]u8 = null,
    failure_bytes: [128]u8 = @splat(0),
    failure_len: u8 = 0,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: Config,
    ) !*Server {
        try config.run_id.validate();
        if (config.developer_directory.len == 0 or
            config.developer_directory[0] != '/')
        {
            return error.DeveloperDirectoryNotAbsolute;
        }

        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);
        const directory = try allocator.dupe(u8, config.developer_directory);
        errdefer allocator.free(directory);
        const discovery_path = try std.fs.path.join(
            allocator,
            &.{ config.developer_directory, "discovery.json" },
        );
        errdefer allocator.free(discovery_path);
        const discovery_lock_path = try std.fs.path.join(
            allocator,
            &.{ config.developer_directory, "discovery.lock" },
        );
        errdefer allocator.free(discovery_lock_path);
        var socket_buffer: [engine.developer_endpoint.max_endpoint_path_bytes]u8 = undefined;
        const socket_path = try std.fmt.bufPrint(
            &socket_buffer,
            "/tmp/incinerator-dev-{x}.sock",
            .{config.run_id.nonce},
        );
        self.* = .{
            .allocator = allocator,
            .io = io,
            .run_id = config.run_id,
            .developer_directory = directory,
            .discovery_path = discovery_path,
            .discovery_lock_path = discovery_lock_path,
            .endpoint_path = try engine.developer_endpoint.Path.init(socket_path),
        };

        _ = try std.Io.Dir.createDirPathStatus(
            .cwd(),
            io,
            self.developer_directory,
            std.Io.Dir.Permissions.fromMode(0o700),
        );
        var directory_handle = try std.Io.Dir.openDirAbsolute(
            io,
            self.developer_directory,
            .{ .iterate = true },
        );
        defer directory_handle.close(io);
        try directory_handle.setPermissions(
            io,
            std.Io.Dir.Permissions.fromMode(0o700),
        );

        try self.claimDiscovery();
        // Every error after startup publication must retire any listener/thread,
        // remove its socket, and replace the transient discovery document before
        // the allocation errdefers release `self`.
        errdefer self.stop();
        const address = try std.Io.net.UnixAddress.init(self.endpoint_path.slice());
        self.listener = address.listen(io, .{}) catch |err| {
            self.setFailure(@errorName(err));
            try self.writeDiscovery(.failed, false, self.failure());
            return self;
        };
        try std.Io.Dir.cwd().setFilePermissions(
            io,
            self.endpoint_path.slice(),
            std.Io.File.Permissions.fromMode(0o600),
            .{ .follow_symlinks = false },
        );
        self.thread = std.Thread.spawn(.{}, transportMain, .{self}) catch |err| {
            self.listener.?.deinit(io);
            self.listener = null;
            std.Io.Dir.deleteFileAbsolute(io, self.endpoint_path.slice()) catch {};
            self.setFailure(@errorName(err));
            try self.writeDiscovery(.failed, false, self.failure());
            return self;
        };
        self.mutex.lockUncancelable(self.io);
        self.lifecycle = .available;
        self.mutex.unlock(self.io);
        try self.writeDiscovery(.available, true, null);
        return self;
    }

    pub fn destroy(self: *Server) void {
        self.stop();
        const allocator = self.allocator;
        allocator.free(self.developer_directory);
        allocator.free(self.discovery_path);
        allocator.free(self.discovery_lock_path);
        allocator.destroy(self);
    }

    pub fn stop(self: *Server) void {
        self.mutex.lockUncancelable(self.io);
        if (self.stopping or self.lifecycle == .stopped) {
            self.mutex.unlock(self.io);
            return;
        }
        self.stopping = true;
        if (self.lifecycle == .available) self.lifecycle = .stopping;
        self.condition.broadcast(self.io);
        // `active_stream` is published and retired under this mutex. Shutdown
        // an incomplete read before releasing the lock so the transport thread
        // cannot close the descriptor between our snapshot and this syscall.
        // Once a request is admitted, leave the stream writable: the waiter
        // wakes from the condition and returns a typed `endpoint_stopping`
        // response before retiring the connection.
        if (self.pending_request == null) {
            if (self.active_stream) |stream| stream.shutdown(self.io, .both) catch {};
        }
        self.mutex.unlock(self.io);
        self.writeDiscovery(.stopping, true, null) catch {};

        if (self.listener != null) {
            const address = std.Io.net.UnixAddress.init(
                self.endpoint_path.slice(),
            ) catch unreachable;
            if (address.connect(self.io)) |wake| {
                wake.close(self.io);
            } else |_| {}
        }
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.listener) |*listener| listener.deinit(self.io);
        self.listener = null;
        std.Io.Dir.deleteFileAbsolute(self.io, self.endpoint_path.slice()) catch {};

        self.mutex.lockUncancelable(self.io);
        if (self.response_json) |bytes| self.allocator.free(bytes);
        self.response_json = null;
        self.pending_request = null;
        self.pending_taken = false;
        self.active_stream = null;
        self.lifecycle = .stopped;
        self.mutex.unlock(self.io);
        self.writeDiscovery(.stopped, false, null) catch {};
    }

    pub fn discovery(self: *Server) engine.developer_endpoint.Discovery {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var result = engine.developer_endpoint.Discovery{
            .lifecycle = self.lifecycle,
            .run_id = self.run_id,
            .protocol_cohort = protocol.protocol_cohort,
            .endpoint_path = switch (self.lifecycle) {
                .starting, .available, .stopping => self.endpoint_path,
                else => null,
            },
            .schema_digest = if (self.lifecycle == .available)
                protocol.schemaDigest()
            else
                null,
        };
        for (protocol.schemaCatalog(), 0..) |schema, index| {
            result.schema_ids[index] = schema.id;
        }
        result.schema_count = @intCast(protocol.schemaCatalog().len);
        return result;
    }

    pub fn discoveryPath(self: *const Server) []const u8 {
        return self.discovery_path;
    }

    /// Returns each admitted request exactly once. The request contains only
    /// owned scalar/tagged values, so no transport allocation crosses into the
    /// composition.
    pub fn takeRequest(self: *Server) ?protocol.Request {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.pending_taken) return null;
        const request = self.pending_request orelse return null;
        self.pending_taken = true;
        return request;
    }

    pub fn respond(self: *Server, response: protocol.Response) !void {
        try response.validate();
        if (!std.meta.eql(response.run_id, self.run_id)) {
            return error.DeveloperRunMismatch;
        }
        const bytes = try protocol.encodeResponseAlloc(self.allocator, response);
        errdefer self.allocator.free(bytes);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const pending = self.pending_request orelse return error.NoDeveloperRequestPending;
        if (!self.pending_taken) return error.DeveloperRequestNotTaken;
        protocol.validateResponseForRequest(pending, response) catch
            return error.DeveloperResponseCorrelationMismatch;
        if (self.response_json != null) return error.DeveloperResponseAlreadyQueued;
        self.response_json = bytes;
        self.condition.signal(self.io);
    }

    fn transportMain(self: *Server) void {
        while (true) {
            const stream = self.listener.?.accept(self.io) catch |err| {
                self.mutex.lockUncancelable(self.io);
                const stopping = self.stopping;
                if (!stopping) {
                    self.lifecycle = .failed;
                    self.setFailureLocked(@errorName(err));
                }
                self.mutex.unlock(self.io);
                if (!stopping) self.writeDiscovery(.failed, false, self.failure()) catch {};
                return;
            };

            self.mutex.lockUncancelable(self.io);
            if (self.stopping) {
                self.mutex.unlock(self.io);
                stream.close(self.io);
                return;
            }
            self.active_stream = stream;
            self.mutex.unlock(self.io);

            self.handleConnection(stream) catch {};

            self.mutex.lockUncancelable(self.io);
            self.active_stream = null;
            const stopping = self.stopping;
            self.mutex.unlock(self.io);
            // Retire the shared handle before closing it so `stop` can never
            // observe a descriptor that has already been closed.
            stream.close(self.io);
            if (stopping) return;
        }
    }

    fn handleConnection(self: *Server, stream: std.Io.net.Stream) !void {
        var read_buffer: [4096]u8 = undefined;
        var stream_reader = stream.reader(self.io, &read_buffer);
        const header = try protocol.readHeader(&stream_reader.interface);
        if (header.kind != .request) {
            try self.writeTransportFailure(
                stream,
                header.request_id,
                protocol.query_schema,
                .malformed_frame,
                "expected a request frame",
            );
            return;
        }
        if (header.protocol_cohort != protocol.protocol_cohort) {
            try self.writeTransportFailure(
                stream,
                header.request_id,
                protocol.query_schema,
                .unknown_protocol_cohort,
                "frame protocol cohort is not supported",
            );
            return;
        }
        const payload = protocol.readPayloadAlloc(
            self.allocator,
            &stream_reader.interface,
            header,
        ) catch |err| switch (err) {
            error.FrameChecksumMismatch,
            error.FrameLengthMismatch,
            error.FrameLengthNotRepresentable,
            error.FramePayloadTooLarge,
            => {
                try self.writeTransportFailure(
                    stream,
                    header.request_id,
                    protocol.query_schema,
                    .malformed_frame,
                    @errorName(err),
                );
                return;
            },
            else => return err,
        };
        defer self.allocator.free(payload);
        var parsed = protocol.parseRequestSyntax(self.allocator, payload) catch |err| {
            try self.writeTransportFailure(
                stream,
                header.request_id,
                protocol.query_schema,
                .malformed_json,
                @errorName(err),
            );
            return;
        };
        defer parsed.deinit();
        const request = parsed.value;
        request.validate() catch |err| {
            const code: protocol.FailureCode = switch (err) {
                error.ProtocolCohortMismatch => .unknown_protocol_cohort,
                error.UnknownDeveloperSchema => .unknown_schema,
                error.CommandSchemaMismatch => .command_schema_mismatch,
                else => .invalid_request,
            };
            try self.writeTransportFailure(
                stream,
                header.request_id,
                if (protocol.schemaIsRegistered(request.schema_id))
                    request.schema_id
                else
                    protocol.query_schema,
                code,
                @errorName(err),
            );
            return;
        };
        if (request.request_id != header.request_id) {
            try self.writeTransportFailure(
                stream,
                header.request_id,
                request.schema_id,
                .invalid_request,
                "request body ID does not match its frame",
            );
            return;
        }
        if (!std.meta.eql(request.expected_run_id, self.run_id)) {
            try self.writeTransportFailure(
                stream,
                request.request_id,
                request.schema_id,
                .run_mismatch,
                "request expected a different editor run",
            );
            return;
        }

        self.mutex.lockUncancelable(self.io);
        if (self.stopping) {
            self.mutex.unlock(self.io);
            try self.writeTransportFailure(
                stream,
                request.request_id,
                request.schema_id,
                .endpoint_stopping,
                "developer endpoint is stopping",
            );
            return;
        }
        if (self.pending_request != null) {
            self.mutex.unlock(self.io);
            try self.writeTransportFailure(
                stream,
                request.request_id,
                request.schema_id,
                .owner_busy,
                "developer request mailbox is occupied",
            );
            return;
        }
        self.pending_request = request;
        self.pending_taken = false;
        self.response_json = null;
        while (self.response_json == null and !self.stopping) {
            self.condition.waitUncancelable(self.io, &self.mutex);
        }
        if (self.stopping) {
            self.mutex.unlock(self.io);
            self.writeTransportFailure(
                stream,
                request.request_id,
                request.schema_id,
                .endpoint_stopping,
                "developer endpoint stopped before producing a response",
            ) catch {};
            return;
        }
        const response_json = self.response_json.?;
        self.response_json = null;
        self.pending_request = null;
        self.pending_taken = false;
        self.mutex.unlock(self.io);
        defer self.allocator.free(response_json);

        var write_buffer: [4096]u8 = undefined;
        var stream_writer = stream.writer(self.io, &write_buffer);
        try protocol.writeFrame(
            &stream_writer.interface,
            .response,
            protocol.protocol_cohort,
            request.request_id,
            response_json,
        );
    }

    fn writeTransportFailure(
        self: *Server,
        stream: std.Io.net.Stream,
        request_id: u64,
        schema_id: protocol.SchemaId,
        code: protocol.FailureCode,
        detail: []const u8,
    ) !void {
        const response = protocol.Response{
            .request_id = request_id,
            .schema_id = schema_id,
            .run_id = self.run_id,
            .outcome = .{ .failure = .{ .code = code, .detail = detail } },
        };
        const json = try protocol.encodeResponseAlloc(self.allocator, response);
        defer self.allocator.free(json);
        var write_buffer: [4096]u8 = undefined;
        var stream_writer = stream.writer(self.io, &write_buffer);
        try protocol.writeFrame(
            &stream_writer.interface,
            .response,
            protocol.protocol_cohort,
            request_id,
            json,
        );
    }

    fn writeDiscovery(
        self: *Server,
        lifecycle: protocol.Lifecycle,
        include_path: bool,
        failure_text: ?[]const u8,
    ) !void {
        var lock = try self.acquireDiscoveryLock();
        defer {
            lock.unlock(self.io);
            lock.close(self.io);
        }
        var current = try self.readValidDiscoveryLocked();
        defer if (current) |*document| document.deinit();
        const owner = current orelse return;
        if (!std.meta.eql(owner.value.run_id, self.run_id)) return;
        try self.writeDiscoveryLocked(lifecycle, include_path, failure_text);
    }

    /// Claims the single well-known discovery document while serializing with
    /// every other editor process. A previous run can contribute only an exact
    /// engine socket name, and that socket is retired only when it is both a
    /// Unix-domain socket and no longer accepts a connection.
    fn claimDiscovery(self: *Server) !void {
        var lock = try self.acquireDiscoveryLock();
        defer {
            lock.unlock(self.io);
            lock.close(self.io);
        }
        var previous = try self.readValidDiscoveryLocked();
        defer if (previous) |*document| document.deinit();
        if (previous) |document| {
            if (document.value.endpoint_path) |path| {
                try removeVerifiedStaleSocket(self.io, path);
            }
        }
        try self.prepareEndpointPathLocked();
        try self.writeDiscoveryLocked(.starting, true, null);
    }

    fn acquireDiscoveryLock(self: *const Server) !std.Io.File {
        var lock = std.Io.Dir.createFileAbsolute(self.io, self.discovery_lock_path, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
            .lock = .exclusive,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => try std.Io.Dir.openFileAbsolute(
                self.io,
                self.discovery_lock_path,
                .{
                    .mode = .read_write,
                    .allow_directory = false,
                    .lock = .exclusive,
                    .follow_symlinks = false,
                },
            ),
            else => return err,
        };
        errdefer lock.close(self.io);
        const stat = try lock.stat(self.io);
        if (stat.kind != .file) return error.InvalidDeveloperDiscoveryLock;
        try lock.setPermissions(
            self.io,
            std.Io.File.Permissions.fromMode(0o600),
        );
        return lock;
    }

    fn readValidDiscoveryLocked(
        self: *const Server,
    ) !?std.json.Parsed(protocol.DiscoveryDocument) {
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            self.discovery_path,
            self.allocator,
            .limited(protocol.max_discovery_document_bytes),
        ) catch |err| switch (err) {
            error.FileNotFound, error.StreamTooLong => return null,
            else => return err,
        };
        defer self.allocator.free(bytes);
        var parsed = std.json.parseFromSlice(
            protocol.DiscoveryDocument,
            self.allocator,
            bytes,
            .{ .allocate = .alloc_always },
        ) catch return null;
        errdefer parsed.deinit();
        parsed.value.validate() catch return null;
        return parsed;
    }

    fn prepareEndpointPathLocked(self: *const Server) !void {
        const path = self.endpoint_path.slice();
        if (!isCanonicalEndpointPath(path)) return error.InvalidDeveloperEndpointPath;
        const stat = std.Io.Dir.cwd().statFile(
            self.io,
            path,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        if (stat.kind != .unix_domain_socket) {
            return error.DeveloperEndpointPathOccupied;
        }
        if (socketAcceptsConnection(self.io, path)) {
            return error.DeveloperEndpointAlreadyRunning;
        }
        try std.Io.Dir.deleteFileAbsolute(self.io, path);
    }

    fn writeDiscoveryLocked(
        self: *Server,
        lifecycle: protocol.Lifecycle,
        include_path: bool,
        failure_text: ?[]const u8,
    ) !void {
        var ids: [engine.developer_endpoint.max_schemas]protocol.SchemaId = undefined;
        for (protocol.schemaCatalog(), 0..) |schema, index| ids[index] = schema.id;
        const document = protocol.DiscoveryDocument{
            .lifecycle = lifecycle,
            .run_id = self.run_id,
            .endpoint_path = if (include_path) self.endpoint_path.slice() else null,
            .schema_ids = ids[0..protocol.schemaCatalog().len],
            .schema_digest = if (lifecycle == .available)
                protocol.schemaDigest()
            else
                null,
            .failure = failure_text,
        };
        try document.validate();
        const json = try std.json.Stringify.valueAlloc(self.allocator, document, .{});
        defer self.allocator.free(json);
        var atomic = try std.Io.Dir.cwd().createFileAtomic(self.io, self.discovery_path, .{
            .replace = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, json);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
    }

    fn setFailure(self: *Server, detail: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.lifecycle = .failed;
        self.setFailureLocked(detail);
    }

    fn setFailureLocked(self: *Server, detail: []const u8) void {
        const count = @min(detail.len, self.failure_bytes.len);
        @memcpy(self.failure_bytes[0..count], detail[0..count]);
        self.failure_len = @intCast(count);
    }

    fn failure(self: *const Server) ?[]const u8 {
        return if (self.failure_len == 0)
            null
        else
            self.failure_bytes[0..self.failure_len];
    }
};

const endpoint_prefix = "/tmp/incinerator-dev-";
const endpoint_suffix = ".sock";

fn isCanonicalEndpointPath(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, endpoint_prefix) or
        !std.mem.endsWith(u8, path, endpoint_suffix))
    {
        return false;
    }
    const nonce_text = path[endpoint_prefix.len .. path.len - endpoint_suffix.len];
    if (nonce_text.len == 0) return false;
    const nonce = std.fmt.parseInt(u64, nonce_text, 16) catch return false;
    if (nonce == 0) return false;
    var expected_buffer: [engine.developer_endpoint.max_endpoint_path_bytes]u8 = undefined;
    const expected = std.fmt.bufPrint(
        &expected_buffer,
        endpoint_prefix ++ "{x}" ++ endpoint_suffix,
        .{nonce},
    ) catch return false;
    return std.mem.eql(u8, path, expected);
}

fn socketAcceptsConnection(io: std.Io, path: []const u8) bool {
    _ = io;
    const socket_fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (std.c.errno(socket_fd) != .SUCCESS) return true;
    defer _ = std.c.close(socket_fd);

    var address = std.c.sockaddr.un{ .path = @splat(0) };
    if (path.len >= address.path.len) return true;
    @memcpy(address.path[0..path.len], path);
    const address_len = @offsetOf(std.c.sockaddr.un, "path") + path.len + 1;
    address.len = @intCast(address_len);
    const result = std.c.connect(
        socket_fd,
        @ptrCast(&address),
        @intCast(address_len),
    );
    return switch (std.c.errno(result)) {
        .SUCCESS => true,
        .CONNREFUSED, .NOENT => false,
        else => true,
    };
}

fn removeVerifiedStaleSocket(io: std.Io, path: []const u8) !void {
    if (!isCanonicalEndpointPath(path)) return;
    const stat = std.Io.Dir.cwd().statFile(
        io,
        path,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .unix_domain_socket) return;
    if (socketAcceptsConnection(io, path)) return;
    std.Io.Dir.deleteFileAbsolute(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn writeDiscoveryFixture(
    allocator: std.mem.Allocator,
    io: std.Io,
    discovery_path: []const u8,
    run_id: protocol.RunId,
    endpoint_path: []const u8,
) !void {
    var ids: [engine.developer_endpoint.max_schemas]protocol.SchemaId = undefined;
    for (protocol.schemaCatalog(), 0..) |schema, index| ids[index] = schema.id;
    const document = protocol.DiscoveryDocument{
        .lifecycle = .available,
        .run_id = run_id,
        .endpoint_path = endpoint_path,
        .schema_ids = ids[0..protocol.schemaCatalog().len],
        .schema_digest = protocol.schemaDigest(),
    };
    try document.validate();
    const json = try std.json.Stringify.valueAlloc(allocator, document, .{});
    defer allocator.free(json);
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, discovery_path, .{
        .replace = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, json);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

fn readDiscoveryFixture(
    allocator: std.mem.Allocator,
    io: std.Io,
    discovery_path: []const u8,
) !std.json.Parsed(protocol.DiscoveryDocument) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        discovery_path,
        allocator,
        .limited(protocol.max_discovery_document_bytes),
    );
    defer allocator.free(bytes);
    var document = try std.json.parseFromSlice(
        protocol.DiscoveryDocument,
        allocator,
        bytes,
        .{ .allocate = .alloc_always },
    );
    errdefer document.deinit();
    try document.value.validate();
    return document;
}

test "discovery path is private and endpoint lifecycle stops cleanly" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var server = try Server.create(std.testing.allocator, std.testing.io, .{
        .developer_directory = root,
        .run_id = .{ .started_wall_unix_ms = 1, .nonce = 0xea05_0001 },
    });
    defer server.destroy();
    try std.testing.expectEqual(protocol.Lifecycle.available, server.discovery().lifecycle);
    try std.testing.expectEqual(@as(u8, 5), server.discovery().schema_count);
    const directory_stat = try std.Io.Dir.cwd().statFile(
        std.testing.io,
        root,
        .{ .follow_symlinks = false },
    );
    try std.testing.expectEqual(std.Io.File.Kind.directory, directory_stat.kind);
    try std.testing.expectEqual(
        @as(std.posix.mode_t, 0o700),
        directory_stat.permissions.toMode() & 0o777,
    );
    const discovery_stat = try temporary.dir.statFile(
        std.testing.io,
        "discovery.json",
        .{},
    );
    try std.testing.expect(discovery_stat.size != 0);
    try std.testing.expectEqual(
        @as(std.posix.mode_t, 0o600),
        discovery_stat.permissions.toMode() & 0o777,
    );
    const lock_stat = try temporary.dir.statFile(
        std.testing.io,
        "discovery.lock",
        .{ .follow_symlinks = false },
    );
    try std.testing.expectEqual(std.Io.File.Kind.file, lock_stat.kind);
    try std.testing.expectEqual(
        @as(std.posix.mode_t, 0o600),
        lock_stat.permissions.toMode() & 0o777,
    );
    const endpoint_stat = try std.Io.Dir.cwd().statFile(
        std.testing.io,
        server.endpoint_path.slice(),
        .{ .follow_symlinks = false },
    );
    try std.testing.expectEqual(std.Io.File.Kind.unix_domain_socket, endpoint_stat.kind);
    try std.testing.expectEqual(
        @as(std.posix.mode_t, 0o600),
        endpoint_stat.permissions.toMode() & 0o777,
    );
    server.stop();
    try std.testing.expectEqual(protocol.Lifecycle.stopped, server.discovery().lifecycle);
}

test "startup refuses a non-socket endpoint obstruction without claiming discovery" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const nonce = std.hash.Wyhash.hash(0xea05_0002, root) | 1;
    var socket_buffer: [engine.developer_endpoint.max_endpoint_path_bytes]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(
        &socket_buffer,
        "/tmp/incinerator-dev-{x}.sock",
        .{nonce},
    );

    // A directory cannot be mistaken for a retired socket. Startup refuses it
    // before taking ownership of the shared discovery document.
    try std.Io.Dir.createDirAbsolute(
        std.testing.io,
        socket_path,
        std.Io.Dir.Permissions.fromMode(0o700),
    );
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, socket_path) catch {};

    if (Server.create(std.testing.allocator, std.testing.io, .{
        .developer_directory = root,
        .run_id = .{ .started_wall_unix_ms = 1, .nonce = nonce },
    })) |server| {
        defer server.destroy();
        return error.ExpectedDeveloperEndpointStartupFailure;
    } else |_| {}

    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.statFile(
            std.testing.io,
            "discovery.json",
            .{ .follow_symlinks = false },
        ),
    );
}

test "older editor shutdown cannot replace newer editor discovery" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const first_nonce = std.hash.Wyhash.hash(0xea05_0003, root) | 1;
    const second_nonce = std.hash.Wyhash.hash(0xea05_0004, root) | 1;

    var first = try Server.create(std.testing.allocator, std.testing.io, .{
        .developer_directory = root,
        .run_id = .{ .started_wall_unix_ms = 1, .nonce = first_nonce },
    });
    defer first.destroy();
    var second = try Server.create(std.testing.allocator, std.testing.io, .{
        .developer_directory = root,
        .run_id = .{ .started_wall_unix_ms = 2, .nonce = second_nonce },
    });
    defer second.destroy();

    first.stop();
    var document = try readDiscoveryFixture(
        std.testing.allocator,
        std.testing.io,
        second.discoveryPath(),
    );
    defer document.deinit();
    try std.testing.expectEqual(protocol.Lifecycle.available, document.value.lifecycle);
    try std.testing.expect(std.meta.eql(second.discovery().run_id, document.value.run_id));
    try std.testing.expectEqualStrings(
        second.endpoint_path.slice(),
        document.value.endpoint_path.?,
    );
    try std.testing.expect(socketAcceptsConnection(
        std.testing.io,
        second.endpoint_path.slice(),
    ));
}

test "new editor retires a validated crash-stale socket" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const stale_nonce = std.hash.Wyhash.hash(0xea05_0005, root) | 1;
    const current_nonce = std.hash.Wyhash.hash(0xea05_0006, root) | 1;
    var stale_path_buffer: [engine.developer_endpoint.max_endpoint_path_bytes]u8 = undefined;
    const stale_path = try std.fmt.bufPrint(
        &stale_path_buffer,
        endpoint_prefix ++ "{x}" ++ endpoint_suffix,
        .{stale_nonce},
    );
    std.Io.Dir.deleteFileAbsolute(std.testing.io, stale_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, stale_path) catch {};
    const stale_address = try std.Io.net.UnixAddress.init(stale_path);
    var stale_listener = try stale_address.listen(std.testing.io, .{});
    stale_listener.deinit(std.testing.io);
    const stale_stat = try std.Io.Dir.cwd().statFile(
        std.testing.io,
        stale_path,
        .{ .follow_symlinks = false },
    );
    try std.testing.expectEqual(std.Io.File.Kind.unix_domain_socket, stale_stat.kind);

    const discovery_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "discovery.json" },
    );
    defer std.testing.allocator.free(discovery_path);
    try writeDiscoveryFixture(
        std.testing.allocator,
        std.testing.io,
        discovery_path,
        .{ .started_wall_unix_ms = 1, .nonce = stale_nonce },
        stale_path,
    );

    var server = try Server.create(std.testing.allocator, std.testing.io, .{
        .developer_directory = root,
        .run_id = .{ .started_wall_unix_ms = 2, .nonce = current_nonce },
    });
    defer server.destroy();
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(
            std.testing.io,
            stale_path,
            .{ .follow_symlinks = false },
        ),
    );
    var document = try readDiscoveryFixture(
        std.testing.allocator,
        std.testing.io,
        discovery_path,
    );
    defer document.deinit();
    try std.testing.expect(std.meta.eql(server.discovery().run_id, document.value.run_id));
    try std.testing.expectEqual(protocol.Lifecycle.available, document.value.lifecycle);
}

test "stale discovery cannot nominate an arbitrary path for deletion" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const prior_nonce = std.hash.Wyhash.hash(0xea05_0007, root) | 1;
    const current_nonce = std.hash.Wyhash.hash(0xea05_0008, root) | 1;
    var arbitrary_buffer: [128]u8 = undefined;
    const arbitrary_path = try std.fmt.bufPrint(
        &arbitrary_buffer,
        "/tmp/incinerator-keep-{x}",
        .{prior_nonce},
    );
    std.Io.Dir.deleteFileAbsolute(std.testing.io, arbitrary_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, arbitrary_path) catch {};
    var arbitrary = try std.Io.Dir.createFileAbsolute(std.testing.io, arbitrary_path, .{
        .exclusive = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    arbitrary.close(std.testing.io);

    const discovery_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "discovery.json" },
    );
    defer std.testing.allocator.free(discovery_path);
    try writeDiscoveryFixture(
        std.testing.allocator,
        std.testing.io,
        discovery_path,
        .{ .started_wall_unix_ms = 1, .nonce = prior_nonce },
        arbitrary_path,
    );

    var server = try Server.create(std.testing.allocator, std.testing.io, .{
        .developer_directory = root,
        .run_id = .{ .started_wall_unix_ms = 2, .nonce = current_nonce },
    });
    defer server.destroy();
    const retained = try std.Io.Dir.cwd().statFile(
        std.testing.io,
        arbitrary_path,
        .{ .follow_symlinks = false },
    );
    try std.testing.expectEqual(std.Io.File.Kind.file, retained.kind);
}
