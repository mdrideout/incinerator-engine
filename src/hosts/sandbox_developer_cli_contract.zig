//! First-class agent-facing contract for the canonical Incinerator CLI.
//!
//! This metadata describes the fixed sandbox developer operations already
//! owned by `sandbox_developer_protocol`. It is not a generic command bus and
//! does not dispatch mutations. The CLI uses it for discovery, guidance, and
//! drift checks while the typed client remains the only executable path.

const std = @import("std");
const protocol = @import("sandbox_developer_protocol");

pub const agent_contract_revision: u16 = 1;

pub const Effect = enum {
    read_only,
    editor_presentation,
    session_authority,
    durable_persistence,
    evidence_capture,
};

pub const Completion = enum {
    synchronous,
    admitted_then_poll,
    poll_until_terminal,
};

pub const Availability = enum {
    offline,
    discovery_document,
    live_editor_endpoint,
};

pub const ParameterKind = enum {
    target,
    unsigned_integer,
    finite_number,
    camera_mode,
};

pub const ParameterDescriptor = struct {
    name: []const u8,
    flag: ?[]const u8 = null,
    positional_index: ?u8 = null,
    kind: ParameterKind,
    required: bool = true,
    unit: ?[]const u8 = null,
    source_operation: ?[]const u8 = null,
    description: []const u8,
};

pub const OperationDescriptor = struct {
    id: []const u8,
    command: []const []const u8,
    summary: []const u8,
    endpoint_schema: ?protocol.SchemaId,
    effect: Effect,
    completion: Completion,
    availability: Availability,
    parameters: []const ParameterDescriptor,
    preconditions: []const []const u8 = &.{},
    poll_operation: ?[]const u8 = null,
    terminal_follow_up: []const []const u8 = &.{},
    rejections: []const []const u8 = &.{},
    example_argv: []const []const u8,
};

pub const GlobalOptionDescriptor = struct {
    flag: []const u8,
    value: []const u8,
    required: bool,
    description: []const u8,
};

pub const Catalog = struct {
    agent_contract_revision: u16,
    catalog_digest: [32]u8,
    protocol_cohort: u16,
    purpose: []const u8,
    global_options: []const GlobalOptionDescriptor,
    invariants: []const []const u8,
    operations: []const OperationDescriptor,
};

pub const SuggestedOperation = struct {
    operation: []const u8,
    target: ?protocol.Target = null,
    transaction_id: ?u64 = null,
    save_request_id: ?u64 = null,
    capture_id: ?u64 = null,
};

pub const ResponseGuidance = struct {
    terminal: bool,
    next: []const SuggestedOperation,
};

