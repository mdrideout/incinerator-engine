//! Real Unix-socket integration for every EA0.5 concrete command family.
//!
//! The graphical composition has separate native Metal acceptance. This file
//! keeps transport/client framing deterministic and runnable without SDL.

const std = @import("std");
const protocol = @import("sandbox_developer_protocol");
const transport = @import("developer_endpoint_transport");
const client_module = @import("developer_endpoint_client");

const target = protocol.Target{ .persistent_entity = .{
    .namespace = 1,
    .local = 1,
} };

const Call = struct {
    discovery_path: []const u8,
    request: protocol.Request,
    response: ?std.json.Parsed(protocol.Response) = null,
    failure: ?anyerror = null,

    fn run(self: *Call) void {
        var client = client_module.Client.init(
            std.testing.allocator,
            std.testing.io,
            self.discovery_path,
        ) catch |err| {
            self.failure = err;
            return;
        };
        defer client.deinit();
        self.response = client.call(self.request) catch |err| {
            self.failure = err;
            return;
        };
    }

    fn deinit(self: *Call) void {
        if (self.response) |*response| response.deinit();
        self.response = null;
    }
};

fn waitForRequest(server: *transport.Server) protocol.Request {
    while (true) {
        if (server.takeRequest()) |request| return request;
        std.Thread.yield() catch {};
    }
}

fn failureResponse(
    run_id: protocol.RunId,
    request_id: u64,
    schema_id: protocol.SchemaId,
) protocol.Response {
    return .{
        .request_id = request_id,
        .schema_id = schema_id,
        .run_id = run_id,
        .outcome = .{ .failure = .{
            .code = .target_not_found,
            .detail = "synthetic typed integration response",
        } },
    };
}

fn rawCall(
    endpoint_path: []const u8,
    request: protocol.Request,
) !std.json.Parsed(protocol.Response) {
    const request_json = try protocol.encodeRequestAlloc(std.testing.allocator, request);
    defer std.testing.allocator.free(request_json);
    const address = try std.Io.net.UnixAddress.init(endpoint_path);
    const stream = try address.connect(std.testing.io);
    defer stream.close(std.testing.io);
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(std.testing.io, &write_buffer);
    try protocol.writeFrame(
        &writer.interface,
        .request,
        request.protocol_cohort,
        request.request_id,
        request_json,
    );
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(std.testing.io, &read_buffer);
    var frame = try protocol.readFrameAlloc(std.testing.allocator, &reader.interface);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.FrameKind.response, frame.header.kind);
    return protocol.parseResponse(std.testing.allocator, frame.payload);
}

fn rawPayloadCall(
    endpoint_path: []const u8,
    cohort: u16,
    request_id: u64,
    payload: []const u8,
) !std.json.Parsed(protocol.Response) {
    const address = try std.Io.net.UnixAddress.init(endpoint_path);
    const stream = try address.connect(std.testing.io);
    defer stream.close(std.testing.io);
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(std.testing.io, &write_buffer);
    try protocol.writeFrame(
        &writer.interface,
        .request,
        cohort,
        request_id,
        payload,
    );
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(std.testing.io, &read_buffer);
    var frame = try protocol.readFrameAlloc(std.testing.allocator, &reader.interface);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.FrameKind.response, frame.header.kind);
    try std.testing.expectEqual(protocol.protocol_cohort, frame.header.protocol_cohort);
    try std.testing.expectEqual(request_id, frame.header.request_id);
    return protocol.parseResponse(std.testing.allocator, frame.payload);
}

fn corruptFrameCall(
    endpoint_path: []const u8,
    request_id: u64,
    payload: []const u8,
) !std.json.Parsed(protocol.Response) {
    const address = try std.Io.net.UnixAddress.init(endpoint_path);
    const stream = try address.connect(std.testing.io);
    defer stream.close(std.testing.io);
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(std.testing.io, &write_buffer);
    var header = protocol.Header.init(
        .request,
        protocol.protocol_cohort,
        request_id,
        payload,
    ).encode();
    header[28] ^= 0xff;
    try writer.interface.writeAll(&header);
    try writer.interface.writeAll(payload);
    try writer.interface.flush();
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(std.testing.io, &read_buffer);
    var frame = try protocol.readFrameAlloc(std.testing.allocator, &reader.interface);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.FrameKind.response, frame.header.kind);
    try std.testing.expectEqual(protocol.protocol_cohort, frame.header.protocol_cohort);
    try std.testing.expectEqual(request_id, frame.header.request_id);
    return protocol.parseResponse(std.testing.allocator, frame.payload);
}

