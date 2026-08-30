//! Canonical JSON CLI for the local Incinerator developer endpoint.

const std = @import("std");
const client_module = @import("developer_endpoint_client");
const agent_contract = @import("sandbox_developer_cli_contract");
const protocol = @import("sandbox_developer_protocol");

const ExitDisposition = enum {
    success,
    operation_failed,
};

const Invocation = union(enum) {
    help,
    agent_bootstrap,
    agent_catalog,
    discovery,
    request: protocol.Command,
};

const GlobalArguments = struct {
    command: std.ArrayList([]const u8),
    discovery_path: ?[]const u8,

    fn deinit(self: *GlobalArguments, allocator: std.mem.Allocator) void {
        self.command.deinit(allocator);
        self.* = undefined;
    }
};

pub fn main(init: std.process.Init) !void {
    const disposition = run(init) catch |err| {
        writeJson(init.io, .{
            .client_error = .{
                .code = @errorName(err),
            },
        }) catch {};
        std.process.exit(1);
    };
    if (disposition == .operation_failed) std.process.exit(1);
}

fn run(init: std.process.Init) !ExitDisposition {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var globals = try parseGlobalArguments(init.gpa, args);
    defer globals.deinit(init.gpa);

    const invocation = try parseInvocation(
        init.gpa,
        globals.command.items,
    );
    switch (invocation) {
        .help => {
            try writeUsage(init.io);
            return .success;
        },
        .agent_catalog => {
            try writeJson(init.io, agent_contract.catalog());
            return .success;
        },
        .agent_bootstrap => {
            const discovery_path = try resolveDiscoveryPath(
                init.gpa,
                init.environ_map,
                globals.discovery_path,
            );
            defer init.gpa.free(discovery_path);
            var discovery = try client_module.loadDiscovery(
                init.gpa,
                init.io,
                discovery_path,
            );
            defer discovery.deinit();
            const available_next = [_]agent_contract.SuggestedOperation{
                .{ .operation = "agent.catalog" },
                .{ .operation = "endpoint.describe" },
                .{ .operation = "world.list" },
                .{ .operation = "content.list" },
            };
            const inactive_next = [_]agent_contract.SuggestedOperation{
                .{ .operation = "agent.catalog" },
                .{ .operation = "endpoint.discovery" },
            };
            const next: []const agent_contract.SuggestedOperation = if (discovery.value.lifecycle == .available) &available_next else &inactive_next;
            try writeJson(init.io, .{
                .agent_contract_revision = agent_contract.agent_contract_revision,
                .catalog_digest = agent_contract.catalogDigest(),
                .local_only = true,
                .discovery_path = discovery_path,
                .lifecycle = discovery.value.lifecycle,
                .run_id = discovery.value.run_id,
                .protocol_cohort = discovery.value.protocol_cohort,
                .schema_digest = discovery.value.schema_digest,
                .schema_ids = discovery.value.schema_ids,
                .next = next,
            });
            return .success;
        },
        .discovery => {
            const discovery_path = try resolveDiscoveryPath(
                init.gpa,
                init.environ_map,
                globals.discovery_path,
            );
            defer init.gpa.free(discovery_path);
            var discovery = try client_module.loadDiscovery(
                init.gpa,
                init.io,
                discovery_path,
            );
            defer discovery.deinit();
            try writeJson(init.io, discovery.value);
            return .success;
        },
        .request => |command| {
            const discovery_path = try resolveDiscoveryPath(
                init.gpa,
                init.environ_map,
                globals.discovery_path,
            );
            defer init.gpa.free(discovery_path);
            var client = try client_module.Client.init(init.gpa, init.io, discovery_path);
            defer client.deinit();
            var response = try client.callCommand(nextRequestId(init.io), command);
            defer response.deinit();
            var next_buffer: [2]agent_contract.SuggestedOperation = undefined;
            const guidance = agent_contract.responseGuidance(response.value, &next_buffer);
            const descriptor = agent_contract.descriptorForCommand(command);
            const disposition = outcomeDisposition(response.value.outcome);
            try writeJson(init.io, .{
                .agent_contract_revision = agent_contract.agent_contract_revision,
                .operation = descriptor.id,
                .terminal = guidance.terminal,
                .next = guidance.next,
                .response = response.value,
            });
            return disposition;
        },
    }
}