const no_parameters = [_]ParameterDescriptor{};
const target_parameter = [_]ParameterDescriptor{.{
    .name = "target",
    .flag = "--target",
    .kind = .target,
    .source_operation = "world.list or content.list",
    .description = "Stable target returned by discovery; never guess a target identity.",
}};
const camera_mode_parameter = [_]ParameterDescriptor{.{
    .name = "mode",
    .positional_index = 2,
    .kind = .camera_mode,
    .description = "Either character or free-camera.",
}};
const camera_pose_parameters = [_]ParameterDescriptor{
    .{ .name = "x", .flag = "--x", .kind = .finite_number, .unit = "meters", .description = "Free-camera world X position." },
    .{ .name = "y", .flag = "--y", .kind = .finite_number, .unit = "meters", .description = "Free-camera world Y position." },
    .{ .name = "z", .flag = "--z", .kind = .finite_number, .unit = "meters", .description = "Free-camera world Z position." },
    .{ .name = "yaw", .flag = "--yaw", .kind = .finite_number, .unit = "radians", .description = "Free-camera yaw." },
    .{ .name = "pitch", .flag = "--pitch", .kind = .finite_number, .unit = "radians", .description = "Free-camera pitch." },
};
const crate_position_parameters = [_]ParameterDescriptor{
    .{ .name = "target", .flag = "--target", .kind = .target, .source_operation = "world.list", .description = "Persistent crate target returned by the current run." },
    .{ .name = "expected_revision", .flag = "--expected-revision", .kind = .unsigned_integer, .source_operation = "target.inspect", .description = "Exact current authoring revision; stale values reject." },
    .{ .name = "x", .flag = "--x", .kind = .finite_number, .unit = "meters", .description = "Requested world X position." },
    .{ .name = "y", .flag = "--y", .kind = .finite_number, .unit = "meters", .description = "Requested world Y position." },
    .{ .name = "z", .flag = "--z", .kind = .finite_number, .unit = "meters", .description = "Requested world Z position." },
};
const transaction_id_parameter = [_]ParameterDescriptor{.{
    .name = "transaction_id",
    .flag = "--id",
    .kind = .unsigned_integer,
    .source_operation = "crate.set-position, transaction.undo, or transaction.redo",
    .description = "Nonzero transaction ID returned by an admission response.",
}};
const history_parameters = [_]ParameterDescriptor{
    .{ .name = "target", .flag = "--target", .kind = .target, .source_operation = "world.list", .description = "Persistent crate target returned by the current run." },
    .{ .name = "expected_revision", .flag = "--expected-revision", .kind = .unsigned_integer, .source_operation = "target.inspect", .description = "Exact current authoring revision and history lineage." },
};
const save_id_parameter = [_]ParameterDescriptor{.{
    .name = "save_request_id",
    .flag = "--id",
    .kind = .unsigned_integer,
    .source_operation = "world.save",
    .description = "Nonzero save request ID returned by admission.",
}};
const capture_id_parameter = [_]ParameterDescriptor{.{
    .name = "capture_id",
    .flag = "--id",
    .kind = .unsigned_integer,
    .source_operation = "frame.capture",
    .description = "Nonzero capture ID returned by admission.",
}};

const global_options = [_]GlobalOptionDescriptor{
    .{
        .flag = "--discovery",
        .value = "/absolute/discovery.json",
        .required = false,
        .description = "Override the default per-user discovery document with an explicit absolute path.",
    },
    .{
        .flag = "--json",
        .value = "",
        .required = false,
        .description = "Explicitly request machine output; every non-help operation already emits JSON and help remains human-readable text.",
    },
};

const invariants = [_][]const u8{
    "Record the current run identity and reject responses from another run.",
    "Discover stable targets from world.list or content.list; never guess identities.",
    "World instances and durable content assets are different identity domains.",
    "Inspect immediately before a revisioned mutation and use that exact revision.",
    "Admission is not completion; poll the declared result operation to a terminal disposition.",
    "A successful or pending operation exits zero; a typed failure or terminal rejection is printed as JSON and exits nonzero.",
    "Reinspect authoritative state after a terminal mutation result; a dynamic body can physically evolve after its committed pose was applied.",
    "Selection and camera operations affect editor presentation; crate edits affect session authority; save is durable persistence.",
};

