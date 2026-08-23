//! Searchable, read-only projection of selectable world instances.

const std = @import("std");
const zgui = @import("zgui");
const tool_module = @import("../tool.zig");
const selection = tool_module.selection;

pub const descriptor = tool_module.Descriptor{
    .id = .world_outliner,
    .name = "World Outliner",
    .category = .world,
    .default_region = .left,
    .purpose = "Discover and select stable world instances without exposing backend handles.",
    .reads = "One immutable, sorted editor SelectionView projected by the visual composition.",
    .requests = "Typed editor-local select or clear request only.",
    .examples = &.{ "search crate", "filter npc", "select stable gameplay incarnation" },
    .audit_fields = &.{ "selection_identity", "object_kind", "owner", "availability", "capabilities" },
};

pub const State = struct {
    search_storage: std.ArrayListUnmanaged(u8) = .empty,
    search_len: usize = 0,
    kind_filter: ?selection.ObjectKind = null,
    last_active: ?selection.Id = null,

    pub fn deinit(self: *State) void {
        self.search_storage.deinit(std.heap.page_allocator);
        self.* = .{};
    }

    fn searchBuffer(self: *State) ![:0]u8 {
        if (self.search_storage.capacity < 2) {
            try self.search_storage.ensureTotalCapacity(std.heap.page_allocator, 2);
        }
        self.search_storage.items.len = self.search_storage.capacity;
        if (self.search_len >= self.search_storage.items.len) self.search_len = 0;
        self.search_storage.items[self.search_len] = 0;
        self.search_storage.items[self.search_storage.items.len - 1] = 0;
        return self.search_storage.items[0 .. self.search_storage.items.len - 1 :0];
    }

    fn search(self: *const State) []const u8 {
        return self.search_storage.items[0..self.search_len];
    }

    fn reveal(self: *State, entry: selection.Entry) void {
        if (selection.matches(entry, self.search(), self.kind_filter)) return;
        self.kind_filter = null;
        self.search_len = 0;
        if (self.search_storage.items.len != 0) self.search_storage.items[0] = 0;
    }
};

fn resizeSearch(data: *zgui.InputTextCallbackData) callconv(.c) i32 {
    if (!data.event_flag.callback_resize) return 0;
    const state: *State = @ptrCast(@alignCast(data.user_data orelse return 1));
    const text_len: usize = @intCast(@max(data.buf_text_len, 0));
    const required: usize = @intCast(@max(data.buf_size, data.buf_text_len + 1));
    state.search_storage.ensureTotalCapacity(
        std.heap.page_allocator,
        required,
    ) catch return 1;
    state.search_storage.items.len = state.search_storage.capacity;
    state.search_len = text_len;
    state.search_storage.items[text_len] = 0;
    data.buf = state.search_storage.items.ptr;
    data.buf_size = @intCast(state.search_storage.items.len);
    return 0;
}

fn optionalIdEql(first: ?selection.Id, second: ?selection.Id) bool {
    if (first == null or second == null) return first == null and second == null;
    return first.?.eql(second.?);
}

fn identityText(entry: selection.Entry) void {
    switch (entry.id) {
        .persistent_entity => |id| zgui.textDisabled(
            "persistent {d}:{d}",
            .{ id.namespace, id.local },
        ),
        .gameplay_entity => |id| zgui.textDisabled(
            "gameplay {d}:{d}:{d}",
            .{ id.namespace, id.local, id.incarnation },
        ),
        .content_asset => |id| zgui.textDisabled(
            "asset {d}:{d}",
            .{ id.namespace, id.local },
        ),
    }
}

fn capabilityText(entry: selection.Entry) []const u8 {
    if (entry.availability == .unavailable) return "UNAVAILABLE";
    if (entry.authorable) return "AUTHORABLE";
    if (entry.inspectable) return "READ-ONLY";
    return "NOT INSPECTABLE";
}

