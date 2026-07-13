const std = @import("std");
const reflections = @import("shader_reflections");
const shader_assets = @import("shader_assets");

const EntryPoint = struct {
    name: []const u8,
    mode: []const u8,
};

const Resource = struct {
    set: u32,
    binding: u32,
    block_size: ?u32 = null,
};

const InterfaceVariable = struct {
    location: u32,
};

const Reflection = struct {
    entryPoints: []const EntryPoint,
    inputs: []const InterfaceVariable = &.{},
    outputs: []const InterfaceVariable = &.{},
    textures: []const Resource = &.{},
    ubos: []const Resource = &.{},
};

const ExpectedResource = struct {
    set: u32,
    binding: u32,
    block_size: ?u32 = null,
};

const Contract = struct {
    source: []const u8,
    reflection: []const u8,
    stage: []const u8,
    input_locations: []const u32,
    output_locations: []const u32,
    textures: []const ExpectedResource = &.{},
    ubos: []const ExpectedResource = &.{},
};

test "SDL GPU shader interfaces and resources match the renderer contract" {
    const contracts = [_]Contract{
        .{
            .source = "triangle.vert",
            .reflection = reflections.triangle_vertex,
            .stage = "vert",
            .input_locations = &.{ 0, 1 },
            .output_locations = &.{0},
            .ubos = &.{.{ .set = 1, .binding = 0, .block_size = 64 }},
        },
        .{
            .source = "triangle.frag",
            .reflection = reflections.triangle_fragment,
            .stage = "frag",
            .input_locations = &.{0},
            .output_locations = &.{0},
        },
        .{
            .source = "model.vert",
            .reflection = reflections.model_vertex,
            .stage = "vert",
            .input_locations = &.{ 0, 1, 2 },
            .output_locations = &.{ 0, 1 },
            .ubos = &.{.{ .set = 1, .binding = 0, .block_size = 128 }},
        },
        .{
            .source = "model.frag",
            .reflection = reflections.model_fragment,
            .stage = "frag",
            .input_locations = &.{ 0, 1 },
            .output_locations = &.{0},
            .textures = &.{.{ .set = 2, .binding = 0 }},
            .ubos = &.{.{ .set = 3, .binding = 0, .block_size = 32 }},
        },
    };

    for (contracts) |contract| try validateContract(contract);
}

test "selected backend artifacts have the expected container and entry point" {
    try std.testing.expectEqual(.msl, shader_assets.format);
    try std.testing.expectEqualStrings("main0", shader_assets.entrypoint);
    try std.testing.expect(std.mem.indexOf(u8, shader_assets.triangle_vertex, "vertex main0") != null);
    try std.testing.expect(std.mem.indexOf(u8, shader_assets.triangle_fragment, "fragment main0") != null);
}

fn validateContract(contract: Contract) !void {
    const parsed = try std.json.parseFromSlice(
        Reflection,
        std.testing.allocator,
        contract.reflection,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const reflection = parsed.value;
    if (reflection.entryPoints.len != 1 or
        !std.mem.eql(u8, reflection.entryPoints[0].name, "main") or
        !std.mem.eql(u8, reflection.entryPoints[0].mode, contract.stage))
    {
        std.debug.print("{s}: expected one {s} entry point named main\n", .{
            contract.source,
            contract.stage,
        });
        return error.InvalidEntryPoint;
    }

    try expectLocations(contract.source, "input", reflection.inputs, contract.input_locations);
    try expectLocations(contract.source, "output", reflection.outputs, contract.output_locations);
    try expectResources(contract.source, "texture", reflection.textures, contract.textures);
    try expectResources(contract.source, "uniform buffer", reflection.ubos, contract.ubos);
}

fn expectLocations(
    source: []const u8,
    kind: []const u8,
    actual: []const InterfaceVariable,
    expected: []const u32,
) !void {
    if (actual.len != expected.len) {
        std.debug.print("{s}: expected {d} {s} locations, found {d}\n", .{
            source,
            expected.len,
            kind,
            actual.len,
        });
        return error.InvalidInterfaceLocationCount;
    }

    for (expected) |location| {
        for (actual) |item| {
            if (item.location == location) break;
        } else {
            std.debug.print("{s}: missing {s} location {d}\n", .{ source, kind, location });
            return error.MissingInterfaceLocation;
        }
    }
}

fn expectResources(
    source: []const u8,
    kind: []const u8,
    actual: []const Resource,
    expected: []const ExpectedResource,
) !void {
    if (actual.len != expected.len) {
        std.debug.print("{s}: expected {d} {s} resources, found {d}\n", .{
            source,
            expected.len,
            kind,
            actual.len,
        });
        return error.InvalidResourceCount;
    }

    for (expected) |wanted| {
        for (actual) |item| {
            if (item.set == wanted.set and item.binding == wanted.binding) {
                if (wanted.block_size) |block_size| {
                    if (item.block_size != block_size) {
                        std.debug.print(
                            "{s}: {s} set {d} binding {d} has block size {?d}, expected {d}\n",
                            .{ source, kind, wanted.set, wanted.binding, item.block_size, block_size },
                        );
                        return error.InvalidResourceBlockSize;
                    }
                }
                break;
            }
        } else {
            std.debug.print("{s}: missing {s} at set {d}, binding {d}\n", .{
                source,
                kind,
                wanted.set,
                wanted.binding,
            });
            return error.MissingResource;
        }
    }
}