fn outcomeDisposition(outcome: protocol.ResponseOutcome) ExitDisposition {
    return switch (outcome) {
        .failure => .operation_failed,
        .success => |payload| switch (payload) {
            .authoring_admission => |value| if (value.admitted)
                .success
            else
                .operation_failed,
            .transaction => |value| if (value.disposition == .rejected)
                .operation_failed
            else
                .success,
            .save_admission => |value| if (value.admitted)
                .success
            else
                .operation_failed,
            .save_result => |value| switch (value.disposition) {
                .pending, .committed => .success,
                .failed, .not_found => .operation_failed,
            },
            .frame_admission => |value| if (value.admitted)
                .success
            else
                .operation_failed,
            .frame_result => |value| switch (value.disposition) {
                .pending, .captured => .success,
                .failed, .not_found => .operation_failed,
            },
            else => .success,
        },
    };
}

fn resolveDiscoveryPath(
    allocator: std.mem.Allocator,
    environ_map: anytype,
    explicit: ?[]const u8,
) ![]u8 {
    if (explicit) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.DiscoveryPathNotAbsolute;
        return allocator.dupe(u8, path);
    }
    const home = environ_map.get("HOME") orelse return error.HomeDirectoryUnavailable;
    return client_module.defaultDiscoveryPathAlloc(allocator, home);
}

fn parseGlobalArguments(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !GlobalArguments {
    var result = GlobalArguments{
        .command = try std.ArrayList([]const u8).initCapacity(allocator, args.len),
        .discovery_path = null,
    };
    errdefer result.deinit(allocator);

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--json")) continue;
        if (std.mem.eql(u8, argument, "--discovery")) {
            if (result.discovery_path != null) return error.DuplicateDiscoveryPath;
            index += 1;
            if (index >= args.len) return error.MissingDiscoveryPath;
            result.discovery_path = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, argument, "--discovery=")) {
            if (result.discovery_path != null) return error.DuplicateDiscoveryPath;
            const path = argument["--discovery=".len..];
            if (path.len == 0) return error.MissingDiscoveryPath;
            result.discovery_path = path;
            continue;
        }
        try result.command.append(allocator, argument);
    }
    return result;
}

const CommandParser = struct {
    allocator: std.mem.Allocator,
    tokens: []const []const u8,
    used: []bool,

    fn init(allocator: std.mem.Allocator, tokens: []const []const u8) !CommandParser {
        const used = try allocator.alloc(bool, tokens.len);
        @memset(used, false);
        return .{ .allocator = allocator, .tokens = tokens, .used = used };
    }

    fn deinit(self: *CommandParser) void {
        self.allocator.free(self.used);
        self.* = undefined;
    }

    fn prefix(self: *CommandParser, expected: []const []const u8) bool {
        if (self.tokens.len < expected.len) return false;
        for (expected, 0..) |word, index| {
            if (!std.mem.eql(u8, self.tokens[index], word)) return false;
        }
        for (0..expected.len) |index| self.used[index] = true;
        return true;
    }

    fn option(self: *CommandParser, name: []const u8) ![]const u8 {
        var value: ?[]const u8 = null;
        for (self.tokens, 0..) |token, index| {
            if (!std.mem.eql(u8, token, name)) continue;
            if (value != null) return error.DuplicateOption;
            if (index + 1 >= self.tokens.len or self.used[index + 1]) {
                return error.MissingOptionValue;
            }
            self.used[index] = true;
            self.used[index + 1] = true;
            value = self.tokens[index + 1];
        }
        return value orelse error.RequiredOptionMissing;
    }

    fn positional(self: *CommandParser, index: usize) ![]const u8 {
        if (index >= self.tokens.len or self.used[index]) {
            return error.RequiredArgumentMissing;
        }
        if (std.mem.startsWith(u8, self.tokens[index], "--")) {
            return error.RequiredArgumentMissing;
        }
        self.used[index] = true;
        return self.tokens[index];
    }

    fn finish(self: *const CommandParser) !void {
        for (self.used) |used| if (!used) return error.UnknownCommandArgument;
    }
};