fn expectTransportFailure(
    response: protocol.Response,
    code: protocol.FailureCode,
) !void {
    try std.testing.expect(response.outcome == .failure);
    try std.testing.expectEqual(code, response.outcome.failure.code);
    try std.testing.expect(response.outcome.failure.detail.len != 0);
}

fn connectAndClose(endpoint_path: []const u8) !void {
    const address = try std.Io.net.UnixAddress.init(endpoint_path);
    const stream = try address.connect(std.testing.io);
    stream.close(std.testing.io);
}

fn exchange(
    server: *transport.Server,
    discovery_path: []const u8,
    request: protocol.Request,
) !void {
    var call = Call{ .discovery_path = discovery_path, .request = request };
    defer call.deinit();
    const thread = try std.Thread.spawn(.{}, Call.run, .{&call});
    const received = waitForRequest(server);
    try std.testing.expectEqual(request.request_id, received.request_id);
    try std.testing.expectEqual(
        std.meta.activeTag(request.command),
        std.meta.activeTag(received.command),
    );
    try server.respond(failureResponse(
        server.discovery().run_id,
        request.request_id,
        request.schema_id,
    ));
    thread.join();
    if (call.failure) |err| return err;
    const response = call.response orelse return error.IntegrationResponseMissing;
    try std.testing.expectEqual(request.request_id, response.value.request_id);
    try std.testing.expectEqual(
        protocol.FailureCode.target_not_found,
        response.value.outcome.failure.code,
    );
}

test "every concrete command crosses real local transport and reusable client" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var server = try transport.Server.create(std.testing.allocator, std.testing.io, .{
        .developer_directory = root,
        .run_id = .{ .started_wall_unix_ms = 1, .nonce = 0xea05_1001 },
    });
    defer server.destroy();

    const commands = [_]protocol.Command{
        .{ .describe = .{} },
        .{ .schema_list = .{} },
        .{ .world_list = .{} },
        .{ .content_list = .{} },
        .{ .inspect = .{ .target = target } },
        .{ .selection_set = .{ .target = target } },
        .{ .selection_clear = .{} },
        .{ .camera_inspect = .{} },
        .{ .camera_set_mode = .{ .mode = .free_camera } },
        .{ .camera_set_pose = .{
            .position = .{ 1, 2, 3 },
            .yaw_radians = 0.25,
            .pitch_radians = -0.125,
        } },
        .{ .camera_focus = .{ .target = target } },
        .{ .crate_set_position = .{
            .target = target,
            .expected_revision = 4,
            .position = .{ 3, 2, 1 },
        } },
        .{ .transaction_inspect = .{ .transaction_id = 7 } },
        .{ .undo = .{ .target = target, .expected_revision = 5 } },
        .{ .redo = .{ .target = target, .expected_revision = 6 } },
        .{ .save_world = .{} },
        .{ .save_result = .{ .save_request_id = 8 } },
        .{ .capture_frame = .{} },
        .{ .frame_result = .{ .capture_id = 9 } },
    };
    for (commands, 1..) |command, request_id| {
        try exchange(
            server,
            server.discoveryPath(),
            protocol.Request.init(server.discovery().run_id, request_id, command),
        );
    }
}