pub fn draw(state: *State, ctx: *const tool_module.SelectionInput) void {
    if (zgui.begin("World Outliner", .{})) {
        const reveal_active = !optionalIdEql(state.last_active, ctx.view.active);
        if (reveal_active) if (ctx.view.activeEntry()) |entry| state.reveal(entry.*);
        if (state.searchBuffer()) |buffer| {
            zgui.setNextItemWidth(-1);
            _ = zgui.inputTextWithHint("##outliner_search", .{
                .hint = "Search label or type",
                .buf = buffer,
                .flags = .{ .callback_resize = true },
                .callback = resizeSearch,
                .user_data = state,
            });
            state.search_len = std.mem.indexOfScalar(u8, state.search_storage.items, 0) orelse
                state.search_storage.items.len;
        } else |_| {
            zgui.textColored(.{ 1, 0.35, 0.2, 1 }, "Search allocation unavailable", .{});
        }

        const filter_label: [:0]const u8 = if (state.kind_filter) |kind|
            @tagName(kind)
        else
            "All types";
        zgui.setNextItemWidth(150);
        if (zgui.beginCombo("##outliner_type", .{ .preview_value = filter_label })) {
            if (zgui.selectable("All types", .{ .selected = state.kind_filter == null })) {
                state.kind_filter = null;
            }
            inline for (std.meta.tags(selection.ObjectKind)) |kind| {
                if (zgui.selectable(@tagName(kind), .{
                    .selected = state.kind_filter == kind,
                })) state.kind_filter = kind;
            }
            zgui.endCombo();
        }

        zgui.sameLine(.{});
        if (zgui.button("Clear Selection", .{})) ctx.requests.submit(.clear);
        zgui.textDisabled("{d} selectable instances", .{ctx.view.entries.len});
        zgui.separator();

        var visible_count: usize = 0;
        if (zgui.beginChild("##outliner_entries", .{
            .child_flags = .{ .frame_style = true },
        })) {
            for (ctx.view.entries, 0..) |entry, index| {
                if (!selection.matches(entry, state.search(), state.kind_filter)) continue;
                visible_count += 1;
                zgui.pushIntId(@intCast(index));
                defer zgui.popId();
                const active = if (ctx.view.active) |id| id.eql(entry.id) else false;
                if (zgui.selectable(switch (entry.kind) {
                    .crate => "Crate",
                    .local_player => "Local Player",
                    .remote_player => "Remote Player",
                    .npc => "NPC",
                    .vehicle => "Vehicle",
                    .carryable => "Carryable",
                    .content_asset => "Content Asset",
                }, .{
                    .selected = active,
                    .flags = .{ .disabled = entry.availability == .unavailable },
                })) ctx.requests.submit(.{ .select = entry.id });
                identityText(entry);
                zgui.sameLine(.{});
                zgui.textDisabled(
                    "owner={s}  {s}",
                    .{ @tagName(entry.owner), capabilityText(entry) },
                );
                if (active and reveal_active) zgui.setScrollHereY(.{});
                zgui.separator();
            }
            if (visible_count == 0) zgui.textDisabled("No matching world instances", .{});
        }
        zgui.endChild();
        state.last_active = ctx.view.active;
    }
    zgui.end();
}

test "viewport selection reveals an entry hidden by outliner filters" {
    var state = State{ .kind_filter = .npc };
    defer state.deinit();
    try state.search_storage.appendSlice(std.heap.page_allocator, "npc");
    state.search_len = 3;

    const crate = selection.Entry{
        .id = .{ .persistent_entity = .{ .namespace = 1, .local = 1 } },
        .label = "Crate",
        .kind = .crate,
        .owner = .game_runtime,
        .inspectable = true,
        .authorable = true,
        .world_bounds = try selection.Bounds.init(.{ 0, 0, 0 }, .{ 1, 1, 1 }),
    };
    state.reveal(crate);
    try std.testing.expect(state.kind_filter == null);
    try std.testing.expectEqual(@as(usize, 0), state.search_len);
}