const operations = [_]OperationDescriptor{
    .{
        .id = "agent.bootstrap",
        .command = &.{ "agent", "bootstrap" },
        .summary = "Read the current discovery document and obtain the safe agent entrypoints.",
        .endpoint_schema = null,
        .effect = .read_only,
        .completion = .synchronous,
        .availability = .discovery_document,
        .parameters = &no_parameters,
        .terminal_follow_up = &.{ "agent.catalog", "endpoint.describe", "world.list", "content.list" },
        .example_argv = &.{ "agent", "bootstrap" },
    },
    .{
        .id = "agent.catalog",
        .command = &.{ "agent", "catalog" },
        .summary = "Describe every fixed CLI operation, parameter source, effect, and completion rule.",
        .endpoint_schema = null,
        .effect = .read_only,
        .completion = .synchronous,
        .availability = .offline,
        .parameters = &no_parameters,
        .example_argv = &.{ "agent", "catalog" },
    },
    .{
        .id = "endpoint.discovery",
        .command = &.{"discovery"},
        .summary = "Read and validate the local endpoint discovery document.",
        .endpoint_schema = null,
        .effect = .read_only,
        .completion = .synchronous,
        .availability = .discovery_document,
        .parameters = &no_parameters,
        .terminal_follow_up = &.{"endpoint.describe"},
        .example_argv = &.{"discovery"},
    },
    .{
        .id = "endpoint.describe",
        .command = &.{"describe"},
        .summary = "Inspect the live endpoint, run identity, protocol cohort, and capabilities.",
        .endpoint_schema = protocol.query_schema,
        .effect = .read_only,
        .completion = .synchronous,
        .availability = .live_editor_endpoint,
        .parameters = &no_parameters,
        .example_argv = &.{"describe"},
    },
    .{
        .id = "schema.list",
        .command = &.{ "schema", "list" },
        .summary = "List the endpoint's registered typed schema families.",
        .endpoint_schema = protocol.query_schema,
        .effect = .read_only,
        .completion = .synchronous,
        .availability = .live_editor_endpoint,
        .parameters = &no_parameters,
        .example_argv = &.{ "schema", "list" },
    },
    .{
        .id = "world.list",
        .command = &.{ "world", "list" },
        .summary = "List live world instances, stable targets, revisions, and authorability.",
        .endpoint_schema = protocol.query_schema,
        .effect = .read_only,
        .completion = .synchronous,
        .availability = .live_editor_endpoint,
        .parameters = &no_parameters,
        .terminal_follow_up = &.{"target.inspect"},
        .example_argv = &.{ "world", "list" },
    },
    .{
        .id = "content.list",
        .command = &.{ "content", "list" },
        .summary = "List durable cooked content assets; runtime entities never appear here.",
        .endpoint_schema = protocol.query_schema,
        .effect = .read_only,
        .completion = .synchronous,
        .availability = .live_editor_endpoint,
        .parameters = &no_parameters,
        .terminal_follow_up = &.{"target.inspect"},
        .example_argv = &.{ "content", "list" },
    },
    .{
        .id = "target.inspect",
        .command = &.{"inspect"},
        .summary = "Inspect one discovered stable world or content target; crate position is the current simulated body pose.",
        .endpoint_schema = protocol.query_schema,
        .effect = .read_only,
        .completion = .synchronous,
        .availability = .live_editor_endpoint,
        .parameters = &target_parameter,
        .rejections = &.{ "target_not_found", "target_kind_not_supported" },
        .example_argv = &.{ "inspect", "--target", "persistent-entity:1:1" },
    },
    .{
        .id = "selection.set",
        .command = &.{"select"},
        .summary = "Select one discovered stable target in the editor.",
        .endpoint_schema = protocol.editor_control_schema,
        .effect = .editor_presentation,
        .completion = .synchronous,
        .availability = .live_editor_endpoint,
        .parameters = &target_parameter,
        .rejections = &.{ "target_not_found", "owner_unavailable" },
        .example_argv = &.{ "select", "--target", "persistent-entity:1:1" },
    },
    .{
        .id = "selection.clear",
        .command = &.{"clear-selection"},
        .summary = "Clear the editor's semantic selection.",
        .endpoint_schema = protocol.editor_control_schema,
        .effect = .editor_presentation,
        .completion = .synchronous,
        .availability = .live_editor_endpoint,
        .parameters = &no_parameters,
        .example_argv = &.{"clear-selection"},
    },
    .{
        .id = "camera.inspect",
        .command = &.{ "camera", "inspect" },
        .summary = "Inspect Character or Free Camera mode and the retained free-camera view.",
        .endpoint_schema = protocol.editor_control_schema,
        .effect = .read_only,
        .completion = .synchronous,
        .availability = .live_editor_endpoint,
        .parameters = &no_parameters,
        .example_argv = &.{ "camera", "inspect" },
    },
    .{
        .id = "camera.set-mode",
        .command = &.{ "camera", "mode" },
        .summary = "Switch the editor between Character and Free Camera mode.",
        .endpoint_schema = protocol.editor_control_schema,
        .effect = .editor_presentation,
        .completion = .synchronous,
        .availability = .live_editor_endpoint,
        .parameters = &camera_mode_parameter,
        .example_argv = &.{ "camera", "mode", "free-camera" },
    },
    .{
        .id = "camera.set-pose",
        .command = &.{ "camera", "pose" },
        .summary = "Set an exact Free Camera pose using meters and radians.",
        .endpoint_schema = protocol.editor_control_schema,
        .effect = .editor_presentation,
        .completion = .synchronous,
        .availability = .live_editor_endpoint,
        .parameters = &camera_pose_parameters,
        .preconditions = &.{"camera mode must be free-camera"},
        .rejections = &.{ "invalid_request", "owner_unavailable" },
        .example_argv = &.{ "camera", "pose", "--x", "1", "--y", "2", "--z", "3", "--yaw", "0.5", "--pitch", "-0.25" },
    },
    .{
        .id = "camera.focus",
        .command = &.{ "camera", "focus" },
        .summary = "Frame a discovered target in Free Camera mode.",
        .endpoint_schema = protocol.editor_control_schema,
        .effect = .editor_presentation,
        .completion = .synchronous,
        .availability = .live_editor_endpoint,
        .parameters = &target_parameter,
        .preconditions = &.{"camera mode must be free-camera"},
        .rejections = &.{ "target_not_found", "target_kind_not_supported", "owner_unavailable" },
        .example_argv = &.{ "camera", "focus", "--target", "persistent-entity:1:1" },
    },
    .{
        .id = "crate.set-position",
        .command = &.{ "crate", "set-position" },
        .summary = "Submit one revision-safe session-authority crate relocation; the dynamic body may simulate after the committed pose is applied.",
        .endpoint_schema = protocol.crate_authoring_schema,
        .effect = .session_authority,
        .completion = .admitted_then_poll,
        .availability = .live_editor_endpoint,
        .parameters = &crate_position_parameters,
        .preconditions = &.{"inspect the target immediately before submitting"},
        .poll_operation = "transaction.inspect",
        .terminal_follow_up = &.{"target.inspect"},
        .rejections = &.{ "stale_revision", "invalid_request", "owner_busy", "owner_unavailable", "target_not_found" },
        .example_argv = &.{ "crate", "set-position", "--target", "persistent-entity:1:1", "--expected-revision", "7", "--x", "3", "--y", "1", "--z", "-5" },
    },
    .{
        .id = "transaction.inspect",
        .command = &.{ "transaction", "inspect" },
        .summary = "Inspect an admitted authoring transaction until accepted or rejected; committed_position is the pose applied at its authority tick.",
        .endpoint_schema = protocol.crate_authoring_schema,
        .effect = .read_only,
        .completion = .poll_until_terminal,
        .availability = .live_editor_endpoint,
        .parameters = &transaction_id_parameter,
        .poll_operation = "transaction.inspect",
        .terminal_follow_up = &.{"target.inspect"},
        .example_argv = &.{ "transaction", "inspect", "--id", "42" },
    },
    .{
        .id = "transaction.undo",
        .command = &.{"undo"},
        .summary = "Submit an exact revision-safe inverse of the current crate history entry.",
        .endpoint_schema = protocol.crate_authoring_schema,
        .effect = .session_authority,
        .completion = .admitted_then_poll,
        .availability = .live_editor_endpoint,
        .parameters = &history_parameters,
        .preconditions = &.{"inspect the target immediately before submitting"},
        .poll_operation = "transaction.inspect",
        .terminal_follow_up = &.{"target.inspect"},
        .rejections = &.{ "stale_revision", "owner_busy", "owner_unavailable", "target_not_found" },
        .example_argv = &.{ "undo", "--target", "persistent-entity:1:1", "--expected-revision", "8" },
    },
    .{
        .id = "transaction.redo",
        .command = &.{"redo"},
        .summary = "Submit an exact revision-safe replay of the current crate redo entry.",
        .endpoint_schema = protocol.crate_authoring_schema,
        .effect = .session_authority,
        .completion = .admitted_then_poll,
        .availability = .live_editor_endpoint,
        .parameters = &history_parameters,
        .preconditions = &.{"inspect the target immediately before submitting"},
        .poll_operation = "transaction.inspect",
        .terminal_follow_up = &.{"target.inspect"},
        .rejections = &.{ "stale_revision", "owner_busy", "owner_unavailable", "target_not_found" },
        .example_argv = &.{ "redo", "--target", "persistent-entity:1:1", "--expected-revision", "9" },
    },
    .{
        .id = "world.save",
        .command = &.{"save-world"},
        .summary = "Request a durable world-snapshot save through the persistence owner.",
        .endpoint_schema = protocol.persistence_schema,
        .effect = .durable_persistence,
        .completion = .admitted_then_poll,
        .availability = .live_editor_endpoint,
        .parameters = &no_parameters,
        .poll_operation = "world.save-result",
        .rejections = &.{ "owner_busy", "owner_unavailable" },
        .example_argv = &.{"save-world"},
    },
    .{
        .id = "world.save-result",
        .command = &.{ "save", "result" },
        .summary = "Inspect a save request until committed or failed; payload_bytes is canonical snapshot size and generation is absent for the fixed slot.",
        .endpoint_schema = protocol.persistence_schema,
        .effect = .read_only,
        .completion = .poll_until_terminal,
        .availability = .live_editor_endpoint,
        .parameters = &save_id_parameter,
        .poll_operation = "world.save-result",
        .example_argv = &.{ "save", "result", "--id", "12" },
    },
    .{
        .id = "frame.capture",
        .command = &.{"capture-frame"},
        .summary = "Request a product-only rendered frame through incident capture.",
        .endpoint_schema = protocol.measurement_schema,
        .effect = .evidence_capture,
        .completion = .admitted_then_poll,
        .availability = .live_editor_endpoint,
        .parameters = &no_parameters,
        .preconditions = &.{"the product must be built and running with incident capture enabled"},
        .poll_operation = "frame.inspect",
        .rejections = &.{ "owner_busy", "owner_unavailable" },
        .example_argv = &.{"capture-frame"},
    },
    .{
        .id = "frame.inspect",
        .command = &.{ "capture", "inspect" },
        .summary = "Inspect a frame request until captured or failed and obtain its correlated artifact.",
        .endpoint_schema = protocol.measurement_schema,
        .effect = .read_only,
        .completion = .poll_until_terminal,
        .availability = .live_editor_endpoint,
        .parameters = &capture_id_parameter,
        .poll_operation = "frame.inspect",
        .example_argv = &.{ "capture", "inspect", "--id", "13" },
    },
};

