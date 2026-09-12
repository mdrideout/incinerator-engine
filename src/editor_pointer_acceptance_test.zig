//! Real queued SDL events, real ImGui windows, and a Metal-presented frame.
const std = @import("std");
const zgui = @import("zgui");
const editor_module = @import("editor/editor.zig");
const input = @import("input.zig");
const c = @import("sdl.zig").c;

fn draw(editor: *editor_module.Editor, window: *c.SDL_Window, device: *c.SDL_GPUDevice) !void {
    editor.backend.newFrame(640, 360, 1);
    _ = zgui.dockSpaceOverViewport(0, zgui.getMainViewport(), .{
        .passthru_central_node = true,
        .no_docking_over_central_node = true,
    });
    zgui.setNextWindowPos(.{ .x = 150, .y = 80, .cond = .always });
    zgui.setNextWindowSize(.{ .w = 240, .h = 180, .cond = .always });
    if (zgui.begin("Inspector Pointer Acceptance", .{ .flags = .{ .no_saved_settings = true } })) {
        zgui.text("Unapplied Inspector draft", .{});
        _ = zgui.button("Apply Position", .{});
    }
    zgui.end();
    const command = c.SDL_AcquireGPUCommandBuffer(device) orelse return error.CommandBufferFailed;
    var texture: ?*c.SDL_GPUTexture = null;
    var width: u32 = 0;
    var height: u32 = 0;
    if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(command, window, &texture, &width, &height))
        return error.SwapchainFailed;
    if (texture) |target| {
        editor.backend.render(command, target);
    } else zgui.render();
    if (!c.SDL_SubmitGPUCommandBuffer(command)) return error.SubmitFailed;
}

fn button(window: *c.SDL_Window, down: bool, x: f32, y: f32) !void {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = if (down) c.SDL_EVENT_MOUSE_BUTTON_DOWN else c.SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.windowID = c.SDL_GetWindowID(window);
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.down = down;
    event.button.x = x;
    event.button.y = y;
    if (!c.SDL_PushEvent(&event)) return error.PushFailed;
}

fn motion(window: *c.SDL_Window, x: f32, y: f32) !void {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_MOUSE_MOTION;
    event.motion.windowID = c.SDL_GetWindowID(window);
    event.motion.x = x;
    event.motion.y = y;
    if (!c.SDL_PushEvent(&event)) return error.PushFailed;
}

test "floating Inspector native acceptance owns same-pump press drag release in both viewport modes" {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SDLInitFailed;
    defer c.SDL_Quit();
    const window = c.SDL_CreateWindow("Incinerator Editor Pointer Acceptance", 640, 360, 0) orelse return error.WindowFailed;
    defer c.SDL_DestroyWindow(window);
    const device = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_MSL, true, "metal") orelse return error.MetalFailed;
    defer c.SDL_DestroyGPUDevice(device);
    if (!c.SDL_ClaimWindowForGPUDevice(device, window)) return error.ClaimFailed;
    defer c.SDL_ReleaseWindowFromGPUDevice(device, window);
    var editor = editor_module.Editor.init(window, device, c.SDL_GetGPUSwapchainTextureFormat(device, window));
    defer editor.deinit();
    zgui.io.setIniFilename(null);
    editor.scene_rect = input.viewport.SceneRect.init(.{ 0, 0 }, .{ 640, 360 });
    var owner = input.InputBuffer.init(c.SDL_GetWindowID(window));
    try owner.attachGameplayMouseWindow(window);
    defer owner.detachGameplayMouseWindow();
    _ = c.SDL_RaiseWindow(window);
    _ = c.SDL_SyncWindow(window);
    c.SDL_WarpMouseInWindow(window, 550, 320);
    try std.testing.expect(owner.pumpEvents(editor.eventSink()));
    try draw(&editor, window, device);
    try draw(&editor, window, device);

    for ([_]input.viewport.Mode{ .free_camera, .character }) |mode| {
        owner.setViewportMode(mode);
        editor.setViewportMode(mode);
        // No ImGui NewFrame between movement into the floating panel and press.
        try motion(window, 200, 120);
        try button(window, true, 200, 120);
        owner.beginFrame();
        try std.testing.expect(owner.pumpEvents(editor.eventSink()));
        try std.testing.expect(!owner.gameplayMouseLocked());
        try std.testing.expect(owner.takeFreeCameraSelectionClick() == null);
        try std.testing.expect(!owner.isMouseButtonPressed(input.MouseButton.LEFT));
        try motion(window, 550, 320);
        owner.beginFrame();
        try std.testing.expect(owner.pumpEvents(editor.eventSink()));
        try std.testing.expect(editor.wantsMouse());
        try button(window, false, 550, 320);
        try std.testing.expect(owner.pumpEvents(editor.eventSink()));
        try std.testing.expectEqual(@as(u32, 0), editor.backend.pointer_buttons);
        try button(window, true, 200, 120);
        try std.testing.expect(owner.pumpEvents(editor.eventSink()));
        var lost = std.mem.zeroes(c.SDL_Event);
        lost.type = c.SDL_EVENT_WINDOW_FOCUS_LOST;
        lost.window.windowID = c.SDL_GetWindowID(window);
        if (!c.SDL_PushEvent(&lost)) return error.PushFailed;
        try std.testing.expect(owner.pumpEvents(editor.eventSink()));
        try std.testing.expectEqual(@as(u32, 0), editor.backend.pointer_buttons);
        try button(window, false, 200, 120);
        try std.testing.expect(owner.pumpEvents(editor.eventSink()));
        // The next press over the passthrough central scene belongs to it.
        try button(window, true, 550, 320);
        owner.beginFrame();
        try std.testing.expect(owner.pumpEvents(editor.eventSink()));
        if (mode == .free_camera) {
            try std.testing.expect(owner.takeFreeCameraSelectionClick() != null);
        } else try std.testing.expect(owner.gameplayMouseLocked());
        try button(window, false, 550, 320);
        try std.testing.expect(owner.pumpEvents(editor.eventSink()));
    }
    try std.testing.expect(c.SDL_WaitForGPUIdle(device));
}