fn parseInvocation(
    allocator: std.mem.Allocator,
    tokens: []const []const u8,
) !Invocation {
    if (tokens.len == 0 or
        (tokens.len == 1 and (std.mem.eql(u8, tokens[0], "help") or
            std.mem.eql(u8, tokens[0], "--help") or
            std.mem.eql(u8, tokens[0], "-h"))))
    {
        return .help;
    }
    if (tokens.len == 1 and std.mem.eql(u8, tokens[0], "discovery")) {
        return .discovery;
    }
    if (tokens.len == 2 and
        std.mem.eql(u8, tokens[0], "agent") and
        std.mem.eql(u8, tokens[1], "bootstrap"))
    {
        return .agent_bootstrap;
    }
    if (tokens.len == 2 and
        std.mem.eql(u8, tokens[0], "agent") and
        std.mem.eql(u8, tokens[1], "catalog"))
    {
        return .agent_catalog;
    }

    var parser = try CommandParser.init(allocator, tokens);
    defer parser.deinit();
    const command: protocol.Command = command: {
        if (parser.prefix(&.{"describe"})) break :command .{ .describe = .{} };
        if (parser.prefix(&.{ "schema", "list" })) break :command .{ .schema_list = .{} };
        if (parser.prefix(&.{ "world", "list" })) break :command .{ .world_list = .{} };
        if (parser.prefix(&.{ "content", "list" })) break :command .{ .content_list = .{} };
        if (parser.prefix(&.{"inspect"})) break :command .{ .inspect = .{
            .target = try parseTarget(try parser.option("--target")),
        } };
        if (parser.prefix(&.{"select"})) break :command .{ .selection_set = .{
            .target = try parseTarget(try parser.option("--target")),
        } };
        if (parser.prefix(&.{"clear-selection"}) or
            parser.prefix(&.{ "selection", "clear" }))
        {
            break :command .{ .selection_clear = .{} };
        }
        if (parser.prefix(&.{ "camera", "inspect" })) {
            break :command .{ .camera_inspect = .{} };
        }
        if (parser.prefix(&.{ "camera", "mode" })) {
            const mode = if (tokens.len > 2 and
                !std.mem.startsWith(u8, tokens[2], "--"))
                try parser.positional(2)
            else
                try parser.option("--mode");
            break :command .{ .camera_set_mode = .{
                .mode = try parseCameraMode(mode),
            } };
        }
        if (parser.prefix(&.{ "camera", "pose" })) break :command .{ .camera_set_pose = .{
            .position = try parsePosition(&parser),
            .yaw_radians = try parseF32(try parser.option("--yaw")),
            .pitch_radians = try parseF32(try parser.option("--pitch")),
        } };
        if (parser.prefix(&.{ "camera", "focus" })) break :command .{ .camera_focus = .{
            .target = try parseTarget(try parser.option("--target")),
        } };
        if (parser.prefix(&.{ "crate", "set-position" })) {
            break :command .{ .crate_set_position = .{
                .target = try parseTarget(try parser.option("--target")),
                .expected_revision = try parseU64(try parser.option("--expected-revision")),
                .position = try parsePosition(&parser),
            } };
        }
        if (parser.prefix(&.{ "transaction", "inspect" })) {
            break :command .{ .transaction_inspect = .{
                .transaction_id = try parseNonzeroU64(try parser.option("--id")),
            } };
        }
        if (parser.prefix(&.{"undo"})) break :command .{ .undo = .{
            .target = try parseTarget(try parser.option("--target")),
            .expected_revision = try parseU64(try parser.option("--expected-revision")),
        } };
        if (parser.prefix(&.{"redo"})) break :command .{ .redo = .{
            .target = try parseTarget(try parser.option("--target")),
            .expected_revision = try parseU64(try parser.option("--expected-revision")),
        } };
        if (parser.prefix(&.{"save-world"})) break :command .{ .save_world = .{} };
        if (parser.prefix(&.{ "save", "result" })) break :command .{ .save_result = .{
            .save_request_id = try parseNonzeroU64(try parser.option("--id")),
        } };
        if (parser.prefix(&.{"capture-frame"})) break :command .{ .capture_frame = .{} };
        if (parser.prefix(&.{ "capture", "inspect" })) break :command .{ .frame_result = .{
            .capture_id = try parseNonzeroU64(try parser.option("--id")),
        } };
        return error.UnknownCommand;
    };
    try parser.finish();
    return .{ .request = command };
}