pub fn operationCatalog() []const OperationDescriptor {
    return &operations;
}

pub fn catalog() Catalog {
    return .{
        .agent_contract_revision = agent_contract_revision,
        .catalog_digest = catalogDigest(),
        .protocol_cohort = protocol.protocol_cohort,
        .purpose = "Canonical shell-agent contract for the local Incinerator developer endpoint; no MCP or second mutation authority.",
        .global_options = &global_options,
        .invariants = &invariants,
        .operations = &operations,
    };
}

pub fn catalogDigest() [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var revision_bytes: [4]u8 = undefined;
    std.mem.writeInt(u16, revision_bytes[0..2], agent_contract_revision, .big);
    std.mem.writeInt(u16, revision_bytes[2..4], protocol.protocol_cohort, .big);
    hasher.update(&revision_bytes);
    for (global_options) |option| {
        hashString(&hasher, option.flag);
        hashString(&hasher, option.value);
        hasher.update(&.{@intFromBool(option.required)});
        hashString(&hasher, option.description);
    }
    hashStrings(&hasher, &invariants);
    for (operations) |operation| {
        hashString(&hasher, operation.id);
        hashStrings(&hasher, operation.command);
        hashString(&hasher, operation.summary);
        hasher.update(&.{ @intFromEnum(operation.effect), @intFromEnum(operation.completion), @intFromEnum(operation.availability) });
        if (operation.endpoint_schema) |schema| {
            hasher.update(&.{1});
            var schema_bytes: [8]u8 = undefined;
            std.mem.writeInt(u32, schema_bytes[0..4], schema.namespace, .big);
            std.mem.writeInt(u32, schema_bytes[4..8], schema.local, .big);
            hasher.update(&schema_bytes);
        } else hasher.update(&.{0});
        for (operation.parameters) |parameter| {
            hashString(&hasher, parameter.name);
            hashOptionalString(&hasher, parameter.flag);
            if (parameter.positional_index) |index| {
                hasher.update(&.{ 1, index });
            } else hasher.update(&.{0});
            hasher.update(&.{ @intFromEnum(parameter.kind), @intFromBool(parameter.required) });
            hashOptionalString(&hasher, parameter.unit);
            hashOptionalString(&hasher, parameter.source_operation);
            hashString(&hasher, parameter.description);
        }
        hashStrings(&hasher, operation.preconditions);
        hashOptionalString(&hasher, operation.poll_operation);
        hashStrings(&hasher, operation.terminal_follow_up);
        hashStrings(&hasher, operation.rejections);
        hashStrings(&hasher, operation.example_argv);
        hasher.update(&.{0xff});
    }
    return hasher.finalResult();
}

