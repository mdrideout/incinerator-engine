//! EA0 four-owner source/import boundary verifier.
//!
//! The manifest below is intentionally explicit and build-owned. It classifies
//! the current public/value roots and the crate-authoring vertical slice
//! without pretending adapters and composition roots are host-neutral tools.

const std = @import("std");

const Owner = enum {
    engine_runtime,
    engine_tooling,
    game_runtime_content,
    game_tooling,
};

const ClassifiedSource = struct {
    path: []const u8,
    owner: Owner,
};

/// One executable ownership manifest. New reusable authoring roots must be
/// classified here before they can enter the EA0-guarded graph.
const classified_sources = [_]ClassifiedSource{
    .{ .path = "src/root.zig", .owner = .engine_runtime },
    .{ .path = "src/engine/contracts.zig", .owner = .engine_runtime },
    .{ .path = "src/engine/identity.zig", .owner = .engine_runtime },
    .{ .path = "src/engine/transform.zig", .owner = .engine_runtime },
    .{ .path = "src/engine/contracts/assets.zig", .owner = .engine_runtime },
    .{ .path = "src/engine/contracts/authoring.zig", .owner = .engine_runtime },
    .{ .path = "src/engine/contracts/developer_endpoint.zig", .owner = .engine_runtime },
    .{ .path = "src/render_contract.zig", .owner = .engine_runtime },
    .{ .path = "src/engine/incident.zig", .owner = .engine_runtime },
    .{ .path = "src/session/authority_diagnostics.zig", .owner = .engine_runtime },

    .{ .path = "src/editor/workspace.zig", .owner = .engine_tooling },
    .{ .path = "src/hosts/developer_controls.zig", .owner = .engine_tooling },
    .{ .path = "src/hosts/developer_diagnostics.zig", .owner = .engine_tooling },
    .{ .path = "src/hosts/developer_profile.zig", .owner = .engine_tooling },
    .{ .path = "src/hosts/developer_visualization.zig", .owner = .engine_tooling },

    .{ .path = "src/features/crates/contract.zig", .owner = .game_runtime_content },
    .{ .path = "src/hosts/sandbox_host_contracts.zig", .owner = .game_runtime_content },
    .{ .path = "src/hosts/sandbox_replay.zig", .owner = .game_runtime_content },
    .{ .path = "src/hosts/sandbox_interaction.zig", .owner = .game_runtime_content },
    .{ .path = "src/features/population/contract.zig", .owner = .game_runtime_content },
    .{ .path = "src/content/root.zig", .owner = .game_runtime_content },
    .{ .path = "src/sandbox/district_recipe.zig", .owner = .game_runtime_content },

    .{ .path = "src/hosts/sandbox_authoring.zig", .owner = .game_tooling },
    .{ .path = "src/editor/tool.zig", .owner = .game_tooling },
    .{ .path = "src/editor/tools/camera_tool.zig", .owner = .game_tooling },
    .{ .path = "src/editor/tools/stats_tool.zig", .owner = .game_tooling },
    .{ .path = "src/editor/tools/crate_authoring_tool.zig", .owner = .game_tooling },
};

const NamedOwner = struct {
    name: []const u8,
    owner: Owner,
};

const named_owners = [_]NamedOwner{
    .{ .name = "incinerator_engine", .owner = .engine_runtime },
    .{ .name = "engine_contracts", .owner = .engine_runtime },
    .{ .name = "session_authority_diagnostics", .owner = .engine_runtime },
    .{ .name = "editor_workspace", .owner = .engine_tooling },
    .{ .name = "developer_controls", .owner = .engine_tooling },
    .{ .name = "developer_diagnostics", .owner = .engine_tooling },
    .{ .name = "developer_profile", .owner = .engine_tooling },
    .{ .name = "developer_visualization", .owner = .engine_tooling },
    .{ .name = "crate_contract", .owner = .game_runtime_content },
    .{ .name = "character_contract", .owner = .game_runtime_content },
    .{ .name = "vehicle_contract", .owner = .game_runtime_content },
    .{ .name = "district_contract", .owner = .game_runtime_content },
    .{ .name = "district_feature_contract", .owner = .game_runtime_content },
    .{ .name = "interaction_feature_contract", .owner = .game_runtime_content },
    .{ .name = "navigation_contract", .owner = .game_runtime_content },
    .{ .name = "npc_contract", .owner = .game_runtime_content },
    .{ .name = "npc_encounter_contract", .owner = .game_runtime_content },
    .{ .name = "vitals_contract", .owner = .game_runtime_content },
    .{ .name = "sandbox_host_contracts", .owner = .game_runtime_content },
    .{ .name = "sandbox_replay", .owner = .game_runtime_content },
    .{ .name = "sandbox_interaction", .owner = .game_runtime_content },
    .{ .name = "population_contract", .owner = .game_runtime_content },
    .{ .name = "sandbox_district_recipe", .owner = .game_runtime_content },
    .{ .name = "sandbox_diagnostics_contract", .owner = .game_runtime_content },
    .{ .name = "sandbox_authoring", .owner = .game_tooling },
};