fn parsePosition(parser: *CommandParser) !protocol.Vec3 {
    return .{
        try parseF32(try parser.option("--x")),
        try parseF32(try parser.option("--y")),
        try parseF32(try parser.option("--z")),
    };
}

fn parseCameraMode(value: []const u8) !protocol.CameraMode {
    if (std.mem.eql(u8, value, "character")) return .character;
    if (std.mem.eql(u8, value, "free-camera")) return .free_camera;
    return error.InvalidCameraMode;
}

pub fn parseTarget(value: []const u8) !protocol.Target {
    var parts = std.mem.splitScalar(u8, value, ':');
    const kind = parts.next() orelse return error.InvalidTarget;
    const namespace = try parseNonzeroU64(parts.next() orelse return error.InvalidTarget);
    const local = try parseNonzeroU64(parts.next() orelse return error.InvalidTarget);
    const target: protocol.Target = if (std.mem.eql(u8, kind, "persistent-entity")) blk: {
        if (parts.next() != null) return error.InvalidTarget;
        break :blk .{ .persistent_entity = .{ .namespace = namespace, .local = local } };
    } else if (std.mem.eql(u8, kind, "gameplay-entity")) blk: {
        const incarnation = try std.fmt.parseInt(
            u32,
            parts.next() orelse return error.InvalidTarget,
            10,
        );
        if (parts.next() != null) return error.InvalidTarget;
        break :blk .{ .gameplay_entity = .{
            .namespace = namespace,
            .local = local,
            .incarnation = incarnation,
        } };
    } else if (std.mem.eql(u8, kind, "content-asset")) blk: {
        if (parts.next() != null) return error.InvalidTarget;
        break :blk .{ .content_asset = .{ .namespace = namespace, .local = local } };
    } else return error.InvalidTargetKind;
    try target.validate();
    return target;
}

fn parseF32(value: []const u8) !f32 {
    const parsed = try std.fmt.parseFloat(f32, value);
    if (!std.math.isFinite(parsed)) return error.NonFiniteNumber;
    return parsed;
}

fn parseU64(value: []const u8) !u64 {
    return std.fmt.parseInt(u64, value, 10);
}

fn parseNonzeroU64(value: []const u8) !u64 {
    const parsed = try parseU64(value);
    if (parsed == 0) return error.ExpectedNonzeroInteger;
    return parsed;
}

fn nextRequestId(io: std.Io) u64 {
    const value = std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
    if (value <= 0) return 1;
    return std.math.cast(u64, value) orelse std.math.maxInt(u64);
}