fn hashString(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    hasher.update(value);
    hasher.update(&.{0});
}

fn hashOptionalString(
    hasher: *std.crypto.hash.sha2.Sha256,
    value: ?[]const u8,
) void {
    if (value) |present| {
        hasher.update(&.{1});
        hashString(hasher, present);
    } else hasher.update(&.{0});
}

fn hashStrings(
    hasher: *std.crypto.hash.sha2.Sha256,
    values: []const []const u8,
) void {
    for (values) |value| hashString(hasher, value);
    hasher.update(&.{0xfe});
}

pub fn descriptorForCommand(command: protocol.Command) *const OperationDescriptor {
    const id: []const u8 = switch (command) {
        .describe => "endpoint.describe",
        .schema_list => "schema.list",
        .world_list => "world.list",
        .content_list => "content.list",
        .inspect => "target.inspect",
        .selection_set => "selection.set",
        .selection_clear => "selection.clear",
        .camera_inspect => "camera.inspect",
        .camera_set_mode => "camera.set-mode",
        .camera_set_pose => "camera.set-pose",
        .camera_focus => "camera.focus",
        .crate_set_position => "crate.set-position",
        .transaction_inspect => "transaction.inspect",
        .undo => "transaction.undo",
        .redo => "transaction.redo",
        .save_world => "world.save",
        .save_result => "world.save-result",
        .capture_frame => "frame.capture",
        .frame_result => "frame.inspect",
    };
    return descriptorById(id).?;
}

