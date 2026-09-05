//! Searchable project content inventory with separate asset selection.

const std = @import("std");
const zgui = @import("zgui");
const tool_module = @import("../tool.zig");
const content_selection = @import("../content_selection.zig");
const engine = @import("incinerator_engine");

pub const descriptor = tool_module.Descriptor{
    .id = .content_browser,
    .name = "Content Browser",
    .category = .authoring,
    .default_region = .bottom,
    .purpose = "Explore stable cooked game assets by bundle and kind without mixing them with world instances.",
    .reads = "Immutable cooked asset catalog including dependencies, source format, cook status, and residency.",
    .requests = "Editor-local typed content-asset selection only.",
    .examples = &.{ "find CargoCratePanels", "filter materials", "inspect sampler metadata" },
    .audit_fields = &.{ "asset_id", "kind", "owner", "revision", "digest", "dependencies", "residency" },
};

pub const State = struct {
    search: [128:0]u8 = @splat(0),
    kind: ?engine.assets.Kind = null,
    owner: ?engine.assets.Owner = null,
    cook_status: ?engine.assets.CookStatus = null,
};

pub fn matches(
    entry: engine.assets.Entry,
    search: []const u8,
    kind: ?engine.assets.Kind,
    owner: ?engine.assets.Owner,
    cook_status: ?engine.assets.CookStatus,
) bool {
    if (kind) |expected| if (entry.kind != expected) return false;
    if (owner) |expected| if (entry.owner != expected) return false;
    if (cook_status) |expected| if (entry.cook_status != expected) return false;
    if (search.len == 0) return true;
    return containsIgnoreCase(entry.label, search) or containsIgnoreCase(entry.bundle_key, search);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |offset| {
        if (std.ascii.eqlIgnoreCase(haystack[offset..][0..needle.len], needle)) return true;
    }
    return false;
}

pub fn draw(state: *State, ctx: *const content_selection.View, requests: *content_selection.Requests) void {
    if (zgui.begin("Content Browser", .{})) {
        zgui.setNextItemWidth(-1);
        _ = zgui.inputTextWithHint("##content_search", .{
            .hint = "Search asset or bundle",
            .buf = &state.search,
        });
        const preview: [:0]const u8 = if (state.kind) |kind| @tagName(kind) else "All asset types";
        zgui.setNextItemWidth(150);
        if (zgui.beginCombo("##content_kind", .{ .preview_value = preview })) {
            if (zgui.selectable("All asset types", .{ .selected = state.kind == null })) state.kind = null;
            inline for (std.meta.tags(engine.assets.Kind)) |kind| {
                if (zgui.selectable(@tagName(kind), .{ .selected = state.kind == kind })) state.kind = kind;
            }
            zgui.endCombo();
        }
        zgui.sameLine(.{});
        const owner_preview: [:0]const u8 = if (state.owner) |owner| @tagName(owner) else "All owners";
        zgui.setNextItemWidth(110);
        if (zgui.beginCombo("##content_owner", .{ .preview_value = owner_preview })) {
            if (zgui.selectable("All owners", .{ .selected = state.owner == null })) state.owner = null;
            inline for (std.meta.tags(engine.assets.Owner)) |owner| {
                if (zgui.selectable(@tagName(owner), .{ .selected = state.owner == owner })) state.owner = owner;
            }
            zgui.endCombo();
        }
        zgui.sameLine(.{});
        const cook_preview: [:0]const u8 = if (state.cook_status) |status| @tagName(status) else "All cook states";
        zgui.setNextItemWidth(130);
        if (zgui.beginCombo("##content_cook_status", .{ .preview_value = cook_preview })) {
            if (zgui.selectable("All cook states", .{ .selected = state.cook_status == null })) state.cook_status = null;
            inline for (std.meta.tags(engine.assets.CookStatus)) |status| {
                if (zgui.selectable(@tagName(status), .{ .selected = state.cook_status == status })) state.cook_status = status;
            }
            zgui.endCombo();
        }
        zgui.sameLine(.{});
        if (zgui.button("Clear Asset Selection", .{})) requests.submit(.clear);
        zgui.sameLine(.{});
        zgui.textDisabled("{d} cooked assets", .{ctx.entries.len});
        zgui.separator();

        const search = std.mem.sliceTo(&state.search, 0);
        var last_bundle: []const u8 = "";
        var visible: usize = 0;
        for (ctx.entries, 0..) |entry, index| {
            if (!matches(entry, search, state.kind, state.owner, state.cook_status)) continue;
            visible += 1;
            if (!std.mem.eql(u8, last_bundle, entry.bundle_key)) {
                if (last_bundle.len != 0) zgui.spacing();
                zgui.textColored(.{ 0.35, 0.75, 1, 1 }, "{s}", .{entry.bundle_key});
                last_bundle = entry.bundle_key;
            }
            zgui.pushIntId(@intCast(index));
            defer zgui.popId();
            const selected = if (ctx.active) |id| std.meta.eql(id, entry.id) else false;
            if (zgui.selectable(switch (entry.kind) {
                .scene => "Scene",
                .mesh => "Mesh",
                .material => "Material",
                .texture => "Texture",
            }, .{ .selected = selected })) {
                requests.submit(.{ .select = entry.id });
            }
            zgui.sameLine(.{});
            zgui.textDisabled(
                "{s} | {s} | r{d} | {s}",
                .{ entry.label, @tagName(entry.owner), entry.revision, @tagName(entry.residency) },
            );
        }
        if (visible == 0) zgui.textDisabled("No matching cooked assets", .{});
    }
    zgui.end();
}

test "content browser matches labels bundles and kinds case-insensitively" {
    var digest: engine.assets.Digest = @splat(0);
    digest[0] = 1;
    const entry = engine.assets.Entry{
        .id = try engine.assets.deriveGameAssetId(.texture, "district/cargo", "CargoCratePanels"),
        .kind = .texture,
        .owner = .game,
        .label = "CargoCratePanels",
        .bundle_key = "district/cargo",
        .revision = 1,
        .digest = digest,
        .dependencies = &.{},
        .source_format = .gltf,
        .cook_status = .valid,
        .residency = .resident,
        .last_use_frame = null,
        .details = .{ .texture = .{
            .width = 128,
            .height = 128,
            .color_space = .srgb,
            .encoding = .jpeg,
            .sampler = .{},
        } },
    };
    try std.testing.expect(matches(entry, "crate", null, null, null));
    try std.testing.expect(matches(entry, "DISTRICT/CARGO", .texture, .game, .valid));
    try std.testing.expect(!matches(entry, "crate", .material, null, null));
    try std.testing.expect(!matches(entry, "crate", .texture, .engine, null));
    try std.testing.expect(!matches(entry, "crate", .texture, .game, .invalid));
}