test "malformed and unknown clients do not poison the next valid exchange" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var server = try transport.Server.create(std.testing.allocator, std.testing.io, .{
        .developer_directory = root,
        .run_id = .{ .started_wall_unix_ms = 1, .nonce = 0xea05_1003 },
    });
    defer server.destroy();
    const run_id = server.discovery().run_id;
    const valid = protocol.Request.init(run_id, 90, .{ .describe = .{} });
    const valid_json = try protocol.encodeRequestAlloc(std.testing.allocator, valid);
    defer std.testing.allocator.free(valid_json);

    try connectAndClose(server.discovery().endpoint_path.?.slice());
    var unknown_cohort = try rawPayloadCall(
        server.discovery().endpoint_path.?.slice(),
        protocol.protocol_cohort + 1,
        91,
        valid_json,
    );
    defer unknown_cohort.deinit();
    try expectTransportFailure(unknown_cohort.value, .unknown_protocol_cohort);

    var malformed_json = try rawPayloadCall(
        server.discovery().endpoint_path.?.slice(),
        protocol.protocol_cohort,
        92,
        "{not-json",
    );
    defer malformed_json.deinit();
    try expectTransportFailure(malformed_json.value, .malformed_json);

    var corrupt_frame = try corruptFrameCall(
        server.discovery().endpoint_path.?.slice(),
        93,
        valid_json,
    );
    defer corrupt_frame.deinit();
    try expectTransportFailure(corrupt_frame.value, .malformed_frame);

    var unknown_schema_request = valid;
    unknown_schema_request.request_id = 94;
    unknown_schema_request.schema_id.local = 999;
    const unknown_json = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        unknown_schema_request,
        .{},
    );
    defer std.testing.allocator.free(unknown_json);
    var unknown_schema = try rawPayloadCall(
        server.discovery().endpoint_path.?.slice(),
        protocol.protocol_cohort,
        unknown_schema_request.request_id,
        unknown_json,
    );
    defer unknown_schema.deinit();
    try expectTransportFailure(unknown_schema.value, .unknown_schema);

    var schema_mismatch_request = valid;
    schema_mismatch_request.request_id = 95;
    schema_mismatch_request.schema_id = protocol.editor_control_schema;
    const schema_mismatch_json = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        schema_mismatch_request,
        .{},
    );
    defer std.testing.allocator.free(schema_mismatch_json);
    var schema_mismatch = try rawPayloadCall(
        server.discovery().endpoint_path.?.slice(),
        protocol.protocol_cohort,
        schema_mismatch_request.request_id,
        schema_mismatch_json,
    );
    defer schema_mismatch.deinit();
    try expectTransportFailure(schema_mismatch.value, .command_schema_mismatch);

    var request_id_mismatch = valid;
    request_id_mismatch.request_id = 96;
    const request_id_mismatch_json = try protocol.encodeRequestAlloc(
        std.testing.allocator,
        request_id_mismatch,
    );
    defer std.testing.allocator.free(request_id_mismatch_json);
    var invalid_request = try rawPayloadCall(
        server.discovery().endpoint_path.?.slice(),
        protocol.protocol_cohort,
        97,
        request_id_mismatch_json,
    );
    defer invalid_request.deinit();
    try expectTransportFailure(invalid_request.value, .invalid_request);

    try exchange(
        server,
        server.discoveryPath(),
        protocol.Request.init(run_id, 98, .{ .describe = .{} }),
    );
}

test "two independent clients retain their own serialized correlations" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var server = try transport.Server.create(std.testing.allocator, std.testing.io, .{
        .developer_directory = root,
        .run_id = .{ .started_wall_unix_ms = 1, .nonce = 0xea05_1004 },
    });
    defer server.destroy();
    const run_id = server.discovery().run_id;
    var first = Call{
        .discovery_path = server.discoveryPath(),
        .request = protocol.Request.init(run_id, 101, .{ .describe = .{} }),
    };
    defer first.deinit();
    var second = Call{
        .discovery_path = server.discoveryPath(),
        .request = protocol.Request.init(run_id, 202, .{ .world_list = .{} }),
    };
    defer second.deinit();
    const first_thread = try std.Thread.spawn(.{}, Call.run, .{&first});
    const second_thread = std.Thread.spawn(.{}, Call.run, .{&second}) catch |err| {
        server.stop();
        first_thread.join();
        return err;
    };
    var joined = false;
    defer if (!joined) {
        server.stop();
        first_thread.join();
        second_thread.join();
    };

    var saw_first = false;
    var saw_second = false;
    for (0..2) |_| {
        const request = waitForRequest(server);
        saw_first = saw_first or request.request_id == first.request.request_id;
        saw_second = saw_second or request.request_id == second.request.request_id;
        try server.respond(failureResponse(run_id, request.request_id, request.schema_id));
    }
    first_thread.join();
    second_thread.join();
    joined = true;

    try std.testing.expect(saw_first and saw_second);
    if (first.failure) |err| return err;
    if (second.failure) |err| return err;
    try std.testing.expectEqual(first.request.request_id, first.response.?.value.request_id);
    try std.testing.expectEqual(second.request.request_id, second.response.?.value.request_id);
}