pub fn descriptorById(id: []const u8) ?*const OperationDescriptor {
    for (&operations) |*operation| {
        if (std.mem.eql(u8, operation.id, id)) return operation;
    }
    return null;
}

pub fn responseGuidance(
    response: protocol.Response,
    next_buffer: *[2]SuggestedOperation,
) ResponseGuidance {
    switch (response.outcome) {
        .failure => return .{ .terminal = true, .next = next_buffer[0..0] },
        .success => |payload| switch (payload) {
            .authoring_admission => |value| {
                if (value.admitted) {
                    if (value.transaction_id) |id| {
                        next_buffer[0] = .{ .operation = "transaction.inspect", .transaction_id = id };
                        return .{ .terminal = false, .next = next_buffer[0..1] };
                    }
                }
                next_buffer[0] = .{ .operation = "target.inspect", .target = value.target };
                return .{ .terminal = true, .next = next_buffer[0..1] };
            },
            .transaction => |value| {
                if (value.disposition == .pending) {
                    next_buffer[0] = .{ .operation = "transaction.inspect", .transaction_id = value.transaction_id };
                    return .{ .terminal = false, .next = next_buffer[0..1] };
                }
                next_buffer[0] = .{ .operation = "target.inspect", .target = value.target };
                return .{ .terminal = true, .next = next_buffer[0..1] };
            },
            .save_admission => |value| {
                if (value.admitted) {
                    if (value.save_request_id) |id| {
                        next_buffer[0] = .{ .operation = "world.save-result", .save_request_id = id };
                        return .{ .terminal = false, .next = next_buffer[0..1] };
                    }
                }
                return .{ .terminal = true, .next = next_buffer[0..0] };
            },
            .save_result => |value| {
                if (value.disposition == .pending) {
                    next_buffer[0] = .{ .operation = "world.save-result", .save_request_id = value.save_request_id };
                    return .{ .terminal = false, .next = next_buffer[0..1] };
                }
                return .{ .terminal = true, .next = next_buffer[0..0] };
            },
            .frame_admission => |value| {
                if (value.admitted) {
                    if (value.capture_id) |id| {
                        next_buffer[0] = .{ .operation = "frame.inspect", .capture_id = id };
                        return .{ .terminal = false, .next = next_buffer[0..1] };
                    }
                }
                return .{ .terminal = true, .next = next_buffer[0..0] };
            },
            .frame_result => |value| {
                if (value.disposition == .pending) {
                    next_buffer[0] = .{ .operation = "frame.inspect", .capture_id = value.capture_id };
                    return .{ .terminal = false, .next = next_buffer[0..1] };
                }
                return .{ .terminal = true, .next = next_buffer[0..0] };
            },
            else => return .{ .terminal = true, .next = next_buffer[0..0] },
        },
    }
}

