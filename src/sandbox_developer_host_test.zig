//! Standalone test root for the graphical developer owner.

const std = @import("std");
const build_options = @import("build_options");
const sandbox_developer_host = @import("hosts/sandbox_developer_host.zig");
const viewport_controller = @import("viewport_controller.zig");

test {
    std.testing.refAllDecls(sandbox_developer_host);
    std.testing.refAllDecls(viewport_controller);
}

test "crate gizmo press is claimed before Free Camera world selection" {
    if (build_options.editor_enabled) {
        const editor_module = @import("editor/editor.zig");
        const c = @import("sdl.zig").c;

        var editor = editor_module.Editor{};
        editor.viewport_mode = .free_camera;
        for (&editor.tools) |*registered_tool| {
            if (registered_tool.descriptor.id == .crate_authoring) {
                registered_tool.enabled = true;
            }
        }
        editor.crate_authoring.gizmo_handle_regions[0] = .{
            .minimum = .{ 90, 90 },
            .maximum = .{ 110, 110 },
        };

        var event = std.mem.zeroes(c.SDL_Event);
        event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
        event.button.button = c.SDL_BUTTON_LEFT;
        event.button.x = 100;
        event.button.y = 100;
        try std.testing.expect(editor.processEvent(&event).mouse_reserved);

        event.button.x = 140;
        try std.testing.expect(!editor.processEvent(&event).mouse_reserved);
    } else {
        return error.SkipZigTest;
    }
}

test "editor Escape acceptance routes gizmo menu and explicit quit" {
    if (build_options.editor_enabled) {
        const editor_module = @import("editor/editor.zig");
        const c = @import("sdl.zig").c;

        var editor = editor_module.Editor{};
        editor.viewport_mode = .free_camera;
        editor.crate_authoring = .{
            .id = .{ .namespace = 1, .local = 4 },
            .position = .{ 3, 4, 5 },
            .dirty = true,
        };
        editor.crate_authoring.beginGizmoDrag(.x);
        try std.testing.expect(editor.crate_authoring.applyGizmoDisplacement(.x, 7));

        var event = std.mem.zeroes(c.SDL_Event);
        event.type = c.SDL_EVENT_KEY_DOWN;
        event.key.scancode = c.SDL_SCANCODE_ESCAPE;

        const cancel = editor.processEvent(&event);
        try std.testing.expect(cancel.keyboard_reserved);
        try std.testing.expectEqual([3]f32{ 3, 4, 5 }, editor.crate_authoring.position);
        try std.testing.expect(editor.crate_authoring.dirty);
        try std.testing.expect(!editor.systemMenuOpen());

        const fallback = editor.processEvent(&event);
        try std.testing.expect(!fallback.keyboard_reserved);
        try std.testing.expect(fallback.system_menu_available);
        editor.toggleSystemMenu();
        try std.testing.expect(editor.systemMenuOpen());
        try std.testing.expect(editor.wantsKeyboard() and editor.wantsMouse());

        const resume_route = editor.processEvent(&event);
        try std.testing.expect(resume_route.keyboard_reserved);
        try std.testing.expect(!editor.systemMenuOpen());
        try std.testing.expect(!editor.takeQuitRequested());

        editor.toggleSystemMenu();
        editor.requestSystemMenuQuit();
        try std.testing.expect(editor.takeQuitRequested());
        try std.testing.expect(!editor.takeQuitRequested());
    } else {
        return error.SkipZigTest;
    }
}

test "Vehicle Lab single Apply queues one revisioned live or reconstruction request" {
    if (!build_options.editor_enabled) return;
    const lab = @import("editor/tools/vehicle_lab_tool.zig");
    const contract = @import("vehicle_authoring_contract");
    const definition = contract.vehicle.asset.validationFixture();
    var live = std.mem.zeroes(contract.vehicle.VehicleView);
    live.definition = definition;
    live.id = .{ .namespace = 77, .local = 1 };
    live.revision = 7;
    var state = lab.State{};
    defer state.deinit();
    const inspection = contract.Inspection{ .live = live, .committed = definition, .asset_revision = definition.revision };
    try state.synchronize(std.testing.allocator, inspection, null);
    var requests = contract.Requests{ .allocator = std.testing.allocator };
    defer requests.deinit();
    const input_value = contract.Input{ .allocator = std.testing.allocator, .inspection = inspection, .result = null, .requests = &requests };
    state.draft.?.value.tuning.steering.rise_per_second += 1;
    state.applyDraft(input_value);
    try std.testing.expectEqual(@as(usize, 1), requests.pending.items.len);
    try std.testing.expectEqual(.apply, std.meta.activeTag(requests.pending.items[0].value.action));
    try std.testing.expectEqual(live.revision, requests.pending.items[0].value.expected_revision);
    requests.clear();
    state.draft.?.value.tuning.max_steer_radians *= 1.1;
    state.applyDraft(input_value);
    try std.testing.expectEqual(@as(usize, 1), requests.pending.items.len);
    const request = requests.pending.items[0].value;
    try std.testing.expectEqual(.rebuild, std.meta.activeTag(request.action));
    try std.testing.expectEqualDeep(live.id, request.target);
    try std.testing.expectEqual(live.revision, request.expected_revision);
    try std.testing.expectEqual(definition.revision, request.expected_asset_revision);
    try std.testing.expectEqual(state.draft.?.value.tuning.max_steer_radians, request.action.rebuild.tuning.max_steer_radians);
}
