//! Renderer-neutral ED1 workspace identities, presets, and startup parsing.
//!
//! This module deliberately imports only the standard library. Product and
//! validation invocation parsing can use it without acquiring ImGui, SDL, or
//! the graphical editor implementation.

const std = @import("std");

pub const ToolId = enum {
    stats,
    camera,
    render,
    diagnostics,
    gameplay_inspector,
    navigation_lab,
    population_lab,
    incident_capture,
    physics_debug,
    crate_authoring,
    interaction,
    neural_rendering_lab,

    pub fn parse(text: []const u8) !ToolId {
        inline for (std.meta.tags(ToolId)) |candidate| {
            if (std.mem.eql(u8, text, @tagName(candidate))) return candidate;
        }
        return error.InvalidEditorPanel;
    }
};

pub const tool_count = std.meta.tags(ToolId).len;

pub const Category = enum {
    performance,
    gameplay,
    world,
    rendering,
    diagnostics,
    authoring,
    experimental,
};

pub const Region = enum {
    left,
    right,
    bottom,
};

pub const Availability = enum {
    active,
    paused,
};

pub const Descriptor = struct {
    id: ToolId,
    name: [:0]const u8,
    category: Category,
    default_region: Region,
    purpose: []const u8,
    reads: []const u8,
    requests: []const u8,
    examples: []const []const u8,
    audit_fields: []const []const u8,
    availability: Availability = .active,

    pub fn isComplete(self: Descriptor) bool {
        if (self.name.len == 0 or self.purpose.len == 0 or self.reads.len == 0 or
            self.requests.len == 0 or self.examples.len == 0 or
            self.audit_fields.len == 0)
        {
            return false;
        }
        for (self.examples) |example| if (example.len == 0) return false;
        for (self.audit_fields) |field| if (field.len == 0) return false;
        return true;
    }
};

pub const LayoutPreset = enum {
    gameplay,
    navigation,
    population,
    rendering,
    incident,
    minimal,
    all,

    pub fn parse(text: []const u8) !LayoutPreset {
        inline for (std.meta.tags(LayoutPreset)) |candidate| {
            if (std.mem.eql(u8, text, @tagName(candidate))) return candidate;
        }
        return error.InvalidEditorLayout;
    }
};

pub const PanelMask = struct {
    enabled: [tool_count]bool = @splat(false),

    pub fn contains(self: PanelMask, id: ToolId) bool {
        return self.enabled[@intFromEnum(id)];
    }

    pub fn set(self: *PanelMask, id: ToolId, value: bool) void {
        self.enabled[@intFromEnum(id)] = value;
    }

    pub fn fromPreset(preset: LayoutPreset) PanelMask {
        var result = PanelMask{};
        inline for (std.meta.tags(ToolId)) |id| {
            result.set(id, presetContains(preset, id));
        }
        return result;
    }
};

pub const StartupConfig = struct {
    layout: LayoutPreset = .gameplay,
    layout_explicit: bool = false,
    exact_panels: ?PanelMask = null,
    focus: ?ToolId = null,
    show_guide: bool = false,
};

pub fn defaultFocus(preset: LayoutPreset) ToolId {
    return switch (preset) {
        .gameplay, .minimal, .all => .gameplay_inspector,
        .navigation => .navigation_lab,
        .population => .population_lab,
        .rendering => .render,
        .incident => .incident_capture,
    };
}

pub const UtcText = struct {
    bytes: [24]u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const UtcText) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub fn formatUtcWallMs(wall_unix_ms: i64) UtcText {
    const milliseconds: u64 = if (wall_unix_ms <= 0) 0 else @intCast(wall_unix_ms);
    const seconds = @divFloor(milliseconds, std.time.ms_per_s);
    const millis = @mod(milliseconds, std.time.ms_per_s);
    const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    var result = UtcText{};
    const rendered = std.fmt.bufPrint(
        &result.bytes,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
        .{
            year_day.year,
            @intFromEnum(month_day.month),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            millis,
        },
    ) catch unreachable;
    result.len = @intCast(rendered.len);
    return result;
}

pub fn isStartupArgument(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--editor-guide") or
        std.mem.startsWith(u8, arg, "--editor-layout=") or
        std.mem.startsWith(u8, arg, "--editor-panels=") or
        std.mem.startsWith(u8, arg, "--editor-focus=");
}

