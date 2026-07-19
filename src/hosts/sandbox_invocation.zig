//! Command-line invocation and installed-content path policy for the sandbox
//! graphical product and its visual-validation companion.
//!
//! This module owns only process-invocation values and parsing. It deliberately
//! contains no SDL, renderer, editor, simulation, or session dependency.

const std = @import("std");
const engine = @import("incinerator_engine");
const content = @import("content");
const save_slots = @import("save_slots");

/// Validated save-root value published by the invocation boundary. Graphical
/// composition does not need to import the concrete storage adapter merely to
/// carry this process argument into the persistence owner.
pub const SaveRootPath = save_slots.RootPath;

pub const VisualSmokeConfig = struct {
    frames: u64 = 480,
    virtual_render_hz: u32 = 240,
};

pub const ProgramMode = union(enum) {
    normal,
    verify_install,
    visual_smoke: VisualSmokeConfig,
    s1_visual_smoke: VisualSmokeConfig,
    s2_visual_smoke: VisualSmokeConfig,
    s3_streaming_smoke: VisualSmokeConfig,
    s6_streaming_smoke: VisualSmokeConfig,
    s7_interaction_smoke: VisualSmokeConfig,
    s8_population_smoke: VisualSmokeConfig,
    s11_combat_smoke: VisualSmokeConfig,
    s4_diagnostics_smoke,
    s4_physics_debug_smoke: VisualSmokeConfig,
    s5_authoring_smoke,
    window_lifecycle_smoke,
    init_failure_smoke,
};

pub const ProductMode = union(enum) {
    normal,
    verify_install,
    incident_smoke,
    incident_benchmark,
    incident_journey,
    incident_journey_window,
    incident_hardening: IncidentHardeningProfile,
    incident_replay: []const u8,
};

/// Explicit developer-only evidence failures exercised by the installed
/// graphical product. These profiles never alter ordinary interactive play.
pub const IncidentHardeningProfile = enum {
    queue_pressure,
    visual_budget,
    writer_budget,
    screenshot_submission,
    screenshot_fence,

    pub fn parse(text: []const u8) !IncidentHardeningProfile {
        inline for (std.meta.tags(IncidentHardeningProfile)) |candidate| {
            if (std.mem.eql(u8, text, @tagName(candidate))) return candidate;
        }
        return error.InvalidIncidentHardeningProfile;
    }
};

pub const BootstrapProfile = enum { sandbox, s0_smoke, s1_smoke, s2_smoke, s3_smoke };

pub const ScriptedScenario = enum {
    none,
    s1_character,
    s2_vehicle,
    s3_streaming,
    s4_physics_debug,
    s7_interaction,
    s11_combat,
};

pub const ContentLayout = enum {
    product,
    validation,
};

pub const SmokeExpectation = struct {
    ticks: u64,
    min_alpha: f32,
    max_alpha: f32,
};

pub fn smokeExpectation(config: VisualSmokeConfig) !SmokeExpectation {
    var accumulator = engine.fixed_step.FixedStepAccumulator.init();
    var result = SmokeExpectation{ .ticks = 0, .min_alpha = 1, .max_alpha = 0 };
    for (0..config.frames) |_| {
        _ = try accumulator.addElapsedSeconds(
            1.0 / @as(f64, @floatFromInt(config.virtual_render_hz)),
        );
        while (accumulator.consumeTick()) result.ticks += 1;
        const alpha = accumulator.alpha();
        result.min_alpha = @min(result.min_alpha, alpha);
        result.max_alpha = @max(result.max_alpha, alpha);
    }
    return result;
}