fn writeJson(io: std.Io, value: anytype) !void {
    var stdout_buffer: [32 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    try std.json.Stringify.value(
        value,
        .{ .whitespace = .indent_2 },
        &stdout_writer.interface,
    );
    try stdout_writer.interface.writeByte('\n');
    try stdout_writer.interface.flush();
}

fn writeUsage(io: std.Io) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(
        \\incinerator-dev [--discovery /absolute/discovery.json] [--json] <command>
        \\  All non-help output is JSON; --json is optional.
        \\  agent bootstrap
        \\  agent catalog
        \\  discovery
        \\  describe
        \\  schema list
        \\  world list
        \\  content list
        \\  inspect --target <persistent-entity:N:L|gameplay-entity:N:L:I|content-asset:N:L>
        \\  select --target <target> | clear-selection
        \\  camera inspect
        \\  camera mode <character|free-camera>
        \\  camera pose --x N --y N --z N --yaw RADIANS --pitch RADIANS
        \\  camera focus --target <target>
        \\  crate set-position --target <persistent-target> --expected-revision N --x N --y N --z N
        \\  transaction inspect --id N
        \\  undo|redo --target <persistent-target> --expected-revision N
        \\  save-world | save result --id N
        \\  capture-frame | capture inspect --id N
        \\
    );
    try writer.interface.flush();
}

test "CLI parses every concrete operation family" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        args: []const []const u8,
        expected: std.meta.Tag(protocol.Command),
    }{
        .{ .args = &.{"describe"}, .expected = .describe },
        .{ .args = &.{ "schema", "list" }, .expected = .schema_list },
        .{ .args = &.{ "world", "list" }, .expected = .world_list },
        .{ .args = &.{ "content", "list" }, .expected = .content_list },
        .{ .args = &.{ "inspect", "--target", "gameplay-entity:2:9:0" }, .expected = .inspect },
        .{ .args = &.{ "select", "--target", "persistent-entity:1:4" }, .expected = .selection_set },
        .{ .args = &.{"clear-selection"}, .expected = .selection_clear },
        .{ .args = &.{ "camera", "inspect" }, .expected = .camera_inspect },
        .{ .args = &.{ "camera", "mode", "free-camera" }, .expected = .camera_set_mode },
        .{ .args = &.{ "camera", "pose", "--x", "1", "--y", "2", "--z", "3", "--yaw", "0.5", "--pitch", "-0.25" }, .expected = .camera_set_pose },
        .{ .args = &.{ "camera", "focus", "--target", "persistent-entity:1:4" }, .expected = .camera_focus },
        .{ .args = &.{ "crate", "set-position", "--target", "persistent-entity:1:4", "--expected-revision", "7", "--x", "3", "--y", "1", "--z", "-5" }, .expected = .crate_set_position },
        .{ .args = &.{ "transaction", "inspect", "--id", "42" }, .expected = .transaction_inspect },
        .{ .args = &.{ "undo", "--target", "persistent-entity:1:4", "--expected-revision", "8" }, .expected = .undo },
        .{ .args = &.{ "redo", "--target", "persistent-entity:1:4", "--expected-revision", "9" }, .expected = .redo },
        .{ .args = &.{"save-world"}, .expected = .save_world },
        .{ .args = &.{ "save", "result", "--id", "12" }, .expected = .save_result },
        .{ .args = &.{"capture-frame"}, .expected = .capture_frame },
        .{ .args = &.{ "capture", "inspect", "--id", "13" }, .expected = .frame_result },
    };
    for (cases) |case| {
        const invocation = try parseInvocation(allocator, case.args);
        try std.testing.expectEqual(case.expected, std.meta.activeTag(invocation.request));
    }
}

test "every catalog example parses through the canonical CLI grammar" {
    for (agent_contract.operationCatalog()) |operation| {
        const invocation = try parseInvocation(std.testing.allocator, operation.example_argv);
        if (operation.endpoint_schema) |schema| {
            try std.testing.expect(invocation == .request);
            try std.testing.expectEqual(schema, invocation.request.schemaId());
            try std.testing.expectEqualStrings(
                operation.id,
                agent_contract.descriptorForCommand(invocation.request).id,
            );
        }
    }
}