const external_modules = [_][]const u8{
    "std",
    "builtin",
    "build_options",
    "zgui",
    "zmath",
    "simulation_cohort_options",
};

const forbidden_tooling_imports = [_][]const u8{
    "zflecs",
    "jolt_c",
    "jolt_physics",
    "sdl",
    "renderer",
    "physics_debug_gpu",
    "district_gpu_registry",
    "sandbox_simulation",
    "simulation_snapshot",
    "save_slots",
};

const forbidden_tooling_mutation_tokens = [_][]const u8{
    "SDL_",
    "JPH_",
    "std.Io.Dir.cwd().createFile",
    "std.Io.Dir.cwd().writeFile",
    "std.Io.Dir.createFile",
    "std.Io.Dir.writeFile",
};

const forbidden_runtime_source_tokens = [_][]const u8{
    ".gltf",
    ".glb",
    ".png",
    ".jpg",
    ".jpeg",
    "assets/",
};

pub fn main(init: std.process.Init) !void {
    try validateManifest(init, true);
    for (classified_sources) |entry| {
        const source = try std.Io.Dir.cwd().readFileAlloc(
            init.io,
            entry.path,
            init.gpa,
            .limited(4 * 1024 * 1024),
        );
        defer init.gpa.free(source);
        try verifySource(source, entry.path, entry.owner, true);
    }
    std.debug.print(
        "EA0_OWNERSHIP_PASS owners=4 manifest=explicit tooling=backend_neutral runtime_content=cooked_only\n",
        .{},
    );
}

fn validateManifest(init: std.process.Init, emit_diagnostics: bool) !void {
    for (classified_sources, 0..) |entry, index| {
        for (classified_sources[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.path, entry.path)) {
                if (emit_diagnostics) {
                    std.debug.print("duplicate EA0 ownership path: {s}\n", .{entry.path});
                }
                return error.DuplicateOwnershipClassification;
            }
        }
        var file = std.Io.Dir.cwd().openFile(init.io, entry.path, .{}) catch |err| {
            if (emit_diagnostics) {
                std.debug.print("missing EA0 ownership source {s}: {s}\n", .{
                    entry.path,
                    @errorName(err),
                });
            }
            return error.MissingOwnershipSource;
        };
        file.close(init.io);
    }
}

fn verifySource(
    source: []const u8,
    path: []const u8,
    owner: Owner,
    emit_diagnostics: bool,
) !void {
    if (owner == .engine_tooling or owner == .game_tooling) {
        for (forbidden_tooling_mutation_tokens) |token| {
            if (std.mem.indexOf(u8, source, token) != null) {
                return reportViolation(
                    path,
                    "tooling mutation/backend token",
                    token,
                    emit_diagnostics,
                    error.ForbiddenToolingMutation,
                );
            }
        }
    }
    if (owner == .game_runtime_content and
        std.mem.startsWith(u8, path, "src/content/"))
    {
        for (forbidden_runtime_source_tokens) |token| {
            if (std.ascii.indexOfIgnoreCase(source, token) != null) {
                return reportViolation(
                    path,
                    "runtime source-asset discovery token",
                    token,
                    emit_diagnostics,
                    error.RuntimeSourceAssetDiscovery,
                );
            }
        }
    }

    var remaining = source;
    const prefix = "@import(\"";
    while (std.mem.indexOf(u8, remaining, prefix)) |start| {
        const import_start = start + prefix.len;
        const after_start = remaining[import_start..];
        const import_end = std.mem.indexOf(u8, after_start, "\")") orelse
            return error.MalformedImport;
        const imported = after_start[0..import_end];
        try verifyImport(path, owner, imported, emit_diagnostics);
        remaining = after_start[import_end + "\")".len ..];
    }
}