pub fn parseProgramMode(args: anytype) !ProgramMode {
    var verify_install = false;
    var visual_smoke = false;
    var s1_visual_smoke = false;
    var s2_visual_smoke = false;
    var s3_streaming_smoke = false;
    var s6_streaming_smoke = false;
    var s7_interaction_smoke = false;
    var s8_population_smoke = false;
    var s11_combat_smoke = false;
    var s4_diagnostics_smoke = false;
    var s4_physics_debug_smoke = false;
    var s5_authoring_smoke = false;
    var window_lifecycle_smoke = false;
    var init_failure_smoke = false;
    var frames: ?u64 = null;
    var virtual_render_hz: ?u32 = null;
    var content_root_seen = false;
    var save_root_seen = false;

    for (args[1..args.len]) |raw_arg| {
        const arg: []const u8 = raw_arg;
        if (std.mem.eql(u8, arg, "--verify-install")) {
            if (verify_install) return error.DuplicateArgument;
            verify_install = true;
        } else if (std.mem.eql(u8, arg, "--visual-smoke")) {
            if (visual_smoke) return error.DuplicateArgument;
            visual_smoke = true;
        } else if (std.mem.eql(u8, arg, "--s1-visual-smoke")) {
            if (s1_visual_smoke) return error.DuplicateArgument;
            s1_visual_smoke = true;
        } else if (std.mem.eql(u8, arg, "--s2-visual-smoke")) {
            if (s2_visual_smoke) return error.DuplicateArgument;
            s2_visual_smoke = true;
        } else if (std.mem.eql(u8, arg, "--s3-streaming-smoke")) {
            if (s3_streaming_smoke) return error.DuplicateArgument;
            s3_streaming_smoke = true;
        } else if (std.mem.eql(u8, arg, "--s6-streaming-smoke")) {
            if (s6_streaming_smoke) return error.DuplicateArgument;
            s6_streaming_smoke = true;
        } else if (std.mem.eql(u8, arg, "--s7-interaction-smoke")) {
            if (s7_interaction_smoke) return error.DuplicateArgument;
            s7_interaction_smoke = true;
        } else if (std.mem.eql(u8, arg, "--s8-population-smoke")) {
            if (s8_population_smoke) return error.DuplicateArgument;
            s8_population_smoke = true;
        } else if (std.mem.eql(u8, arg, "--s11-combat-smoke")) {
            if (s11_combat_smoke) return error.DuplicateArgument;
            s11_combat_smoke = true;
        } else if (std.mem.eql(u8, arg, "--s4-diagnostics-smoke")) {
            if (s4_diagnostics_smoke) return error.DuplicateArgument;
            s4_diagnostics_smoke = true;
        } else if (std.mem.eql(u8, arg, "--s4-physics-debug-smoke")) {
            if (s4_physics_debug_smoke) return error.DuplicateArgument;
            s4_physics_debug_smoke = true;
        } else if (std.mem.eql(u8, arg, "--s5-authoring-smoke")) {
            if (s5_authoring_smoke) return error.DuplicateArgument;
            s5_authoring_smoke = true;
        } else if (std.mem.eql(u8, arg, "--window-lifecycle-smoke")) {
            if (window_lifecycle_smoke) return error.DuplicateArgument;
            window_lifecycle_smoke = true;
        } else if (std.mem.eql(u8, arg, "--init-failure-smoke")) {
            if (init_failure_smoke) return error.DuplicateArgument;
            init_failure_smoke = true;
        } else if (std.mem.startsWith(u8, arg, "--frames=")) {
            if (frames != null) return error.DuplicateArgument;
            const value = arg["--frames=".len..];
            frames = std.fmt.parseUnsigned(u64, value, 10) catch
                return error.InvalidFrameCount;
            if (frames.? == 0) return error.InvalidFrameCount;
        } else if (std.mem.startsWith(u8, arg, "--virtual-render-hz=")) {
            if (virtual_render_hz != null) return error.DuplicateArgument;
            const value = arg["--virtual-render-hz=".len..];
            virtual_render_hz = std.fmt.parseUnsigned(u32, value, 10) catch
                return error.InvalidVirtualRenderRate;
            if (virtual_render_hz.? == 0 or virtual_render_hz.? > 10_000) {
                return error.InvalidVirtualRenderRate;
            }
        } else if (std.mem.startsWith(u8, arg, "--content-root=")) {
            if (content_root_seen) return error.DuplicateArgument;
            _ = try content.ContentRootPath.parse(arg["--content-root=".len..]);
            content_root_seen = true;
        } else if (std.mem.startsWith(u8, arg, "--save-root=")) {
            if (save_root_seen) return error.DuplicateArgument;
            _ = try SaveRootPath.parse(arg["--save-root=".len..]);
            save_root_seen = true;
        } else {
            return error.UnknownArgument;
        }
    }

    if (verify_install) {
        if (visual_smoke or s1_visual_smoke or s2_visual_smoke or
            s3_streaming_smoke or s6_streaming_smoke or s7_interaction_smoke or
            s8_population_smoke or s11_combat_smoke or
            window_lifecycle_smoke or init_failure_smoke or
            s4_diagnostics_smoke or s4_physics_debug_smoke or
            s5_authoring_smoke or save_root_seen or
            frames != null or virtual_render_hz != null)
        {
            return error.ConflictingProgramModes;
        }
        return .verify_install;
    }
    const explicit_mode_count = @as(u8, @intFromBool(visual_smoke)) +
        @as(u8, @intFromBool(s1_visual_smoke)) +
        @as(u8, @intFromBool(s2_visual_smoke)) +
        @as(u8, @intFromBool(s3_streaming_smoke)) +
        @as(u8, @intFromBool(s6_streaming_smoke)) +
        @as(u8, @intFromBool(s7_interaction_smoke)) +
        @as(u8, @intFromBool(s8_population_smoke)) +
        @as(u8, @intFromBool(s11_combat_smoke)) +
        @as(u8, @intFromBool(s4_diagnostics_smoke)) +
        @as(u8, @intFromBool(s4_physics_debug_smoke)) +
        @as(u8, @intFromBool(s5_authoring_smoke)) +
        @as(u8, @intFromBool(window_lifecycle_smoke)) +
        @as(u8, @intFromBool(init_failure_smoke));
    if (explicit_mode_count > 1) return error.ConflictingProgramModes;
    if (content_root_seen and explicit_mode_count != 0) return error.ConflictingProgramModes;
    if (save_root_seen and explicit_mode_count != 0 and !s5_authoring_smoke) {
        return error.ConflictingProgramModes;
    }
    if (!visual_smoke and !s1_visual_smoke and !s2_visual_smoke and
        !s3_streaming_smoke and !s6_streaming_smoke and !s7_interaction_smoke and
        !s8_population_smoke and !s11_combat_smoke and
        !s4_physics_debug_smoke and
        (frames != null or virtual_render_hz != null))
    {
        return error.VisualSmokeOptionWithoutMode;
    }
    if (window_lifecycle_smoke) return .window_lifecycle_smoke;
    if (init_failure_smoke) return .init_failure_smoke;
    if (s4_diagnostics_smoke) return .s4_diagnostics_smoke;
    if (s5_authoring_smoke) {
        if (!save_root_seen) return error.SaveRootRequired;
        if (frames != null or virtual_render_hz != null) {
            return error.VisualSmokeOptionWithoutMode;
        }
        return .s5_authoring_smoke;
    }
    if (s4_physics_debug_smoke) {
        const config = VisualSmokeConfig{
            .frames = frames orelse 600,
            .virtual_render_hz = virtual_render_hz orelse 80,
        };
        try validateSmokeAttemptBound(config);
        return .{ .s4_physics_debug_smoke = config };
    }
    if (!visual_smoke and !s1_visual_smoke and !s2_visual_smoke and
        !s3_streaming_smoke and !s6_streaming_smoke and !s7_interaction_smoke and
        !s8_population_smoke and !s11_combat_smoke)
    {
        return .normal;
    }

    const config = VisualSmokeConfig{
        .frames = frames orelse if (s2_visual_smoke)
            1_440
        else if (s8_population_smoke)
            3_600
        else if (s11_combat_smoke)
            3_840
        else if (s3_streaming_smoke or s6_streaming_smoke or s7_interaction_smoke)
            1_200
        else
            480,
        .virtual_render_hz = virtual_render_hz orelse 240,
    };
    try validateSmokeAttemptBound(config);
    return if (s11_combat_smoke)
        .{ .s11_combat_smoke = config }
    else if (s8_population_smoke)
        .{ .s8_population_smoke = config }
    else if (s7_interaction_smoke)
        .{ .s7_interaction_smoke = config }
    else if (s6_streaming_smoke)
        .{ .s6_streaming_smoke = config }
    else if (s3_streaming_smoke)
        .{ .s3_streaming_smoke = config }
    else if (s2_visual_smoke)
        .{ .s2_visual_smoke = config }
    else if (s1_visual_smoke)
        .{ .s1_visual_smoke = config }
    else
        .{ .visual_smoke = config };
}