test "target grammar keeps world and content identities nominally distinct" {
    const entity = try parseTarget("persistent-entity:1:4");
    try std.testing.expect(entity == .persistent_entity);
    const gameplay = try parseTarget("gameplay-entity:2:9:0");
    try std.testing.expect(gameplay == .gameplay_entity);
    try std.testing.expectEqual(@as(u32, 0), gameplay.gameplay_entity.incarnation);
    const asset = try parseTarget("content-asset:7:3");
    try std.testing.expect(asset == .content_asset);
    try std.testing.expectError(error.InvalidTarget, parseTarget("persistent-entity:1:4:5"));
    try std.testing.expectError(error.InvalidTargetKind, parseTarget("pointer:1:4"));
}

test "CLI rejects unknown and duplicate options" {
    try std.testing.expectError(
        error.UnknownCommandArgument,
        parseInvocation(std.testing.allocator, &.{ "describe", "--surprise" }),
    );
    try std.testing.expectError(
        error.DuplicateOption,
        parseInvocation(std.testing.allocator, &.{
            "inspect",  "--target",              "persistent-entity:1:4",
            "--target", "persistent-entity:1:5",
        }),
    );
}

test "CLI exit status distinguishes progress from typed operation failure" {
    const target = protocol.Target{
        .persistent_entity = .{ .namespace = 1, .local = 1 },
    };
    try std.testing.expectEqual(
        ExitDisposition.operation_failed,
        outcomeDisposition(.{ .failure = .{
            .code = .owner_unavailable,
            .detail = "owner unavailable",
        } }),
    );
    try std.testing.expectEqual(
        ExitDisposition.success,
        outcomeDisposition(.{ .success = .{ .authoring_admission = .{
            .admitted = true,
            .target = target,
            .transaction_id = 1,
            .expected_revision = 0,
        } } }),
    );
    try std.testing.expectEqual(
        ExitDisposition.operation_failed,
        outcomeDisposition(.{ .success = .{ .authoring_admission = .{
            .admitted = false,
            .target = target,
            .transaction_id = null,
            .expected_revision = 0,
        } } }),
    );
    try std.testing.expectEqual(
        ExitDisposition.operation_failed,
        outcomeDisposition(.{ .success = .{ .transaction = .{
            .transaction_id = 1,
            .source = .local_developer_client,
            .target = target,
            .scope = .session,
            .disposition = .rejected,
            .expected_revision = 0,
            .committed_revision = null,
            .before_position = null,
            .requested_position = .{ 1, 2, 3 },
            .committed_position = null,
            .rejection = null,
            .authority_tick = 1,
            .presentation_frame = 2,
        } } }),
    );
    try std.testing.expectEqual(
        ExitDisposition.success,
        outcomeDisposition(.{ .success = .{ .save_result = .{
            .save_request_id = 1,
            .disposition = .committed,
            .slot = "sandbox",
            .generation = null,
            .payload_bytes = 42,
            .detail = null,
        } } }),
    );
    try std.testing.expectEqual(
        ExitDisposition.operation_failed,
        outcomeDisposition(.{ .success = .{ .save_result = .{
            .save_request_id = 2,
            .disposition = .not_found,
            .slot = "sandbox",
            .generation = null,
            .payload_bytes = null,
            .detail = "not retained",
        } } }),
    );
    try std.testing.expectEqual(
        ExitDisposition.success,
        outcomeDisposition(.{ .success = .{ .frame_result = .{
            .capture_id = 1,
            .disposition = .pending,
            .artifact_path = null,
            .authority_tick = null,
            .presentation_frame = null,
            .wall_unix_ms = null,
            .detail = null,
        } } }),
    );
    try std.testing.expectEqual(
        ExitDisposition.operation_failed,
        outcomeDisposition(.{ .success = .{ .frame_result = .{
            .capture_id = 2,
            .disposition = .failed,
            .artifact_path = null,
            .authority_tick = null,
            .presentation_frame = null,
            .wall_unix_ms = null,
            .detail = "capture failed",
        } } }),
    );
}

test "CLI entry point compiles" {
    std.testing.refAllDecls(@This());
}