const material_lab = @import("editor/tools/material_lab_tool.zig");
const material_contract = @import("material_authoring_contract");
const material_authoring = @import("material_authoring");
const assets = @import("incinerator_engine").assets;
const material_library = @import("content").material_library;

const MaterialJourney = struct {
    editor: *editor_module.Editor,
    window: *c.SDL_Window,
    device: *c.SDL_GPUDevice,
    owner: *material_authoring.Owner,
    requests: material_contract.Requests = .{ .allocator = std.testing.allocator },
    mode: material_contract.PreviewMode = .world,
    selected: ?assets.AssetId = null,
    extent: u32 = 0,
    entries: []const assets.Entry,
    store: material_authoring.Store,

    fn frame(self: *@This()) !void {
        self.editor.backend.newFrame(720, 720, 1);
        zgui.setNextWindowPos(.{ .x = 50, .y = 50, .cond = .always });
        zgui.setNextWindowSize(.{ .w = 610, .h = 630, .cond = .always });
        var selection_requests = @import("editor/content_selection.zig").Requests{};
        material_lab.draw(&self.editor.material_lab, .{
            .view = .{ .records = self.owner.records, .bindings = self.owner.bindings, .last_ui_outcome = self.owner.last_ui_outcome, .persistence_available = true },
            .requests = &self.requests,
            .preview_mode = &self.mode,
            .preview_material = &self.selected,
            .preview_extent = &self.extent,
        }, .{ .entries = self.entries, .active = self.entries[0].id }, &selection_requests);
        const command = c.SDL_AcquireGPUCommandBuffer(self.device) orelse return error.CommandBufferFailed;
        var target: ?*c.SDL_GPUTexture = null;
        var width: u32 = 0;
        var height: u32 = 0;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(command, self.window, &target, &width, &height)) return error.SwapchainFailed;
        if (target) |texture| self.editor.backend.render(command, texture) else zgui.render();
        if (!c.SDL_SubmitGPUCommandBuffer(command)) return error.SubmitFailed;
        for (self.requests.pending.items) |request| {
            const result = try self.owner.execute(.ui, request, self.store);
            try std.testing.expect(result.rejection == null);
        }
        self.requests.pending.clearRetainingCapacity();
    }

    fn click(self: *@This(), input_owner: *input.InputBuffer, item: material_lab.AcceptanceItem, fraction: f32) !void {
        const rect = material_lab.acceptance_rects[@intFromEnum(item)];
        const x = rect[0][0] + (rect[1][0] - rect[0][0]) * fraction;
        const y = (rect[0][1] + rect[1][1]) / 2;
        c.SDL_WarpMouseInWindow(self.window, x, y);
        try motion(self.window, x, y);
        input_owner.beginFrame();
        try std.testing.expect(input_owner.pumpEvents(self.editor.eventSink()));
        try self.frame();
        try button(self.window, true, x, y);
        input_owner.beginFrame();
        try std.testing.expect(input_owner.pumpEvents(self.editor.eventSink()));
        try std.testing.expect(!input_owner.gameplayMouseLocked());
        try std.testing.expect(input_owner.takeFreeCameraSelectionClick() == null);
        try self.frame();
        try button(self.window, false, x, y);
        input_owner.beginFrame();
        try std.testing.expect(input_owner.pumpEvents(self.editor.eventSink()));
        try self.frame();
        try self.frame();
    }
};