test "server rejects mismatched response correlation without poisoning mailbox" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var server = try transport.Server.create(std.testing.allocator, std.testing.io, .{
        .developer_directory = root,
        .run_id = .{ .started_wall_unix_ms = 1, .nonce = 0xea05_1005 },
    });
    defer server.destroy();
    const run_id = server.discovery().run_id;
    const request = protocol.Request.init(run_id, 301, .{ .world_list = .{} });
    var call = Call{ .discovery_path = server.discoveryPath(), .request = request };
    defer call.deinit();
    const thread = try std.Thread.spawn(.{}, Call.run, .{&call});
    var joined = false;
    defer if (!joined) {
        server.stop();
        thread.join();
    };
    _ = waitForRequest(server);

    try std.testing.expectError(
        error.DeveloperResponseCorrelationMismatch,
        server.respond(failureResponse(run_id, 302, request.schema_id)),
    );
    try std.testing.expectError(
        error.DeveloperResponseCorrelationMismatch,
        server.respond(failureResponse(run_id, request.request_id, protocol.editor_control_schema)),
    );
    var wrong_run = failureResponse(run_id, request.request_id, request.schema_id);
    wrong_run.run_id.nonce += 1;
    try std.testing.expectError(error.DeveloperRunMismatch, server.respond(wrong_run));
    try std.testing.expectError(
        error.DeveloperResponseCorrelationMismatch,
        server.respond(.{
            .request_id = request.request_id,
            .schema_id = request.schema_id,
            .run_id = run_id,
            .outcome = .{ .success = .{ .content_list = &.{} } },
        }),
    );
    try server.respond(.{
        .request_id = request.request_id,
        .schema_id = request.schema_id,
        .run_id = run_id,
        .outcome = .{ .success = .{ .world_list = &.{} } },
    });
    thread.join();
    joined = true;
    if (call.failure) |err| return err;
    try std.testing.expect(call.response.?.value.outcome == .success);
    try std.testing.expect(call.response.?.value.outcome.success == .world_list);
}

test "wrong expected run is rejected before the App mailbox" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var server = try transport.Server.create(std.testing.allocator, std.testing.io, .{
        .developer_directory = root,
        .run_id = .{ .started_wall_unix_ms = 1, .nonce = 0xea05_1006 },
    });
    defer server.destroy();
    const actual_run = server.discovery().run_id;
    var wrong_run = actual_run;
    wrong_run.nonce += 1;
    const request = protocol.Request.init(wrong_run, 401, .{ .describe = .{} });
    var response = try rawCall(server.discovery().endpoint_path.?.slice(), request);
    defer response.deinit();
    try std.testing.expect(response.value.outcome == .failure);
    try std.testing.expectEqual(
        protocol.FailureCode.run_mismatch,
        response.value.outcome.failure.code,
    );
    try std.testing.expect(server.takeRequest() == null);

    var client = try client_module.Client.init(
        std.testing.allocator,
        std.testing.io,
        server.discoveryPath(),
    );
    defer client.deinit();
    try std.testing.expectError(error.DeveloperRunMismatch, client.call(request));
    try exchange(
        server,
        server.discoveryPath(),
        protocol.Request.init(actual_run, 402, .{ .describe = .{} }),
    );
}

test "admitted request receives a typed stopping response" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var server = try transport.Server.create(std.testing.allocator, std.testing.io, .{
        .developer_directory = root,
        .run_id = .{ .started_wall_unix_ms = 1, .nonce = 0xea05_1007 },
    });
    defer server.destroy();
    var call = Call{
        .discovery_path = server.discoveryPath(),
        .request = protocol.Request.init(
            server.discovery().run_id,
            501,
            .{ .describe = .{} },
        ),
    };
    defer call.deinit();
    const thread = try std.Thread.spawn(.{}, Call.run, .{&call});
    var joined = false;
    defer if (!joined) {
        server.stop();
        thread.join();
    };
    _ = waitForRequest(server);

    server.stop();
    thread.join();
    joined = true;
    if (call.failure) |err| return err;
    const response = call.response orelse return error.IntegrationResponseMissing;
    try expectTransportFailure(response.value, .endpoint_stopping);
}

test "stopped discovery and a stale initialized client fail explicitly" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var server = try transport.Server.create(std.testing.allocator, std.testing.io, .{
        .developer_directory = root,
        .run_id = .{ .started_wall_unix_ms = 1, .nonce = 0xea05_1002 },
    });
    defer server.destroy();
    var client = try client_module.Client.init(
        std.testing.allocator,
        std.testing.io,
        server.discoveryPath(),
    );
    defer client.deinit();
    server.stop();
    var stopped = try client_module.loadDiscovery(
        std.testing.allocator,
        std.testing.io,
        server.discoveryPath(),
    );
    defer stopped.deinit();
    try std.testing.expectEqual(protocol.Lifecycle.stopped, stopped.value.lifecycle);
    try std.testing.expect(stopped.value.endpoint_path == null);
    try std.testing.expect(stopped.value.schema_digest == null);
    try std.testing.expectError(
        error.StaleDeveloperEndpoint,
        client.call(protocol.Request.init(client.runId(), 1, .{ .describe = .{} })),
    );
    try std.testing.expectError(
        error.DeveloperEndpointUnavailable,
        client_module.Client.init(
            std.testing.allocator,
            std.testing.io,
            server.discoveryPath(),
        ),
    );
}