pub fn parseProductMode(args: anytype) !ProductMode {
    var verify_install = false;
    var incident_smoke = false;
    var incident_benchmark = false;
    var incident_journey = false;
    var incident_journey_window = false;
    var incident_hardening: ?IncidentHardeningProfile = null;
    var incident_replay: ?[]const u8 = null;
    var content_root_seen = false;
    var save_root_seen = false;
    for (args[1..args.len]) |raw_arg| {
        const arg: []const u8 = raw_arg;
        if (std.mem.eql(u8, arg, "--verify-install")) {
            if (verify_install) return error.DuplicateArgument;
            verify_install = true;
        } else if (std.mem.eql(u8, arg, "--incident-smoke")) {
            if (incident_smoke) return error.DuplicateArgument;
            incident_smoke = true;
        } else if (std.mem.eql(u8, arg, "--incident-benchmark")) {
            if (incident_benchmark) return error.DuplicateArgument;
            incident_benchmark = true;
        } else if (std.mem.eql(u8, arg, "--incident-journey")) {
            if (incident_journey) return error.DuplicateArgument;
            incident_journey = true;
        } else if (std.mem.eql(u8, arg, "--incident-journey-window")) {
            if (incident_journey_window) return error.DuplicateArgument;
            incident_journey_window = true;
        } else if (std.mem.startsWith(u8, arg, "--incident-hardening=")) {
            if (incident_hardening != null) return error.DuplicateArgument;
            incident_hardening = try IncidentHardeningProfile.parse(
                arg["--incident-hardening=".len..],
            );
        } else if (std.mem.startsWith(u8, arg, "--replay-incident=")) {
            if (incident_replay != null) return error.DuplicateArgument;
            const path = arg["--replay-incident=".len..];
            if (!std.fs.path.isAbsolute(path) or path.len == 0) {
                return error.InvalidIncidentRunPath;
            }
            incident_replay = path;
        } else if (std.mem.startsWith(u8, arg, "--content-root=")) {
            if (content_root_seen) return error.DuplicateArgument;
            _ = try content.ContentRootPath.parse(arg["--content-root=".len..]);
            content_root_seen = true;
        } else if (std.mem.startsWith(u8, arg, "--save-root=")) {
            if (save_root_seen) return error.DuplicateArgument;
            _ = try SaveRootPath.parse(arg["--save-root=".len..]);
            save_root_seen = true;
        } else {
            return error.UnknownArgument;
        }
    }
    if ((verify_install and (save_root_seen or incident_smoke or incident_benchmark or incident_journey or
        incident_journey_window or incident_hardening != null or incident_replay != null)) or
        (incident_smoke and (save_root_seen or incident_benchmark or incident_journey or
            incident_journey_window or incident_hardening != null or incident_replay != null)) or
        (incident_benchmark and (save_root_seen or incident_journey or
            incident_journey_window or incident_hardening != null or incident_replay != null)) or
        (incident_journey and (save_root_seen or incident_journey_window or
            incident_hardening != null or incident_replay != null)) or
        (incident_journey_window and (save_root_seen or incident_hardening != null or
            incident_replay != null)) or
        (incident_hardening != null and (save_root_seen or incident_replay != null)) or
        (incident_replay != null and save_root_seen)) return error.ConflictingProgramModes;
    return if (verify_install)
        .verify_install
    else if (incident_smoke)
        .incident_smoke
    else if (incident_benchmark)
        .incident_benchmark
    else if (incident_journey)
        .incident_journey
    else if (incident_journey_window)
        .incident_journey_window
    else if (incident_hardening) |profile|
        .{ .incident_hardening = profile }
    else if (incident_replay) |path|
        .{ .incident_replay = path }
    else
        .normal;
}