test "Material Lab native SDL controls preview apply revert commit and restart the shared owner" {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SDLInitFailed;
    defer c.SDL_Quit();
    const window = c.SDL_CreateWindow("Incinerator Material Lab Acceptance", 720, 720, 0) orelse return error.WindowFailed;
    defer c.SDL_DestroyWindow(window);
    const device = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_MSL, true, "metal") orelse return error.MetalFailed;
    defer c.SDL_DestroyGPUDevice(device);
    if (!c.SDL_ClaimWindowForGPUDevice(device, window)) return error.ClaimFailed;
    defer c.SDL_ReleaseWindowFromGPUDevice(device, window);
    var editor = editor_module.Editor.init(window, device, c.SDL_GetGPUSwapchainTextureFormat(device, window));
    defer editor.deinit();
    zgui.io.setIniFilename(null);
    editor.scene_rect = input.viewport.SceneRect.init(.{ 0, 0 }, .{ 720, 720 });
    var input_owner = input.InputBuffer.init(c.SDL_GetWindowID(window));
    try input_owner.attachGameplayMouseWindow(window);
    defer input_owner.detachGameplayMouseWindow();
    const id = try assets.deriveGameAssetId(.material, "acceptance", "Steel");
    const initial = assets.MaterialMetadata{ .base_color = .{ 0.2, 0.3, 0.4, 1 }, .base_color_texture = null, .base_color_texcoord = 0, .roughness = 0.9 };
    const definitions = [_]material_library.Definition{.{ .id = id, .label = "Steel", .revision = 1, .value = initial }};
    const entries = [_]assets.Entry{.{ .id = id, .kind = .material, .owner = .game, .label = "Steel", .bundle_key = "acceptance", .revision = 1, .digest = initial.digest(), .dependencies = &.{}, .source_format = .glb, .cook_status = .valid, .residency = .resident, .last_use_frame = null, .details = .{ .material = initial } }};
    var owner = try material_authoring.Owner.init(std.testing.allocator, .{ .materials = &definitions, .bindings = &.{} }, &entries);
    defer owner.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const Disk = struct {
        dir: std.Io.Dir,
        fn write(context: *anyopaque, value: material_library.Library) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try material_library.write(std.testing.allocator, std.testing.io, self.dir, value);
        }
    };
    var disk = Disk{ .dir = temporary.dir };
    var journey = MaterialJourney{ .editor = &editor, .window = window, .device = device, .owner = &owner, .entries = &entries, .store = .{ .context = &disk, .write_fn = Disk.write } };
    defer journey.requests.deinit();
    _ = c.SDL_RaiseWindow(window);
    _ = c.SDL_SyncWindow(window);
    try std.testing.expect(input_owner.pumpEvents(editor.eventSink()));
    try journey.frame();
    try journey.frame();
    for ([_]input.viewport.Mode{ .character, .free_camera }) |mode| {
        input_owner.setViewportMode(mode);
        editor.setViewportMode(mode);
        try journey.click(&input_owner, .roughness, 0.35);
        try std.testing.expect(editor.material_lab.dirty);
        const draft = editor.material_lab.draft;
        try std.testing.expect(draft.roughness != initial.roughness);
        try journey.click(&input_owner, .preview, 0.5);
        try std.testing.expectEqualDeep(draft, owner.find(id).?.presented());
        try std.testing.expectEqualDeep(initial, owner.find(id).?.session);
        try journey.click(&input_owner, .apply, 0.5);
        try std.testing.expectEqualDeep(draft, owner.find(id).?.session);
        try std.testing.expect(owner.find(id).?.preview == null);
        try journey.click(&input_owner, .revert, 0.5);
        try std.testing.expectEqualDeep(initial, owner.find(id).?.session);
        // Escape rolls back the control while the pointer remains held. A
        // later frame must not re-apply the cancelled slider value.
        const rect = material_lab.acceptance_rects[@intFromEnum(material_lab.AcceptanceItem.roughness)];
        const x = rect[0][0] + (rect[1][0] - rect[0][0]) * 0.2;
        const y = (rect[0][1] + rect[1][1]) / 2;
        c.SDL_WarpMouseInWindow(window, x, y);
        try motion(window, x, y);
        try button(window, true, x, y);
        try std.testing.expect(input_owner.pumpEvents(editor.eventSink()));
        try journey.frame();
        try std.testing.expect(editor.material_lab.active_start != null);
        var escape = std.mem.zeroes(c.SDL_Event);
        escape.type = c.SDL_EVENT_KEY_DOWN;
        escape.key.windowID = c.SDL_GetWindowID(window);
        escape.key.key = c.SDLK_ESCAPE;
        escape.key.scancode = c.SDL_SCANCODE_ESCAPE;
        escape.key.down = true;
        if (!c.SDL_PushEvent(&escape)) return error.PushFailed;
        try std.testing.expect(input_owner.pumpEvents(editor.eventSink()));
        try journey.frame();
        try journey.frame();
        try std.testing.expectEqualDeep(initial, editor.material_lab.draft);
        try std.testing.expect(!editor.systemMenuOpen());
        try button(window, false, x, y);
        escape.type = c.SDL_EVENT_KEY_UP;
        escape.key.down = false;
        if (!c.SDL_PushEvent(&escape)) return error.PushFailed;
        try std.testing.expect(input_owner.pumpEvents(editor.eventSink()));
        try journey.frame();
    }
    try journey.click(&input_owner, .roughness, 0.45);
    try journey.click(&input_owner, .apply, 0.5);
    try journey.click(&input_owner, .commit, 0.5);
    var saved = try material_library.read(std.testing.allocator, std.testing.io, temporary.dir);
    defer saved.deinit();
    var restarted = try material_authoring.Owner.init(std.testing.allocator, saved.value, &entries);
    defer restarted.deinit();
    try std.testing.expectEqualDeep(owner.find(id).?.session, restarted.find(id).?.session);
    try std.testing.expect(restarted.find(id).?.session.roughness != initial.roughness);
    try std.testing.expectEqual(@as(u32, 0), editor.backend.pointer_buttons);
    try std.testing.expect(c.SDL_WaitForGPUIdle(device));
}