fn verifyImport(
    source_path: []const u8,
    source_owner: Owner,
    imported: []const u8,
    emit_diagnostics: bool,
) !void {
    if (source_owner == .engine_tooling or source_owner == .game_tooling) {
        const basename = std.fs.path.stem(std.fs.path.basename(imported));
        for (forbidden_tooling_imports) |forbidden| {
            if (std.ascii.eqlIgnoreCase(basename, forbidden)) {
                return reportViolation(
                    source_path,
                    "tooling import",
                    imported,
                    emit_diagnostics,
                    error.ForbiddenToolingImport,
                );
            }
        }
    }

    const target_owner = ownerOfImport(source_path, source_owner, imported) orelse
        return reportViolation(
            source_path,
            "unclassified import",
            imported,
            emit_diagnostics,
            error.UnclassifiedOwnershipImport,
        );
    if (!dependencyAllowed(source_owner, target_owner)) {
        return reportViolation(
            source_path,
            "forbidden owner dependency",
            imported,
            emit_diagnostics,
            error.ForbiddenOwnerDependency,
        );
    }
}

fn ownerOfImport(
    source_path: []const u8,
    source_owner: Owner,
    imported: []const u8,
) ?Owner {
    for (external_modules) |name| {
        if (std.mem.eql(u8, imported, name)) return source_owner;
    }
    for (named_owners) |entry| {
        if (std.mem.eql(u8, imported, entry.name)) return entry.owner;
    }
    if (!std.mem.endsWith(u8, imported, ".zig")) return null;

    if (std.mem.indexOf(u8, imported, "engine/") != null or
        std.mem.eql(u8, std.fs.path.basename(imported), "camera.zig") or
        std.mem.eql(u8, std.fs.path.basename(imported), "timing.zig") or
        std.mem.eql(u8, std.fs.path.basename(imported), "render_contract.zig"))
    {
        return .engine_runtime;
    }
    if (std.mem.eql(u8, std.fs.path.basename(imported), "tool.zig")) {
        return .game_tooling;
    }
    if (std.mem.startsWith(u8, source_path, "src/engine/") or
        std.mem.eql(u8, source_path, "src/root.zig"))
    {
        return .engine_runtime;
    }
    return source_owner;
}

fn dependencyAllowed(source: Owner, target: Owner) bool {
    return switch (source) {
        .engine_runtime => target == .engine_runtime,
        .engine_tooling => target == .engine_runtime or target == .engine_tooling,
        .game_runtime_content => target == .engine_runtime or target == .game_runtime_content,
        .game_tooling => true,
    };
}

fn reportViolation(
    path: []const u8,
    kind: []const u8,
    value: []const u8,
    emit_diagnostics: bool,
    err: anyerror,
) anyerror {
    if (emit_diagnostics) {
        std.debug.print("EA0 ownership violation in {s}: {s}: {s}\n", .{
            path,
            kind,
            value,
        });
    }
    return err;
}

test "tooling rejects raw backend imports and mutation APIs" {
    try std.testing.expectError(
        error.ForbiddenToolingImport,
        verifySource(
            "const renderer = @import(\"../renderer.zig\");",
            "tool.zig",
            .game_tooling,
            false,
        ),
    );
    try std.testing.expectError(
        error.ForbiddenToolingMutation,
        verifySource(
            "try std.Io.Dir.cwd().createFile(io, path, .{});",
            "tool.zig",
            .engine_tooling,
            false,
        ),
    );
}

test "owner direction rejects game tooling from game runtime" {
    try std.testing.expectError(
        error.ForbiddenOwnerDependency,
        verifySource(
            "const authoring = @import(\"sandbox_authoring\");",
            "runtime.zig",
            .game_runtime_content,
            false,
        ),
    );
}

test "runtime content rejects source asset discovery" {
    try std.testing.expectError(
        error.RuntimeSourceAssetDiscovery,
        verifySource(
            "const source = \"assets/vehicle.glb\";",
            "src/content/root.zig",
            .game_runtime_content,
            false,
        ),
    );
}

test "game tooling may compose public engine tooling and game value contracts" {
    try verifySource(
        "const workspace = @import(\"editor_workspace\");\n" ++
            "const engine = @import(\"incinerator_engine\");\n" ++
            "const crates = @import(\"crate_contract\");",
        "src/editor/tools/example.zig",
        .game_tooling,
        false,
    );
}