pub fn parseContentRootOverride(args: anytype) !?content.ContentRootPath {
    var result: ?content.ContentRootPath = null;
    for (args[1..args.len]) |raw_arg| {
        const arg: []const u8 = raw_arg;
        if (!std.mem.startsWith(u8, arg, "--content-root=")) continue;
        if (result != null) return error.DuplicateArgument;
        result = try content.ContentRootPath.parse(arg["--content-root=".len..]);
    }
    return result;
}

pub fn parseSaveRootOverride(args: anytype) !?SaveRootPath {
    var result: ?SaveRootPath = null;
    for (args[1..args.len]) |raw_arg| {
        const arg: []const u8 = raw_arg;
        if (!std.mem.startsWith(u8, arg, "--save-root=")) continue;
        if (result != null) return error.DuplicateArgument;
        result = try SaveRootPath.parse(arg["--save-root=".len..]);
    }
    return result;
}

pub fn resolveContentRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    configured: ?content.ContentRootPath,
    layout: ContentLayout,
) !content.ContentRootPath {
    if (configured) |root| return root;
    var executable_dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable_dir_len = try std.process.executableDirPath(io, &executable_dir_buffer);
    const resolved = try std.fs.path.resolve(
        allocator,
        &.{
            executable_dir_buffer[0..executable_dir_len],
            defaultContentRootRelative(layout),
        },
    );
    defer allocator.free(resolved);
    return content.ContentRootPath.parse(resolved);
}