pub fn parseStartup(args: anytype) !StartupConfig {
    var result = StartupConfig{};
    var layout_seen = false;
    var panels_seen = false;
    var focus_seen = false;
    var guide_seen = false;

    for (args[1..args.len]) |raw_arg| {
        const arg: []const u8 = raw_arg;
        if (std.mem.startsWith(u8, arg, "--editor-layout=")) {
            if (layout_seen) return error.DuplicateArgument;
            layout_seen = true;
            result.layout = try LayoutPreset.parse(arg["--editor-layout=".len..]);
            result.layout_explicit = true;
        } else if (std.mem.startsWith(u8, arg, "--editor-panels=")) {
            if (panels_seen) return error.DuplicateArgument;
            panels_seen = true;
            result.exact_panels = try parsePanelMask(arg["--editor-panels=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--editor-focus=")) {
            if (focus_seen) return error.DuplicateArgument;
            focus_seen = true;
            result.focus = try ToolId.parse(arg["--editor-focus=".len..]);
        } else if (std.mem.eql(u8, arg, "--editor-guide")) {
            if (guide_seen) return error.DuplicateArgument;
            guide_seen = true;
            result.show_guide = true;
        }
    }

    const open_panels = result.exact_panels orelse PanelMask.fromPreset(result.layout);
    if (result.focus) |focus| {
        if (!open_panels.contains(focus)) return error.EditorFocusPanelClosed;
    }
    return result;
}

fn parsePanelMask(text: []const u8) !PanelMask {
    if (text.len == 0) return error.InvalidEditorPanel;
    var result = PanelMask{};
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidEditorPanel;
        const id = try ToolId.parse(part);
        if (result.contains(id)) return error.DuplicateEditorPanel;
        result.set(id, true);
    }
    return result;
}

fn presetContains(preset: LayoutPreset, id: ToolId) bool {
    if (id == .neural_rendering_lab) return false;
    return switch (preset) {
        .gameplay => switch (id) {
            .gameplay_inspector,
            .interaction,
            .stats,
            .diagnostics,
            .incident_capture,
            => true,
            else => false,
        },
        .navigation => switch (id) {
            .gameplay_inspector,
            .navigation_lab,
            .population_lab,
            .stats,
            .diagnostics,
            .incident_capture,
            => true,
            else => false,
        },
        .population => switch (id) {
            .gameplay_inspector,
            .navigation_lab,
            .population_lab,
            .diagnostics,
            .incident_capture,
            => true,
            else => false,
        },
        .rendering => switch (id) {
            .camera,
            .render,
            .physics_debug,
            .stats,
            .diagnostics,
            .incident_capture,
            => true,
            else => false,
        },
        .incident => switch (id) {
            .gameplay_inspector,
            .diagnostics,
            .incident_capture,
            .stats,
            => true,
            else => false,
        },
        .minimal => switch (id) {
            .gameplay_inspector, .incident_capture => true,
            else => false,
        },
        .all => true,
    };
}

test "startup parser accepts deterministic LLM workspace selection" {
    const config = try parseStartup(&[_][]const u8{
        "incinerator",
        "--editor-layout=navigation",
        "--editor-panels=gameplay_inspector,navigation_lab,diagnostics",
        "--editor-focus=navigation_lab",
        "--editor-guide",
        "--content-root=/tmp/content",
    });
    try std.testing.expectEqual(LayoutPreset.navigation, config.layout);
    try std.testing.expect(config.layout_explicit);
    try std.testing.expect(config.show_guide);
    try std.testing.expectEqual(ToolId.navigation_lab, config.focus.?);
    try std.testing.expect(config.exact_panels.?.contains(.gameplay_inspector));
    try std.testing.expect(config.exact_panels.?.contains(.navigation_lab));
    try std.testing.expect(config.exact_panels.?.contains(.diagnostics));
    try std.testing.expect(!config.exact_panels.?.contains(.population_lab));
}

test "startup parser rejects unknown duplicate and closed focus panels" {
    try std.testing.expectError(
        error.InvalidEditorLayout,
        parseStartup(&[_][]const u8{ "incinerator", "--editor-layout=unknown" }),
    );
    try std.testing.expectError(
        error.InvalidEditorPanel,
        parseStartup(&[_][]const u8{ "incinerator", "--editor-panels=unknown" }),
    );
    try std.testing.expectError(
        error.DuplicateEditorPanel,
        parseStartup(&[_][]const u8{
            "incinerator",
            "--editor-panels=stats,stats",
        }),
    );
    try std.testing.expectError(
        error.EditorFocusPanelClosed,
        parseStartup(&[_][]const u8{
            "incinerator",
            "--editor-panels=diagnostics",
            "--editor-focus=stats",
        }),
    );
}

test "all deterministic preset excludes the paused neural panel" {
    const all = PanelMask.fromPreset(.all);
    try std.testing.expect(all.contains(.stats));
    try std.testing.expect(all.contains(.population_lab));
    try std.testing.expect(!all.contains(.neural_rendering_lab));
}

test "UTC status formatting matches incident wall milliseconds" {
    const text = formatUtcWallMs(1_784_488_696_237);
    try std.testing.expectEqualStrings("2026-07-19T19:18:16.237Z", text.slice());
}