const vehicle_lab = @import("editor/tools/vehicle_lab_tool.zig");
const vehicle_authoring = @import("vehicle_authoring");
const vehicle_contract = @import("vehicle_authoring_contract");
const simulation_module = @import("sandbox_simulation");
const VehicleJourney = struct {
    editor: *editor_module.Editor,
    window: *c.SDL_Window,
    device: *c.SDL_GPUDevice,
    owner: *vehicle_authoring.Owner,
    simulation: *simulation_module.Simulation,
    target: @import("incinerator_engine").PersistentId,
    entries: []const assets.Entry,
    requests: vehicle_contract.Requests = .{ .allocator = std.testing.allocator },
    store: vehicle_authoring.Writer,

    fn frame(self: *@This()) !void {
        self.editor.backend.newFrame(720, 720, 1);
        zgui.setNextWindowPos(.{ .x = 20, .y = 20, .cond = .always });
        zgui.setNextWindowSize(.{ .w = 680, .h = 680, .cond = .always });
        vehicle_lab.draw(&self.editor.vehicle_lab, .{ .persistence_available = true, .allocator = std.testing.allocator, .inspection = try self.owner.inspect(try self.simulation.vehicle(self.target)), .result = if (self.owner.last_ui_result) |id| self.owner.result(id, .ui) else null, .requests = &self.requests, .catalog = self.entries });
        const command = c.SDL_AcquireGPUCommandBuffer(self.device) orelse return error.CommandBufferFailed;
        var target: ?*c.SDL_GPUTexture = null;
        var width: u32 = 0;
        var height: u32 = 0;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(command, self.window, &target, &width, &height)) return error.SwapchainFailed;
        if (target) |texture| self.editor.backend.render(command, texture) else zgui.render();
        if (!c.SDL_SubmitGPUCommandBuffer(command)) return error.SubmitFailed;
        for (self.requests.pending.items) |request| {
            const tx = try self.owner.prepare(.ui, request.value, try self.simulation.vehicle(self.target), self.entries, self.store);
            if (tx.command) |edit| try self.simulation.submitVehicle(.{ .reconfigure = edit });
        }
        self.requests.clear();
        try self.simulation.tick();
        while (self.simulation.pollVehicleOutcome()) |outcome| self.owner.observe(outcome);
        while (self.simulation.pollVehicleEvent()) |_| {}
    }
    fn control(self: *@This(), owner: *input.InputBuffer, item: vehicle_lab.AcceptanceItem, drag: f32, cancel: bool) !void {
        const rect = vehicle_lab.acceptance_rects[@intFromEnum(item)];
        const x = (rect[0][0] + rect[1][0]) / 2;
        const y = (rect[0][1] + rect[1][1]) / 2;
        try std.testing.expect(y > 20 and y < 700);
        c.SDL_WarpMouseInWindow(self.window, x, y);
        try motion(self.window, x, y);
        owner.beginFrame();
        try std.testing.expect(owner.pumpEvents(self.editor.eventSink()));
        try self.frame();
        try button(self.window, true, x, y);
        owner.beginFrame();
        try std.testing.expect(owner.pumpEvents(self.editor.eventSink()));
        try std.testing.expect(owner.takeFreeCameraSelectionClick() == null);
        try self.frame();
        if (drag != 0) {
            c.SDL_WarpMouseInWindow(self.window, x + drag, y);
            try motion(self.window, x + drag, y);
            owner.beginFrame();
            try std.testing.expect(owner.pumpEvents(self.editor.eventSink()));
            try self.frame();
        }
        if (cancel) {
            try std.testing.expect(self.editor.vehicle_lab.active_start != null);
            var event = std.mem.zeroes(c.SDL_Event);
            event.type = c.SDL_EVENT_KEY_DOWN;
            event.key.windowID = c.SDL_GetWindowID(self.window);
            event.key.key = c.SDLK_ESCAPE;
            event.key.scancode = c.SDL_SCANCODE_ESCAPE;
            event.key.down = true;
            if (!c.SDL_PushEvent(&event)) return error.PushFailed;
            try std.testing.expect(owner.pumpEvents(self.editor.eventSink()));
            try self.frame();
            try self.frame();
            try std.testing.expect(!self.editor.systemMenuOpen());
            event.type = c.SDL_EVENT_KEY_UP;
            event.key.down = false;
            if (!c.SDL_PushEvent(&event)) return error.PushFailed;
        }
        try button(self.window, false, x + drag, y);
        owner.beginFrame();
        try std.testing.expect(owner.pumpEvents(self.editor.eventSink()));
        try self.frame();
        try self.frame();
    }
};