pub fn defaultContentRootRelative(layout: ContentLayout) []const u8 {
    return switch (layout) {
        .product => "../share/incinerator/content",
        .validation => "../../share/incinerator/content",
    };
}

fn validateSmokeAttemptBound(config: VisualSmokeConfig) !void {
    const scaled = std.math.mul(u64, config.frames, 4) catch
        return error.InvalidFrameCount;
    _ = std.math.add(u64, scaled, 120) catch return error.InvalidFrameCount;
}

test "installed product compositions derive content from their own layout" {
    try std.testing.expectEqualStrings(
        "../share/incinerator/content",
        defaultContentRootRelative(.product),
    );
    try std.testing.expectEqualStrings(
        "../../share/incinerator/content",
        defaultContentRootRelative(.validation),
    );
}

test "product mode accepts only product invocation options" {
    try std.testing.expect((try parseProductMode(&[_][]const u8{"incinerator"})) == .normal);
    try std.testing.expect((try parseProductMode(&[_][]const u8{
        "incinerator",
        "--incident-smoke",
    })) == .incident_smoke);
    try std.testing.expect((try parseProductMode(&[_][]const u8{
        "incinerator",
        "--incident-benchmark",
    })) == .incident_benchmark);
    try std.testing.expect((try parseProductMode(&[_][]const u8{
        "incinerator",
        "--incident-journey",
    })) == .incident_journey);
    try std.testing.expect((try parseProductMode(&[_][]const u8{
        "incinerator",
        "--incident-journey-window",
    })) == .incident_journey_window);
    const hardening = try parseProductMode(&[_][]const u8{
        "incinerator",
        "--incident-hardening=writer_budget",
    });
    try std.testing.expectEqual(
        IncidentHardeningProfile.writer_budget,
        hardening.incident_hardening,
    );
    const replay = try parseProductMode(&[_][]const u8{
        "incinerator",
        "--replay-incident=/tmp/incinerator-run",
    });
    try std.testing.expectEqualStrings("/tmp/incinerator-run", replay.incident_replay);
    try std.testing.expect((try parseProductMode(&[_][]const u8{
        "incinerator",
        "--verify-install",
        "--content-root=/tmp/incinerator-content",
    })) == .verify_install);
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProductMode(&[_][]const u8{
            "incinerator",
            "--verify-install",
            "--save-root=/tmp/incinerator-saves",
        }),
    );
    try std.testing.expectError(
        error.InvalidIncidentHardeningProfile,
        parseProductMode(&[_][]const u8{
            "incinerator",
            "--incident-hardening=unknown",
        }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProductMode(&[_][]const u8{
            "incinerator",
            "--incident-hardening=queue_pressure",
            "--incident-journey",
        }),
    );
    try std.testing.expectError(
        error.UnknownArgument,
        parseProductMode(&[_][]const u8{ "incinerator", "--visual-smoke" }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProductMode(&[_][]const u8{
            "incinerator",
            "--incident-smoke",
            "--incident-journey",
        }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProductMode(&[_][]const u8{
            "incinerator",
            "--incident-benchmark",
            "--incident-journey",
        }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProductMode(&[_][]const u8{
            "incinerator",
            "--incident-journey",
            "--incident-journey-window",
        }),
    );
    try std.testing.expectError(
        error.UnknownArgument,
        parseProductMode(&[_][]const u8{ "incinerator", "--s11-combat-smoke" }),
    );
}

test "program mode parsing keeps visual smoke explicit and bounded" {
    const normal_args = [_][]const u8{"incinerator"};
    const normal = try parseProgramMode(&normal_args);
    try std.testing.expect(normal == .normal);
    const configured_root_args = [_][]const u8{
        "incinerator",
        "--content-root=/tmp/incinerator-content",
    };
    try std.testing.expect((try parseProgramMode(&configured_root_args)) == .normal);
    const configured_root = (try parseContentRootOverride(&configured_root_args)).?;
    try std.testing.expectEqualStrings("/tmp/incinerator-content", configured_root.bytes());
    const configured_save_args = [_][]const u8{
        "incinerator",
        "--save-root=/tmp/incinerator-saves",
    };
    try std.testing.expect((try parseProgramMode(&configured_save_args)) == .normal);
    const configured_save = (try parseSaveRootOverride(&configured_save_args)).?;
    try std.testing.expectEqualStrings("/tmp/incinerator-saves", configured_save.bytes());
    const smoke_args = [_][]const u8{
        "incinerator",
        "--visual-smoke",
        "--frames=160",
        "--virtual-render-hz=80",
    };
    const smoke = try parseProgramMode(&smoke_args);
    try std.testing.expectEqual(@as(u64, 160), smoke.visual_smoke.frames);
    try std.testing.expectEqual(@as(u32, 80), smoke.visual_smoke.virtual_render_hz);
    const s1_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--s1-visual-smoke",
        "--frames=240",
        "--virtual-render-hz=120",
    });
    try std.testing.expectEqual(@as(u64, 240), s1_smoke.s1_visual_smoke.frames);
    const s2_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--s2-visual-smoke",
    });
    try std.testing.expectEqual(@as(u64, 1_440), s2_smoke.s2_visual_smoke.frames);
    try std.testing.expectEqual(@as(u32, 240), s2_smoke.s2_visual_smoke.virtual_render_hz);
    const s2_expected = try smokeExpectation(s2_smoke.s2_visual_smoke);
    try std.testing.expectEqual(@as(u64, 360), s2_expected.ticks);
    const s3_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--s3-streaming-smoke",
        "--virtual-render-hz=80",
    });
    try std.testing.expectEqual(@as(u64, 1_200), s3_smoke.s3_streaming_smoke.frames);
    try std.testing.expectEqual(@as(u32, 80), s3_smoke.s3_streaming_smoke.virtual_render_hz);
    const s6_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--s6-streaming-smoke",
        "--frames=120",
        "--virtual-render-hz=240",
    });
    try std.testing.expectEqual(@as(u64, 120), s6_smoke.s6_streaming_smoke.frames);
    try std.testing.expectEqual(@as(u32, 240), s6_smoke.s6_streaming_smoke.virtual_render_hz);
    const s7_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--s7-interaction-smoke",
        "--virtual-render-hz=80",
    });
    try std.testing.expectEqual(@as(u64, 1_200), s7_smoke.s7_interaction_smoke.frames);
    try std.testing.expectEqual(@as(u32, 80), s7_smoke.s7_interaction_smoke.virtual_render_hz);
    const s8_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--s8-population-smoke",
    });
    try std.testing.expectEqual(@as(u64, 3_600), s8_smoke.s8_population_smoke.frames);
    try std.testing.expectEqual(@as(u32, 240), s8_smoke.s8_population_smoke.virtual_render_hz);
    const s11_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--s11-combat-smoke",
    });
    try std.testing.expectEqual(@as(u64, 3_840), s11_smoke.s11_combat_smoke.frames);
    try std.testing.expectEqual(@as(u32, 240), s11_smoke.s11_combat_smoke.virtual_render_hz);
    const window_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--window-lifecycle-smoke",
    });
    try std.testing.expect(window_smoke == .window_lifecycle_smoke);
    const init_failure_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--init-failure-smoke",
    });
    try std.testing.expect(init_failure_smoke == .init_failure_smoke);
    const s4_diagnostics_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--s4-diagnostics-smoke",
    });
    try std.testing.expect(s4_diagnostics_smoke == .s4_diagnostics_smoke);
    const s4_physics_debug_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--s4-physics-debug-smoke",
    });
    try std.testing.expectEqual(
        @as(u64, 600),
        s4_physics_debug_smoke.s4_physics_debug_smoke.frames,
    );
    try std.testing.expectEqual(
        @as(u32, 80),
        s4_physics_debug_smoke.s4_physics_debug_smoke.virtual_render_hz,
    );
    const s5_authoring_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--s5-authoring-smoke",
        "--save-root=/tmp/incinerator-s5",
    });
    try std.testing.expect(s5_authoring_smoke == .s5_authoring_smoke);
    const above = try smokeExpectation(.{ .frames = 480, .virtual_render_hz = 240 });
    try std.testing.expectEqual(@as(u64, 120), above.ticks);
    try std.testing.expectEqual(@as(f32, 0), above.min_alpha);
    try std.testing.expectEqual(@as(f32, 0.75), above.max_alpha);
    const eighty_hz = try smokeExpectation(.{ .frames = 160, .virtual_render_hz = 80 });
    try std.testing.expectEqual(@as(u64, 120), eighty_hz.ticks);
    try std.testing.expectEqual(@as(f32, 0), eighty_hz.min_alpha);
    try std.testing.expectEqual(@as(f32, 0.75), eighty_hz.max_alpha);
    try std.testing.expectError(
        error.VisualSmokeOptionWithoutMode,
        parseProgramMode(&[_][]const u8{ "incinerator", "--frames=1" }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{ "incinerator", "--verify-install", "--visual-smoke" }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--visual-smoke",
            "--s1-visual-smoke",
        }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--s1-visual-smoke",
            "--s2-visual-smoke",
        }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--s3-streaming-smoke",
            "--s6-streaming-smoke",
        }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--s6-streaming-smoke",
            "--s7-interaction-smoke",
        }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--s7-interaction-smoke",
            "--s8-population-smoke",
        }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--s8-population-smoke",
            "--s11-combat-smoke",
        }),
    );
    try std.testing.expectError(
        error.DuplicateArgument,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--s11-combat-smoke",
            "--s11-combat-smoke",
        }),
    );
    try std.testing.expectError(
        error.DuplicateArgument,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--s8-population-smoke",
            "--s8-population-smoke",
        }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--window-lifecycle-smoke",
            "--init-failure-smoke",
        }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--s4-diagnostics-smoke",
            "--window-lifecycle-smoke",
        }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--s4-diagnostics-smoke",
            "--s4-physics-debug-smoke",
        }),
    );
    try std.testing.expectError(
        error.VisualSmokeOptionWithoutMode,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--s4-diagnostics-smoke",
            "--frames=8",
        }),
    );
    try std.testing.expectError(
        error.VisualSmokeOptionWithoutMode,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--window-lifecycle-smoke",
            "--frames=8",
        }),
    );
    try std.testing.expectError(
        error.InvalidVirtualRenderRate,
        parseProgramMode(&[_][]const u8{ "incinerator", "--visual-smoke", "--virtual-render-hz=0" }),
    );
    try std.testing.expectError(
        error.InvalidContentRoot,
        parseProgramMode(&[_][]const u8{ "incinerator", "--content-root=relative" }),
    );
    try std.testing.expectError(
        error.InvalidSaveRoot,
        parseProgramMode(&[_][]const u8{ "incinerator", "--save-root=relative" }),
    );
    try std.testing.expectError(
        error.SaveRootRequired,
        parseProgramMode(&[_][]const u8{ "incinerator", "--s5-authoring-smoke" }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--s2-visual-smoke",
            "--content-root=/tmp/incinerator-content",
        }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--s4-physics-debug-smoke",
            "--content-root=/tmp/incinerator-content",
        }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--visual-smoke",
            "--save-root=/tmp/incinerator-saves",
        }),
    );
}