test "agent catalog is complete, unique, and separate from the wire digest" {
    try std.testing.expectEqual(operations.len, 3 + std.meta.fields(protocol.Command).len);
    for (operations, 0..) |operation, index| {
        try std.testing.expect(operation.id.len != 0);
        try std.testing.expect(operation.command.len != 0);
        try std.testing.expect(operation.summary.len != 0);
        try std.testing.expect(operation.example_argv.len != 0);
        for (operations[0..index]) |previous| {
            try std.testing.expect(!std.mem.eql(u8, previous.id, operation.id));
        }
        if (operation.completion == .admitted_then_poll or
            operation.completion == .poll_until_terminal)
        {
            try std.testing.expect(operation.poll_operation != null);
        }
    }
    const digest = catalogDigest();
    try std.testing.expect(!std.mem.eql(u8, &digest, &protocol.schemaDigest()));
}

test "every typed command maps exhaustively to a matching descriptor schema" {
    const target = protocol.Target{ .persistent_entity = .{ .namespace = 1, .local = 1 } };
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
        .{ .camera_set_pose = .{ .position = .{ 1, 2, 3 }, .yaw_radians = 0.5, .pitch_radians = -0.25 } },
        .{ .camera_focus = .{ .target = target } },
        .{ .crate_set_position = .{ .target = target, .expected_revision = 7, .position = .{ 1, 2, 3 } } },
        .{ .transaction_inspect = .{ .transaction_id = 8 } },
        .{ .undo = .{ .target = target, .expected_revision = 8 } },
        .{ .redo = .{ .target = target, .expected_revision = 9 } },
        .{ .save_world = .{} },
        .{ .save_result = .{ .save_request_id = 10 } },
        .{ .capture_frame = .{} },
        .{ .frame_result = .{ .capture_id = 11 } },
    };
    for (commands) |command| {
        const descriptor = descriptorForCommand(command);
        try std.testing.expectEqual(command.schemaId(), descriptor.endpoint_schema.?);
    }
}