test "Vehicle Lab native single Apply selects rebuild or live update with cancel revert and durable restart" {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SDLInitFailed;
    defer c.SDL_Quit();
    const window = c.SDL_CreateWindow("Incinerator Vehicle Lab Acceptance", 720, 720, 0) orelse return error.WindowFailed;
    defer c.SDL_DestroyWindow(window);
    const device = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_MSL, true, "metal") orelse return error.MetalFailed;
    defer c.SDL_DestroyGPUDevice(device);
    if (!c.SDL_ClaimWindowForGPUDevice(device, window)) return error.ClaimFailed;
    defer c.SDL_ReleaseWindowFromGPUDevice(device, window);
    var editor = editor_module.Editor.init(window, device, c.SDL_GetGPUSwapchainTextureFormat(device, window));
    defer editor.deinit();
    zgui.io.setIniFilename(null);
    editor.scene_rect = input.viewport.SceneRect.init(.{ 0, 0 }, .{ 720, 720 });
    var input_owner = input.InputBuffer.init(c.SDL_GetWindowID(window));
    try input_owner.attachGameplayMouseWindow(window);
    defer input_owner.detachGameplayMouseWindow();
    const definition = vehicle_contract.vehicle.asset.validationFixture();
    var simulation = try simulation_module.Simulation.init(std.testing.allocator, .{ .namespace = 77 });
    defer simulation.deinit();
    try simulation.submitVehicle(.{ .spawn = .{ .request_id = 1, .definition = definition, .chassis = .{ .pose = .{ .position = .{ 0, 2, 0 } } } } });
    try simulation.tick();
    const target = simulation.pollVehicleOutcome().?.spawned.id;
    while (simulation.pollVehicleEvent()) |_| {}
    for (0..240) |_| try simulation.tick();
    var owner = try vehicle_authoring.Owner.init(std.testing.allocator, &.{definition});
    defer owner.deinit();
    var entries: [4]assets.Entry = undefined;
    for (&entries, 0..) |*entry, i| entry.* = .{ .id = .{ .namespace = 1, .local = i + 1 }, .kind = if (i % 2 == 0) .mesh else .material, .owner = .game, .label = "Validation visual", .bundle_key = "vehicle/test", .revision = 1, .digest = @splat(1), .dependencies = &.{}, .source_format = .glb, .cook_status = .valid, .residency = .resident, .last_use_frame = null, .details = if (i % 2 == 0) .mesh else .{ .material = .{ .base_color = .{ 1, 1, 1, 1 }, .base_color_texture = null, .base_color_texcoord = 0 } } };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const Disk = struct {
        dir: std.Io.Dir,
        fn write(context: *anyopaque, value: vehicle_contract.Definition) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try vehicle_contract.vehicle.asset.write(std.testing.allocator, std.testing.io, self.dir, value);
        }
    };
    var disk = Disk{ .dir = temporary.dir };
    var journey = VehicleJourney{ .editor = &editor, .window = window, .device = device, .owner = &owner, .simulation = &simulation, .target = target, .entries = &entries, .store = .{ .context = &disk, .write_fn = Disk.write } };
    defer journey.requests.deinit();
    _ = c.SDL_RaiseWindow(window);
    _ = c.SDL_SyncWindow(window);
    try std.testing.expect(input_owner.pumpEvents(editor.eventSink()));
    try journey.frame();
    try journey.frame();
    const before_preset = try simulation.vehicle(target);
    const expected_preset = (try owner.inspect(before_preset)).presets[0];
    const expected_digest = try expected_preset.candidate.digest(std.testing.allocator);
    try journey.control(&input_owner, .preset, 0, false);
    try std.testing.expect(editor.vehicle_lab.dirty);
    try std.testing.expectEqualDeep(expected_digest, try editor.vehicle_lab.draft.?.value.digest(std.testing.allocator));
    try std.testing.expectEqualDeep(before_preset.definition_digest, (try simulation.vehicle(target)).definition_digest);
    try std.testing.expectEqual(before_preset.revision, (try simulation.vehicle(target)).revision);
    for ([_]input.viewport.Mode{ .character, .free_camera }) |mode| {
        input_owner.setViewportMode(mode);
        editor.setViewportMode(mode);
        const initial = (try simulation.vehicle(target)).definition.tuning.mass;
        try journey.control(&input_owner, .mass, 35, false);
        try std.testing.expect(editor.vehicle_lab.dirty);
        const candidate = editor.vehicle_lab.draft.?.value.tuning.mass;
        try std.testing.expect(candidate != initial);
        try std.testing.expectEqual(initial, (try simulation.vehicle(target)).definition.tuning.mass);
        const revision_before_apply = (try simulation.vehicle(target)).revision;
        try journey.control(&input_owner, .apply, 0, false);
        try std.testing.expectEqual(revision_before_apply + 1, (try simulation.vehicle(target)).revision);
        try std.testing.expectEqual(.rebuild, owner.result(owner.last_ui_result.?, .ui).?.action);
        try std.testing.expectEqual(candidate, (try simulation.vehicle(target)).definition.tuning.mass);
        try journey.control(&input_owner, .mass, -25, true);
        try std.testing.expectEqual(candidate, editor.vehicle_lab.draft.?.value.tuning.mass);
        try journey.control(&input_owner, .revert, 0, false);
        try std.testing.expectEqual(definition.tuning.mass, (try simulation.vehicle(target)).definition.tuning.mass);
    }
    editor.vehicle_lab.draft.?.value.tuning.powertrain.max_torque_nm = 550;
    editor.vehicle_lab.dirty = true;
    try journey.control(&input_owner, .apply, 0, false);
    try std.testing.expectEqual(.apply, owner.result(owner.last_ui_result.?, .ui).?.action);
    try std.testing.expectEqual(@as(f32, 550), (try simulation.vehicle(target)).definition.tuning.powertrain.max_torque_nm);
    try journey.control(&input_owner, .commit, 0, false);
    var restarted = try vehicle_contract.vehicle.asset.read(std.testing.allocator, std.testing.io, temporary.dir, definition.id);
    defer restarted.deinit();
    try std.testing.expectEqual(@as(f32, 550), restarted.value.tuning.powertrain.max_torque_nm);
    try std.testing.expectEqual(@as(u64, 2), restarted.value.revision);
    try std.testing.expect(c.SDL_WaitForGPUIdle(device));
}