test "guidance distinguishes admission, pending, and terminal authority results" {
    const target = protocol.Target{ .persistent_entity = .{ .namespace = 1, .local = 1 } };
    var next_buffer: [2]SuggestedOperation = undefined;
    const admission = protocol.Response{
        .request_id = 1,
        .schema_id = protocol.crate_authoring_schema,
        .run_id = .{ .started_wall_unix_ms = 1, .nonce = 2 },
        .outcome = .{ .success = .{ .authoring_admission = .{
            .admitted = true,
            .target = target,
            .transaction_id = 9,
            .expected_revision = 7,
        } } },
    };
    const admitted = responseGuidance(admission, &next_buffer);
    try std.testing.expect(!admitted.terminal);
    try std.testing.expectEqual(@as(?u64, 9), admitted.next[0].transaction_id);

    const terminal = protocol.Response{
        .request_id = 2,
        .schema_id = protocol.crate_authoring_schema,
        .run_id = .{ .started_wall_unix_ms = 1, .nonce = 2 },
        .outcome = .{ .success = .{ .transaction = .{
            .transaction_id = 9,
            .source = .local_developer_client,
            .target = target,
            .scope = .session,
            .disposition = .accepted,
            .expected_revision = 7,
            .committed_revision = 8,
            .before_position = .{ 0, 0, 0 },
            .requested_position = .{ 1, 2, 3 },
            .committed_position = .{ 1, 2, 3 },
            .rejection = null,
            .authority_tick = 10,
            .presentation_frame = 11,
        } } },
    };
    const completed = responseGuidance(terminal, &next_buffer);
    try std.testing.expect(completed.terminal);
    try std.testing.expectEqualStrings("target.inspect", completed.next[0].operation);

    const save_admission = protocol.Response{
        .request_id = 3,
        .schema_id = protocol.persistence_schema,
        .run_id = .{ .started_wall_unix_ms = 1, .nonce = 2 },
        .outcome = .{ .success = .{ .save_admission = .{
            .admitted = true,
            .save_request_id = 12,
            .rejection = null,
        } } },
    };
    const save_admitted = responseGuidance(save_admission, &next_buffer);
    try std.testing.expect(!save_admitted.terminal);
    try std.testing.expectEqual(@as(?u64, 12), save_admitted.next[0].save_request_id);

    const frame_pending = protocol.Response{
        .request_id = 4,
        .schema_id = protocol.measurement_schema,
        .run_id = .{ .started_wall_unix_ms = 1, .nonce = 2 },
        .outcome = .{ .success = .{ .frame_result = .{
            .capture_id = 13,
            .disposition = .pending,
            .artifact_path = null,
            .authority_tick = null,
            .presentation_frame = null,
            .wall_unix_ms = null,
            .detail = null,
        } } },
    };
    const pending = responseGuidance(frame_pending, &next_buffer);
    try std.testing.expect(!pending.terminal);
    try std.testing.expectEqual(@as(?u64, 13), pending.next[0].capture_id);

    const failed = protocol.Response{
        .request_id = 5,
        .schema_id = protocol.query_schema,
        .run_id = .{ .started_wall_unix_ms = 1, .nonce = 2 },
        .outcome = .{ .failure = .{
            .code = .target_not_found,
            .detail = "target is not present",
        } },
    };
    const rejected = responseGuidance(failed, &next_buffer);
    try std.testing.expect(rejected.terminal);
    try std.testing.expectEqual(@as(usize, 0), rejected.next.len);
}
