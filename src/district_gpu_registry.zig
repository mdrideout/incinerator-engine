//! Bounded visual-host residency for streamed district scenes.
//!
//! Logical district activation does not depend on this registry. The visual
//! host reserves a `SceneHandle`, stages decoded renderer data, and resolves a
//! fallback until one fence-polled batch publishes the complete scene.

const std = @import("std");
const engine = @import("incinerator_engine");
const mesh_module = @import("mesh.zig");
const texture_module = @import("texture.zig");
const sdl = @import("sdl.zig");

const c = sdl.c;
const Mesh = mesh_module.Mesh;
const VertexPNU = mesh_module.VertexPNU;
const OwnedTexture = texture_module.OwnedTexture;

pub const max_scenes: usize = 4;
pub const max_in_flight_batches: usize = 2;
pub const max_scenes_per_batch: usize = 4;
pub const max_meshes_per_scene: usize = 8;
pub const max_textures_per_scene: usize = 8;
pub const max_materials_per_scene: usize = 8;
pub const max_instances_per_scene: usize = 32;

pub const MeshUpload = struct {
    vertices: []const VertexPNU,
    indices: []const u32,
    material_index: u16,
};

pub const TextureUpload = struct {
    width: u32,
    height: u32,
    format: TextureFormat = .rgba8_unorm,
    rgba8: []const u8,
};

pub const TextureFormat = enum { rgba8_unorm, rgba8_srgb };

pub const MaterialUpload = struct {
    base_color: [4]f32 = .{ 1, 1, 1, 1 },
    base_color_texture: ?u16 = null,
};

/// Column-major model transform, matching zmath/renderer matrix layout.
pub const InstanceUpload = struct {
    mesh_index: u16,
    transform: [16]f32,
};

pub const SceneUpload = struct {
    meshes: []const MeshUpload,
    textures: []const TextureUpload,
    materials: []const MaterialUpload,
    instances: []const InstanceUpload,
};

pub const Config = struct {
    max_staged_cpu_bytes: u64 = 16 * 1024 * 1024,
    max_in_flight_upload_bytes: u64 = 16 * 1024 * 1024,
    max_resident_gpu_bytes: u64 = 32 * 1024 * 1024,
    max_submit_bytes_per_pump: u64 = 8 * 1024 * 1024,

    pub fn validate(self: Config) !void {
        if (self.max_staged_cpu_bytes == 0 or
            self.max_in_flight_upload_bytes == 0 or
            self.max_resident_gpu_bytes == 0 or
            self.max_submit_bytes_per_pump == 0)
        {
            return error.InvalidDistrictGpuBudget;
        }
        if (self.max_submit_bytes_per_pump > self.max_in_flight_upload_bytes) {
            return error.InvalidDistrictGpuBudget;
        }
    }
};

pub const Residency = enum {
    free,
    reserved,
    staged,
    submitted,
    retiring,
    resident,
};

pub const PumpResult = struct {
    submissions: u8 = 0,
    submitted_scenes: u8 = 0,
    published_scenes: u8 = 0,
    discarded_scenes: u8 = 0,
    submitted_bytes: u64 = 0,
};

pub const Stats = struct {
    staged_cpu_bytes: u64,
    in_flight_upload_bytes: u64,
    resident_gpu_bytes: u64,
    staged_scenes: u8,
    submitted_scenes: u8,
    resident_scenes: u8,
    active_batches: u8,
};

const StagedMesh = struct {
    vertices: []VertexPNU,
    indices: []u32,
    material_index: u16,

    fn deinit(self: *StagedMesh, allocator: std.mem.Allocator) void {
        allocator.free(self.indices);
        allocator.free(self.vertices);
        self.* = undefined;
    }
};

const StagedTexture = struct {
    width: u32,
    height: u32,
    format: TextureFormat,
    rgba8: []u8,

    fn deinit(self: *StagedTexture, allocator: std.mem.Allocator) void {
        allocator.free(self.rgba8);
        self.* = undefined;
    }
};

const StagedSceneView = struct {
    meshes: []const StagedMesh,
    textures: []const StagedTexture,
    materials: []const MaterialUpload,
    instances: []const InstanceUpload,
    upload_bytes: u64,
};

const StagedScene = struct {
    meshes: []StagedMesh,
    textures: []StagedTexture,
    materials: []MaterialUpload,
    instances: []InstanceUpload,
    cpu_bytes: u64,
    upload_bytes: u64,

    fn initCopy(allocator: std.mem.Allocator, source: SceneUpload) !StagedScene {
        const sizes = try validateAndSize(source);

        const meshes = try allocator.alloc(StagedMesh, source.meshes.len);
        errdefer allocator.free(meshes);
        var initialized_meshes: usize = 0;
        errdefer for (meshes[0..initialized_meshes]) |*item| item.deinit(allocator);
        for (source.meshes, 0..) |item, index| {
            const vertices = try allocator.dupe(VertexPNU, item.vertices);
            errdefer allocator.free(vertices);
            const indices = try allocator.dupe(u32, item.indices);
            meshes[index] = .{
                .vertices = vertices,
                .indices = indices,
                .material_index = item.material_index,
            };
            initialized_meshes += 1;
        }

        const textures = try allocator.alloc(StagedTexture, source.textures.len);
        errdefer allocator.free(textures);
        var initialized_textures: usize = 0;
        errdefer for (textures[0..initialized_textures]) |*item| item.deinit(allocator);
        for (source.textures, 0..) |item, index| {
            textures[index] = .{
                .width = item.width,
                .height = item.height,
                .format = item.format,
                .rgba8 = try allocator.dupe(u8, item.rgba8),
            };
            initialized_textures += 1;
        }

        const materials = try allocator.dupe(MaterialUpload, source.materials);
        errdefer allocator.free(materials);
        const instances = try allocator.dupe(InstanceUpload, source.instances);
        errdefer allocator.free(instances);

        return .{
            .meshes = meshes,
            .textures = textures,
            .materials = materials,
            .instances = instances,
            .cpu_bytes = sizes.cpu_bytes,
            .upload_bytes = sizes.upload_bytes,
        };
    }

    fn view(self: *const StagedScene) StagedSceneView {
        return .{
            .meshes = self.meshes,
            .textures = self.textures,
            .materials = self.materials,
            .instances = self.instances,
            .upload_bytes = self.upload_bytes,
        };
    }

    fn deinit(self: *StagedScene, allocator: std.mem.Allocator) void {
        allocator.free(self.instances);
        allocator.free(self.materials);
        for (self.textures) |*item| item.deinit(allocator);
        allocator.free(self.textures);
        for (self.meshes) |*item| item.deinit(allocator);
        allocator.free(self.meshes);
        self.* = undefined;
    }
};

const SceneSizes = struct {
    cpu_bytes: u64,
    upload_bytes: u64,
};

fn checkedAdd(total: *u64, value: u64) !void {
    total.* = std.math.add(u64, total.*, value) catch return error.SceneUploadTooLarge;
}

fn allocationBytes(comptime T: type, count: usize) !u64 {
    const bytes = std.math.mul(usize, @sizeOf(T), count) catch
        return error.SceneUploadTooLarge;
    return @intCast(bytes);
}

fn validateAndSize(source: SceneUpload) !SceneSizes {
    if (source.meshes.len == 0 or source.materials.len == 0 or source.instances.len == 0) {
        return error.EmptySceneUpload;
    }
    if (source.meshes.len > max_meshes_per_scene or
        source.textures.len > max_textures_per_scene or
        source.materials.len > max_materials_per_scene or
        source.instances.len > max_instances_per_scene)
    {
        return error.SceneResourceCapacityExceeded;
    }

    var cpu_bytes: u64 = 0;
    var upload_bytes: u64 = 0;
    try checkedAdd(&cpu_bytes, try allocationBytes(StagedMesh, source.meshes.len));
    try checkedAdd(&cpu_bytes, try allocationBytes(StagedTexture, source.textures.len));
    try checkedAdd(&cpu_bytes, try allocationBytes(MaterialUpload, source.materials.len));
    try checkedAdd(&cpu_bytes, try allocationBytes(InstanceUpload, source.instances.len));

    for (source.meshes) |item| {
        if (item.vertices.len == 0 or item.indices.len == 0 or item.indices.len % 3 != 0) {
            return error.InvalidSceneMesh;
        }
        if (item.material_index >= source.materials.len) return error.InvalidSceneMaterial;
        for (item.indices) |index| {
            if (index >= item.vertices.len) return error.InvalidSceneIndex;
        }
        const vertex_bytes = try allocationBytes(VertexPNU, item.vertices.len);
        const index_bytes = try allocationBytes(u32, item.indices.len);
        try checkedAdd(&cpu_bytes, vertex_bytes);
        try checkedAdd(&cpu_bytes, index_bytes);
        try checkedAdd(&upload_bytes, vertex_bytes);
        try checkedAdd(&upload_bytes, index_bytes);
    }
    for (source.textures) |item| {
        if (item.width == 0 or item.height == 0) return error.InvalidSceneTexture;
        const pixel_count = std.math.mul(u64, item.width, item.height) catch
            return error.SceneUploadTooLarge;
        const expected = std.math.mul(u64, pixel_count, 4) catch
            return error.SceneUploadTooLarge;
        if (item.rgba8.len != expected) return error.InvalidSceneTexture;
        try checkedAdd(&cpu_bytes, expected);
        try checkedAdd(&upload_bytes, expected);
    }
    for (source.materials) |item| {
        for (item.base_color) |value| {
            if (!std.math.isFinite(value) or value < 0 or value > 1) {
                return error.InvalidSceneMaterial;
            }
        }
        if (item.base_color_texture) |index| {
            if (index >= source.textures.len) return error.InvalidSceneTexture;
        }
    }
    for (source.instances) |item| {
        if (item.mesh_index >= source.meshes.len) return error.InvalidSceneInstance;
        for (item.transform) |value| {
            if (!std.math.isFinite(value)) return error.InvalidSceneTransform;
        }
    }
    if (upload_bytes == 0 or upload_bytes > std.math.maxInt(u32)) {
        return error.SceneUploadTooLarge;
    }
    return .{ .cpu_bytes = cpu_bytes, .upload_bytes = upload_bytes };
}

/// State machine parameterized by a narrow upload backend. Production uses
/// `SdlBackend`; tests use inert integer tokens and controllable fences.
pub fn Registry(comptime Backend: type) type {
    return struct {
        const Self = @This();
        pub const Resolution = Backend.ResourceView;

        const Slot = struct {
            generation: u32 = 1,
            state: Residency = .free,
            staged: ?StagedScene = null,
            resident: ?Backend.Candidate = null,
        };

        const BatchEntry = struct {
            slot_index: u8 = 0,
            generation: u32 = 0,
            upload_bytes: u64 = 0,
            discard: bool = false,
        };

        const Batch = struct {
            active: bool = false,
            submission: ?Backend.Submission = null,
            count: u8 = 0,
            upload_bytes: u64 = 0,
            entries: [max_scenes_per_batch]BatchEntry = @splat(.{}),
            candidates: [max_scenes_per_batch]?Backend.Candidate = @splat(null),
        };

        allocator: std.mem.Allocator,
        backend: Backend,
        fallback: Backend.ResourceView,
        config: Config,
        owner_thread: std.Thread.Id,
        slots: [max_scenes]Slot = @splat(.{}),
        batches: [max_in_flight_batches]Batch = @splat(.{}),
        staged_cpu_bytes: u64 = 0,
        staged_upload_bytes: u64 = 0,
        in_flight_upload_bytes: u64 = 0,
        resident_gpu_bytes: u64 = 0,

        pub fn init(
            allocator: std.mem.Allocator,
            backend: Backend,
            fallback: Backend.ResourceView,
            config: Config,
        ) !Self {
            try config.validate();
            return .{
                .allocator = allocator,
                .backend = backend,
                .fallback = fallback,
                .config = config,
                .owner_thread = std.Thread.getCurrentId(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.assertOwnerThread();
            for (&self.batches) |*batch| {
                if (!batch.active) continue;
                for (batch.candidates[0..batch.count]) |*candidate| {
                    if (candidate.*) |*owned| self.backend.releaseCandidate(owned);
                    candidate.* = null;
                }
                if (batch.submission) |*submission| {
                    self.backend.releaseSubmission(submission);
                }
                batch.submission = null;
                batch.active = false;
            }
            for (&self.slots) |*slot| {
                if (slot.staged) |*staged| staged.deinit(self.allocator);
                slot.staged = null;
                if (slot.resident) |*resident| self.backend.releaseCandidate(resident);
                slot.resident = null;
                slot.state = .free;
            }
            self.staged_cpu_bytes = 0;
            self.staged_upload_bytes = 0;
            self.in_flight_upload_bytes = 0;
            self.resident_gpu_bytes = 0;
        }

        pub fn reserve(self: *Self) !engine.rendering.SceneHandle {
            try self.ensureOwnerThread();
            for (&self.slots, 0..) |*slot, index| {
                if (slot.state != .free) continue;
                slot.state = .reserved;
                return .{ .index = @intCast(index), .generation = slot.generation };
            }
            return error.DistrictSceneRegistryFull;
        }

        pub fn stage(
            self: *Self,
            handle: engine.rendering.SceneHandle,
            source: SceneUpload,
        ) !void {
            try self.ensureOwnerThread();
            const slot = try self.currentSlot(handle);
            if (slot.state != .reserved) return error.SceneHandleNotReserved;
            const sizes = try validateAndSize(source);
            if (sizes.cpu_bytes > self.config.max_staged_cpu_bytes or
                sizes.upload_bytes > self.config.max_submit_bytes_per_pump or
                sizes.upload_bytes > self.config.max_in_flight_upload_bytes or
                sizes.upload_bytes > self.config.max_resident_gpu_bytes)
            {
                return error.DistrictSceneExceedsBudget;
            }
            const projected_staging = std.math.add(
                u64,
                self.staged_cpu_bytes,
                sizes.cpu_bytes,
            ) catch return error.DistrictStagingBudgetExceeded;
            if (projected_staging > self.config.max_staged_cpu_bytes) {
                return error.DistrictStagingBudgetExceeded;
            }
            const committed_gpu = std.math.add(
                u64,
                self.resident_gpu_bytes,
                self.in_flight_upload_bytes,
            ) catch return error.DistrictResidentBudgetExceeded;
            const with_staged = std.math.add(u64, committed_gpu, self.staged_upload_bytes) catch
                return error.DistrictResidentBudgetExceeded;
            const projected = std.math.add(u64, with_staged, sizes.upload_bytes) catch
                return error.DistrictResidentBudgetExceeded;
            if (projected > self.config.max_resident_gpu_bytes) {
                return error.DistrictResidentBudgetExceeded;
            }

            slot.staged = try StagedScene.initCopy(self.allocator, source);
            slot.state = .staged;
            self.staged_cpu_bytes += sizes.cpu_bytes;
            self.staged_upload_bytes += sizes.upload_bytes;
        }

        pub fn cancel(self: *Self, handle: engine.rendering.SceneHandle) !void {
            try self.ensureOwnerThread();
            const slot = try self.currentSlot(handle);
            switch (slot.state) {
                .reserved => self.recycleSlot(slot),
                .staged => {
                    const staged = &(slot.staged orelse return error.SceneRegistryInvariantBroken);
                    self.staged_cpu_bytes -= staged.cpu_bytes;
                    self.staged_upload_bytes -= staged.upload_bytes;
                    staged.deinit(self.allocator);
                    slot.staged = null;
                    self.recycleSlot(slot);
                },
                .submitted => {
                    const entry = self.findBatchEntry(handle) orelse
                        return error.SceneRegistryInvariantBroken;
                    entry.discard = true;
                    slot.state = .retiring;
                },
                .resident => {
                    var resident = slot.resident orelse return error.SceneRegistryInvariantBroken;
                    slot.resident = null;
                    const resident_bytes = self.backend.candidateBytes(&resident);
                    self.backend.releaseCandidate(&resident);
                    self.resident_gpu_bytes -= resident_bytes;
                    self.recycleSlot(slot);
                },
                .free, .retiring => return error.StaleSceneHandle,
            }
        }

        /// Invalidate a scene generation regardless of whether it is still
        /// staged, submitted, or already resident.
        pub fn release(self: *Self, handle: engine.rendering.SceneHandle) !void {
            try self.cancel(handle);
        }

        pub fn resolve(
            self: *Self,
            handle: engine.rendering.SceneHandle,
        ) !Backend.ResourceView {
            try self.ensureOwnerThread();
            const slot = try self.currentSlot(handle);
            return switch (slot.state) {
                .reserved, .staged, .submitted => self.fallback,
                .resident => self.backend.view(
                    &(slot.resident orelse return error.SceneRegistryInvariantBroken),
                ),
                .free, .retiring => error.StaleSceneHandle,
            };
        }

        pub fn residency(
            self: *Self,
            handle: engine.rendering.SceneHandle,
        ) !Residency {
            try self.ensureOwnerThread();
            return (try self.currentSlot(handle)).state;
        }

        /// Poll every active fence without waiting, then submit at most one
        /// bounded batch using one transfer buffer and one command buffer.
        pub fn pump(self: *Self) !PumpResult {
            try self.ensureOwnerThread();
            var result = PumpResult{};
            try self.pollCompleted(&result);
            try self.submitOneBatch(&result);
            return result;
        }

        pub fn stats(self: *Self) !Stats {
            try self.ensureOwnerThread();
            var result = Stats{
                .staged_cpu_bytes = self.staged_cpu_bytes,
                .in_flight_upload_bytes = self.in_flight_upload_bytes,
                .resident_gpu_bytes = self.resident_gpu_bytes,
                .staged_scenes = 0,
                .submitted_scenes = 0,
                .resident_scenes = 0,
                .active_batches = 0,
            };
            for (self.slots) |slot| switch (slot.state) {
                .staged => result.staged_scenes += 1,
                .submitted, .retiring => result.submitted_scenes += 1,
                .resident => result.resident_scenes += 1,
                else => {},
            };
            for (self.batches) |batch| if (batch.active) {
                result.active_batches += 1;
            };
            return result;
        }

        fn pollCompleted(self: *Self, result: *PumpResult) !void {
            for (&self.batches) |*batch| {
                if (!batch.active) continue;
                const submission = &(batch.submission orelse
                    return error.SceneRegistryInvariantBroken);
                if (!self.backend.query(submission)) continue;

                self.backend.releaseSubmission(submission);
                batch.submission = null;
                for (batch.entries[0..batch.count], 0..) |entry, item_index| {
                    var candidate = batch.candidates[item_index] orelse
                        return error.SceneRegistryInvariantBroken;
                    batch.candidates[item_index] = null;
                    const slot = &self.slots[entry.slot_index];
                    self.in_flight_upload_bytes -= entry.upload_bytes;
                    if (entry.discard) {
                        self.backend.releaseCandidate(&candidate);
                        if (slot.generation == entry.generation) self.recycleSlot(slot);
                        result.discarded_scenes += 1;
                        continue;
                    }
                    if (slot.generation != entry.generation or slot.state != .submitted) {
                        self.backend.releaseCandidate(&candidate);
                        return error.SceneRegistryInvariantBroken;
                    }
                    slot.resident = candidate;
                    slot.state = .resident;
                    self.resident_gpu_bytes += entry.upload_bytes;
                    result.published_scenes += 1;
                }
                batch.active = false;
                batch.count = 0;
                batch.upload_bytes = 0;
            }
        }

        fn submitOneBatch(self: *Self, result: *PumpResult) !void {
            var free_batch: ?*Batch = null;
            for (&self.batches) |*batch| {
                if (!batch.active) {
                    free_batch = batch;
                    break;
                }
            }
            const batch = free_batch orelse return;
            const in_flight_room = self.config.max_in_flight_upload_bytes -
                self.in_flight_upload_bytes;
            const byte_limit = @min(in_flight_room, self.config.max_submit_bytes_per_pump);
            if (byte_limit == 0) return;

            var selected: [max_scenes_per_batch]u8 = undefined;
            var views: [max_scenes_per_batch]StagedSceneView = undefined;
            var count: usize = 0;
            var bytes: u64 = 0;
            for (&self.slots, 0..) |*slot, index| {
                if (slot.state != .staged or count == max_scenes_per_batch) continue;
                const staged = &(slot.staged orelse return error.SceneRegistryInvariantBroken);
                if (staged.upload_bytes > byte_limit - bytes) continue;
                selected[count] = @intCast(index);
                views[count] = staged.view();
                bytes += staged.upload_bytes;
                count += 1;
            }
            if (count == 0) return;

            var candidates: [max_scenes_per_batch]?Backend.Candidate = @splat(null);
            const submission = self.backend.submitBatch(views[0..count], &candidates) catch |err| {
                for (candidates[0..count]) |*candidate| {
                    if (candidate.*) |*owned| self.backend.releaseCandidate(owned);
                    candidate.* = null;
                }
                for (selected[0..count]) |slot_index| {
                    const slot = &self.slots[slot_index];
                    const staged = &(slot.staged orelse continue);
                    self.staged_cpu_bytes -= staged.cpu_bytes;
                    self.staged_upload_bytes -= staged.upload_bytes;
                    staged.deinit(self.allocator);
                    slot.staged = null;
                    self.recycleSlot(slot);
                }
                return err;
            };

            for (candidates[0..count]) |candidate| {
                if (candidate == null) {
                    for (candidates[0..count]) |*owned_candidate| {
                        if (owned_candidate.*) |*owned| self.backend.releaseCandidate(owned);
                        owned_candidate.* = null;
                    }
                    var owned_submission = submission;
                    self.backend.releaseSubmission(&owned_submission);
                    for (selected[0..count]) |slot_index| {
                        const slot = &self.slots[slot_index];
                        const staged = &(slot.staged orelse continue);
                        self.staged_cpu_bytes -= staged.cpu_bytes;
                        self.staged_upload_bytes -= staged.upload_bytes;
                        staged.deinit(self.allocator);
                        slot.staged = null;
                        self.recycleSlot(slot);
                    }
                    return error.SceneBackendCandidateMissing;
                }
            }

            batch.* = .{
                .active = true,
                .submission = submission,
                .count = @intCast(count),
                .upload_bytes = bytes,
            };
            for (selected[0..count], 0..) |slot_index, item_index| {
                const slot = &self.slots[slot_index];
                const staged = &(slot.staged orelse return error.SceneRegistryInvariantBroken);
                const candidate = candidates[item_index].?;
                candidates[item_index] = null;
                batch.entries[item_index] = .{
                    .slot_index = slot_index,
                    .generation = slot.generation,
                    .upload_bytes = staged.upload_bytes,
                };
                batch.candidates[item_index] = candidate;
                self.staged_cpu_bytes -= staged.cpu_bytes;
                self.staged_upload_bytes -= staged.upload_bytes;
                self.in_flight_upload_bytes += staged.upload_bytes;
                staged.deinit(self.allocator);
                slot.staged = null;
                slot.state = .submitted;
            }
            result.submissions = 1;
            result.submitted_scenes = @intCast(count);
            result.submitted_bytes = bytes;
        }

        fn currentSlot(self: *Self, handle: engine.rendering.SceneHandle) !*Slot {
            if (!handle.isValid() or handle.index >= max_scenes) return error.StaleSceneHandle;
            const slot = &self.slots[handle.index];
            if (slot.generation != handle.generation or slot.state == .free) {
                return error.StaleSceneHandle;
            }
            return slot;
        }

        fn findBatchEntry(self: *Self, handle: engine.rendering.SceneHandle) ?*BatchEntry {
            for (&self.batches) |*batch| {
                if (!batch.active) continue;
                for (batch.entries[0..batch.count]) |*entry| {
                    if (entry.slot_index == handle.index and entry.generation == handle.generation) {
                        return entry;
                    }
                }
            }
            return null;
        }

        fn recycleSlot(_: *Self, slot: *Slot) void {
            slot.state = .free;
            slot.staged = null;
            slot.resident = null;
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
        }

        fn ensureOwnerThread(self: *const Self) !void {
            if (std.Thread.getCurrentId() != self.owner_thread) {
                return error.WrongDistrictGpuThread;
            }
        }

        fn assertOwnerThread(self: *const Self) void {
            std.debug.assert(std.Thread.getCurrentId() == self.owner_thread);
        }
    };
}

pub const ResidentMesh = struct {
    mesh: Mesh,
    material_index: u16,
};

pub const ResidentMaterial = struct {
    base_color: [4]f32,
    base_color_texture: ?u16,
};

pub const ResidentInstance = InstanceUpload;

pub const SdlMeshView = struct {
    mesh: *const Mesh,
    material_index: u16,
};

pub const SdlSceneView = struct {
    mesh_storage: [max_meshes_per_scene]SdlMeshView = undefined,
    texture_storage: [max_textures_per_scene]texture_module.Texture = undefined,
    material_storage: [max_materials_per_scene]ResidentMaterial = undefined,
    instance_storage: [max_instances_per_scene]ResidentInstance = undefined,
    mesh_count: u8 = 0,
    texture_count: u8 = 0,
    material_count: u8 = 0,
    instance_count: u8 = 0,

    pub fn single(
        fallback_mesh: *const Mesh,
        fallback_texture: ?texture_module.Texture,
    ) SdlSceneView {
        var result = SdlSceneView{};
        result.mesh_storage[0] = .{ .mesh = fallback_mesh, .material_index = 0 };
        result.mesh_count = 1;
        if (fallback_texture) |borrowed| {
            result.texture_storage[0] = borrowed;
            result.texture_count = 1;
        }
        result.material_storage[0] = .{
            .base_color = .{ 1, 1, 1, 1 },
            .base_color_texture = if (fallback_texture != null) 0 else null,
        };
        result.material_count = 1;
        result.instance_storage[0] = .{
            .mesh_index = 0,
            .transform = identity_transform,
        };
        result.instance_count = 1;
        return result;
    }

    pub fn meshes(self: *const SdlSceneView) []const SdlMeshView {
        return self.mesh_storage[0..self.mesh_count];
    }

    pub fn materials(self: *const SdlSceneView) []const ResidentMaterial {
        return self.material_storage[0..self.material_count];
    }

    pub fn instances(self: *const SdlSceneView) []const ResidentInstance {
        return self.instance_storage[0..self.instance_count];
    }

    pub fn materialTexture(
        self: *const SdlSceneView,
        material_index: u16,
    ) ?texture_module.Texture {
        const material = self.material_storage[material_index];
        const texture_index = material.base_color_texture orelse return null;
        return self.texture_storage[texture_index];
    }

    pub fn materialBaseColor(self: *const SdlSceneView, material_index: u16) [4]f32 {
        return self.material_storage[material_index].base_color;
    }
};

const SdlCandidate = struct {
    meshes: [max_meshes_per_scene]ResidentMesh = undefined,
    mesh_count: u8 = 0,
    textures: [max_textures_per_scene]OwnedTexture = undefined,
    texture_count: u8 = 0,
    materials: [max_materials_per_scene]ResidentMaterial = undefined,
    material_count: u8 = 0,
    instances: [max_instances_per_scene]ResidentInstance = undefined,
    instance_count: u8 = 0,
    upload_bytes: u64 = 0,
};

const SdlSubmission = struct {
    fence: *c.SDL_GPUFence,
    transfer: *c.SDL_GPUTransferBuffer,
};

const MeshLayout = struct {
    vertex_offset: u32,
    vertex_bytes: u32,
    index_offset: u32,
    index_bytes: u32,
};

const TextureLayout = struct {
    offset: u32,
    bytes: u32,
};

const SceneLayout = struct {
    meshes: [max_meshes_per_scene]MeshLayout = undefined,
    textures: [max_textures_per_scene]TextureLayout = undefined,
};

pub const SdlBackend = struct {
    pub const Candidate = SdlCandidate;
    pub const Submission = SdlSubmission;
    pub const ResourceView = SdlSceneView;

    device: *c.SDL_GPUDevice,

    pub fn submitBatch(
        self: *SdlBackend,
        items: []const StagedSceneView,
        out: *[max_scenes_per_batch]?Candidate,
    ) !Submission {
        var layouts: [max_scenes_per_batch]SceneLayout = @splat(.{});
        var total: u32 = 0;
        for (items, 0..) |item, item_index| {
            for (item.meshes, 0..) |source, mesh_index| {
                const vertex_bytes = try gpuSize(VertexPNU, source.vertices.len);
                const index_bytes = try gpuSize(u32, source.indices.len);
                const vertex_offset = try align4(total);
                total = std.math.add(u32, vertex_offset, vertex_bytes) catch
                    return error.SceneUploadTooLarge;
                const index_offset = try align4(total);
                total = std.math.add(u32, index_offset, index_bytes) catch
                    return error.SceneUploadTooLarge;
                layouts[item_index].meshes[mesh_index] = .{
                    .vertex_offset = vertex_offset,
                    .vertex_bytes = vertex_bytes,
                    .index_offset = index_offset,
                    .index_bytes = index_bytes,
                };
            }
            for (item.textures, 0..) |source, texture_index| {
                const bytes: u32 = @intCast(source.rgba8.len);
                const offset = try align4(total);
                total = std.math.add(u32, offset, bytes) catch
                    return error.SceneUploadTooLarge;
                layouts[item_index].textures[texture_index] = .{ .offset = offset, .bytes = bytes };
            }
        }
        if (total == 0) return error.EmptySceneUpload;

        errdefer for (out[0..items.len]) |*candidate| {
            if (candidate.*) |*owned| self.releaseCandidate(owned);
            candidate.* = null;
        };
        for (items, 0..) |item, item_index| {
            out[item_index] = Candidate{ .upload_bytes = item.upload_bytes };
            const candidate = &(out[item_index].?);
            for (item.meshes, 0..) |source, mesh_index| {
                const layout = layouts[item_index].meshes[mesh_index];
                const vertex_buffer = c.SDL_CreateGPUBuffer(self.device, &.{
                    .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
                    .size = layout.vertex_bytes,
                    .props = 0,
                }) orelse return error.BufferCreationFailed;
                errdefer c.SDL_ReleaseGPUBuffer(self.device, vertex_buffer);
                const index_buffer = c.SDL_CreateGPUBuffer(self.device, &.{
                    .usage = c.SDL_GPU_BUFFERUSAGE_INDEX,
                    .size = layout.index_bytes,
                    .props = 0,
                }) orelse return error.BufferCreationFailed;
                candidate.meshes[mesh_index] = .{
                    .mesh = .{
                        .vertex_buffer = vertex_buffer,
                        .vertex_count = @intCast(source.vertices.len),
                        .vertex_format = .pos_normal_uv,
                        .device = self.device,
                        .index_buffer = index_buffer,
                        .index_count = @intCast(source.indices.len),
                    },
                    .material_index = source.material_index,
                };
                candidate.mesh_count += 1;
            }
            for (item.textures, 0..) |source, texture_index| {
                const gpu_texture = c.SDL_CreateGPUTexture(self.device, &.{
                    .type = c.SDL_GPU_TEXTURETYPE_2D,
                    .format = switch (source.format) {
                        .rgba8_unorm => c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
                        .rgba8_srgb => c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM_SRGB,
                    },
                    .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
                    .width = source.width,
                    .height = source.height,
                    .layer_count_or_depth = 1,
                    .num_levels = 1,
                    .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
                    .props = 0,
                }) orelse return error.TextureCreationFailed;
                candidate.textures[texture_index] = .{
                    .device = self.device,
                    .texture = .{
                        .gpu_texture = gpu_texture,
                        .width = source.width,
                        .height = source.height,
                    },
                };
                candidate.texture_count += 1;
            }
            for (item.materials, 0..) |source, material_index| {
                candidate.materials[material_index] = .{
                    .base_color = source.base_color,
                    .base_color_texture = source.base_color_texture,
                };
                candidate.material_count += 1;
            }
            for (item.instances, 0..) |source, instance_index| {
                candidate.instances[instance_index] = source;
                candidate.instance_count += 1;
            }
        }

        const transfer = c.SDL_CreateGPUTransferBuffer(self.device, &.{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = total,
            .props = 0,
        }) orelse return error.TransferBufferCreationFailed;
        errdefer c.SDL_ReleaseGPUTransferBuffer(self.device, transfer);
        const mapped_raw = c.SDL_MapGPUTransferBuffer(self.device, transfer, false) orelse
            return error.TransferBufferMapFailed;
        const mapped: [*]u8 = @ptrCast(mapped_raw);
        for (items, 0..) |item, item_index| {
            for (item.meshes, 0..) |source, mesh_index| {
                const layout = layouts[item_index].meshes[mesh_index];
                const vertex_bytes = std.mem.sliceAsBytes(source.vertices);
                @memcpy(mapped[layout.vertex_offset..][0..vertex_bytes.len], vertex_bytes);
                const index_bytes = std.mem.sliceAsBytes(source.indices);
                @memcpy(mapped[layout.index_offset..][0..index_bytes.len], index_bytes);
            }
            for (item.textures, 0..) |source, texture_index| {
                const layout = layouts[item_index].textures[texture_index];
                @memcpy(mapped[layout.offset..][0..source.rgba8.len], source.rgba8);
            }
        }
        c.SDL_UnmapGPUTransferBuffer(self.device, transfer);

        const command = c.SDL_AcquireGPUCommandBuffer(self.device) orelse
            return error.CommandBufferFailed;
        const copy_pass = c.SDL_BeginGPUCopyPass(command) orelse {
            if (!c.SDL_CancelGPUCommandBuffer(command)) {
                return error.CommandBufferCancelFailed;
            }
            return error.CopyPassFailed;
        };
        for (items, 0..) |item, item_index| {
            const candidate = &(out[item_index] orelse unreachable);
            for (item.meshes, 0..) |_, mesh_index| {
                const layout = layouts[item_index].meshes[mesh_index];
                c.SDL_UploadToGPUBuffer(copy_pass, &.{
                    .transfer_buffer = transfer,
                    .offset = layout.vertex_offset,
                }, &.{
                    .buffer = candidate.meshes[mesh_index].mesh.vertex_buffer,
                    .offset = 0,
                    .size = layout.vertex_bytes,
                }, false);
                c.SDL_UploadToGPUBuffer(copy_pass, &.{
                    .transfer_buffer = transfer,
                    .offset = layout.index_offset,
                }, &.{
                    .buffer = candidate.meshes[mesh_index].mesh.index_buffer.?,
                    .offset = 0,
                    .size = layout.index_bytes,
                }, false);
            }
            for (item.textures, 0..) |source, texture_index| {
                const layout = layouts[item_index].textures[texture_index];
                c.SDL_UploadToGPUTexture(copy_pass, &.{
                    .transfer_buffer = transfer,
                    .offset = layout.offset,
                    .pixels_per_row = source.width,
                    .rows_per_layer = source.height,
                }, &.{
                    .texture = candidate.textures[texture_index].borrow().getHandle(),
                    .mip_level = 0,
                    .layer = 0,
                    .x = 0,
                    .y = 0,
                    .z = 0,
                    .w = source.width,
                    .h = source.height,
                    .d = 1,
                }, false);
            }
        }
        c.SDL_EndGPUCopyPass(copy_pass);
        // Submission consumes `command` even when fence acquisition fails.
        // Never attempt cancellation beyond this point.
        const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(command) orelse
            return error.CommandBufferSubmitFailed;
        return .{ .fence = fence, .transfer = transfer };
    }

    pub fn query(self: *SdlBackend, submission: *Submission) bool {
        return c.SDL_QueryGPUFence(self.device, submission.fence);
    }

    pub fn releaseSubmission(self: *SdlBackend, submission: *Submission) void {
        c.SDL_ReleaseGPUFence(self.device, submission.fence);
        c.SDL_ReleaseGPUTransferBuffer(self.device, submission.transfer);
        submission.* = undefined;
    }

    pub fn releaseCandidate(_: *SdlBackend, candidate: *Candidate) void {
        var mesh_index = candidate.mesh_count;
        while (mesh_index > 0) {
            mesh_index -= 1;
            candidate.meshes[mesh_index].mesh.deinit();
        }
        var texture_index = candidate.texture_count;
        while (texture_index > 0) {
            texture_index -= 1;
            candidate.textures[texture_index].deinit();
        }
        candidate.* = undefined;
    }

    pub fn candidateBytes(_: *SdlBackend, candidate: *const Candidate) u64 {
        return candidate.upload_bytes;
    }

    pub fn view(_: *SdlBackend, candidate: *const Candidate) ResourceView {
        var result = ResourceView{};
        for (candidate.meshes[0..candidate.mesh_count], 0..) |*resident, index| {
            result.mesh_storage[index] = .{
                .mesh = &resident.mesh,
                .material_index = resident.material_index,
            };
        }
        result.mesh_count = candidate.mesh_count;
        for (candidate.textures[0..candidate.texture_count], 0..) |*owned, index| {
            result.texture_storage[index] = owned.borrow();
        }
        result.texture_count = candidate.texture_count;
        @memcpy(
            result.material_storage[0..candidate.material_count],
            candidate.materials[0..candidate.material_count],
        );
        result.material_count = candidate.material_count;
        @memcpy(
            result.instance_storage[0..candidate.instance_count],
            candidate.instances[0..candidate.instance_count],
        );
        result.instance_count = candidate.instance_count;
        return result;
    }
};

pub const DistrictGpuRegistry = Registry(SdlBackend);

fn gpuSize(comptime T: type, count: usize) !u32 {
    if (count == 0) return error.EmptySceneUpload;
    const bytes = std.math.mul(usize, @sizeOf(T), count) catch
        return error.SceneUploadTooLarge;
    if (bytes > std.math.maxInt(u32)) return error.SceneUploadTooLarge;
    return @intCast(bytes);
}

fn align4(value: u32) !u32 {
    const with_padding = std.math.add(u32, value, 3) catch
        return error.SceneUploadTooLarge;
    return with_padding & ~@as(u32, 3);
}

const test_vertices = [_]VertexPNU{
    .{ .position = .{ 0, 0, 0 }, .normal = .{ 0, 1, 0 }, .texcoord = .{ 0, 0 } },
    .{ .position = .{ 1, 0, 0 }, .normal = .{ 0, 1, 0 }, .texcoord = .{ 1, 0 } },
    .{ .position = .{ 0, 0, 1 }, .normal = .{ 0, 1, 0 }, .texcoord = .{ 0, 1 } },
};
const test_indices = [_]u32{ 0, 1, 2 };
const test_pixels = [_]u8{ 255, 255, 255, 255 };
const test_meshes = [_]MeshUpload{.{
    .vertices = &test_vertices,
    .indices = &test_indices,
    .material_index = 0,
}};
const test_textures = [_]TextureUpload{.{ .width = 1, .height = 1, .rgba8 = &test_pixels }};
const test_materials = [_]MaterialUpload{.{ .base_color_texture = 0 }};
const identity_transform = [16]f32{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
};
const test_instances = [_]InstanceUpload{.{ .mesh_index = 0, .transform = identity_transform }};
const test_scene = SceneUpload{
    .meshes = &test_meshes,
    .textures = &test_textures,
    .materials = &test_materials,
    .instances = &test_instances,
};

const FakeRecorder = struct {
    submissions: u8 = 0,
    released_submissions: u8 = 0,
    released_candidates: u8 = 0,
    next_candidate: u16 = 1,
    signaled: [16]bool = @splat(false),
    fail_submit: bool = false,
    fail_after_candidates: bool = false,
    omit_last_candidate: bool = false,
};

const FakeBackend = struct {
    pub const Candidate = struct { id: u16, bytes: u64 };
    pub const Submission = struct { id: u8 };
    pub const ResourceView = u16;

    recorder: *FakeRecorder,

    pub fn submitBatch(
        self: *FakeBackend,
        items: []const StagedSceneView,
        out: *[max_scenes_per_batch]?Candidate,
    ) !Submission {
        if (self.recorder.fail_submit) return error.InjectedSubmitFailure;
        const submission = self.recorder.submissions;
        self.recorder.submissions += 1;
        for (items, 0..) |item, index| {
            if (self.recorder.omit_last_candidate and index + 1 == items.len) break;
            out[index] = .{ .id = self.recorder.next_candidate, .bytes = item.upload_bytes };
            self.recorder.next_candidate += 1;
        }
        if (self.recorder.fail_after_candidates) return error.InjectedPartialSubmitFailure;
        return .{ .id = submission };
    }

    pub fn query(self: *FakeBackend, submission: *Submission) bool {
        return self.recorder.signaled[submission.id];
    }

    pub fn releaseSubmission(self: *FakeBackend, _: *Submission) void {
        self.recorder.released_submissions += 1;
    }

    pub fn releaseCandidate(self: *FakeBackend, candidate: *Candidate) void {
        self.recorder.released_candidates += 1;
        candidate.* = .{ .id = 0, .bytes = 0 };
    }

    pub fn candidateBytes(_: *FakeBackend, candidate: *const Candidate) u64 {
        return candidate.bytes;
    }

    pub fn view(_: *FakeBackend, candidate: *const Candidate) ResourceView {
        return candidate.id;
    }
};

const FakeRegistry = Registry(FakeBackend);

fn testRegistry(recorder: *FakeRecorder) !FakeRegistry {
    return FakeRegistry.init(
        std.testing.allocator,
        .{ .recorder = recorder },
        0,
        .{},
    );
}

test "staged and submitted scenes resolve fallback until a signaled fence publishes" {
    var recorder = FakeRecorder{};
    var registry = try testRegistry(&recorder);
    defer registry.deinit();
    const handle = try registry.reserve();
    try registry.stage(handle, test_scene);
    try std.testing.expectEqual(@as(u16, 0), try registry.resolve(handle));
    const submitted = try registry.pump();
    try std.testing.expectEqual(@as(u8, 1), submitted.submissions);
    try std.testing.expectEqual(Residency.submitted, try registry.residency(handle));
    try std.testing.expectEqual(@as(u16, 0), try registry.resolve(handle));
    recorder.signaled[0] = true;
    const completed = try registry.pump();
    try std.testing.expectEqual(@as(u8, 1), completed.published_scenes);
    try std.testing.expectEqual(Residency.resident, try registry.residency(handle));
    try std.testing.expectEqual(@as(u16, 1), try registry.resolve(handle));
}

test "pre-submit cancellation frees staging and invalidates the generation" {
    var recorder = FakeRecorder{};
    var registry = try testRegistry(&recorder);
    defer registry.deinit();
    const old = try registry.reserve();
    try registry.stage(old, test_scene);
    try registry.cancel(old);
    try std.testing.expectError(error.StaleSceneHandle, registry.resolve(old));
    const replacement = try registry.reserve();
    try std.testing.expectEqual(old.index, replacement.index);
    try std.testing.expect(replacement.generation != old.generation);
    const stats = try registry.stats();
    try std.testing.expectEqual(@as(u64, 0), stats.staged_cpu_bytes);
    try std.testing.expectEqual(@as(u8, 0), recorder.submissions);
}

test "post-submit cancellation discards after fence and never publishes" {
    var recorder = FakeRecorder{};
    var registry = try testRegistry(&recorder);
    defer registry.deinit();
    const handle = try registry.reserve();
    try registry.stage(handle, test_scene);
    _ = try registry.pump();
    try registry.cancel(handle);
    try std.testing.expectError(error.StaleSceneHandle, registry.resolve(handle));
    recorder.signaled[0] = true;
    const completed = try registry.pump();
    try std.testing.expectEqual(@as(u8, 1), completed.discarded_scenes);
    try std.testing.expectEqual(@as(u8, 1), recorder.released_candidates);
    try std.testing.expectEqual(@as(u8, 1), recorder.released_submissions);
    try std.testing.expectError(error.StaleSceneHandle, registry.residency(handle));
}

test "resident release captures accounting before destroying the backend owner" {
    var recorder = FakeRecorder{};
    var registry = try testRegistry(&recorder);
    defer registry.deinit();
    const old = try registry.reserve();
    try registry.stage(old, test_scene);
    _ = try registry.pump();
    recorder.signaled[0] = true;
    _ = try registry.pump();
    try registry.release(old);
    const stats = try registry.stats();
    try std.testing.expectEqual(@as(u64, 0), stats.resident_gpu_bytes);
    try std.testing.expectEqual(@as(u8, 1), recorder.released_candidates);
    try std.testing.expectError(error.StaleSceneHandle, registry.resolve(old));
    const replacement = try registry.reserve();
    try std.testing.expectEqual(old.index, replacement.index);
    try std.testing.expect(replacement.generation != old.generation);
}

test "one batch can publish one scene and discard another" {
    var recorder = FakeRecorder{};
    var registry = try testRegistry(&recorder);
    defer registry.deinit();
    const first = try registry.reserve();
    const second = try registry.reserve();
    try registry.stage(first, test_scene);
    try registry.stage(second, test_scene);
    const submitted = try registry.pump();
    try std.testing.expectEqual(@as(u8, 2), submitted.submitted_scenes);
    try std.testing.expectEqual(@as(u8, 1), recorder.submissions);
    try registry.cancel(second);
    recorder.signaled[0] = true;
    const completed = try registry.pump();
    try std.testing.expectEqual(@as(u8, 1), completed.published_scenes);
    try std.testing.expectEqual(@as(u8, 1), completed.discarded_scenes);
    try std.testing.expectEqual(Residency.resident, try registry.residency(first));
    try std.testing.expectError(error.StaleSceneHandle, registry.residency(second));
}

test "budget and fixed scene capacity produce explicit backpressure" {
    const sizes = try validateAndSize(test_scene);
    var recorder = FakeRecorder{};
    var registry = try FakeRegistry.init(
        std.testing.allocator,
        .{ .recorder = &recorder },
        0,
        .{
            .max_staged_cpu_bytes = sizes.cpu_bytes,
            .max_in_flight_upload_bytes = sizes.upload_bytes,
            .max_resident_gpu_bytes = sizes.upload_bytes,
            .max_submit_bytes_per_pump = sizes.upload_bytes,
        },
    );
    defer registry.deinit();
    const first = try registry.reserve();
    try registry.stage(first, test_scene);
    const second = try registry.reserve();
    try std.testing.expectError(
        error.DistrictStagingBudgetExceeded,
        registry.stage(second, test_scene),
    );
    try registry.cancel(second);
    _ = try registry.pump();
    const replacement = try registry.reserve();
    try std.testing.expectError(
        error.DistrictResidentBudgetExceeded,
        registry.stage(replacement, test_scene),
    );
}

test "fixed registry capacity rejects a fifth live generation" {
    var recorder = FakeRecorder{};
    var registry = try testRegistry(&recorder);
    defer registry.deinit();
    var handles: [max_scenes]engine.rendering.SceneHandle = undefined;
    for (&handles) |*handle| handle.* = try registry.reserve();
    try std.testing.expectError(error.DistrictSceneRegistryFull, registry.reserve());
    for (handles) |handle| try registry.release(handle);
}

test "submit failure releases staged ownership and leaves stale handles" {
    var recorder = FakeRecorder{ .fail_submit = true };
    var registry = try testRegistry(&recorder);
    defer registry.deinit();
    const handle = try registry.reserve();
    try registry.stage(handle, test_scene);
    try std.testing.expectError(error.InjectedSubmitFailure, registry.pump());
    try std.testing.expectError(error.StaleSceneHandle, registry.resolve(handle));
    const stats = try registry.stats();
    try std.testing.expectEqual(@as(u64, 0), stats.staged_cpu_bytes);
}

test "partial backend failure releases every candidate returned before error" {
    var recorder = FakeRecorder{ .fail_after_candidates = true };
    var registry = try testRegistry(&recorder);
    defer registry.deinit();
    const handle = try registry.reserve();
    try registry.stage(handle, test_scene);
    try std.testing.expectError(error.InjectedPartialSubmitFailure, registry.pump());
    try std.testing.expectEqual(@as(u8, 1), recorder.released_candidates);
    try std.testing.expectError(error.StaleSceneHandle, registry.resolve(handle));
}

test "successful submission missing a candidate is retired without accounting drift" {
    var recorder = FakeRecorder{ .omit_last_candidate = true };
    var registry = try testRegistry(&recorder);
    defer registry.deinit();
    const handle = try registry.reserve();
    try registry.stage(handle, test_scene);
    try std.testing.expectError(error.SceneBackendCandidateMissing, registry.pump());
    try std.testing.expectEqual(@as(u8, 1), recorder.released_submissions);
    try std.testing.expectError(error.StaleSceneHandle, registry.resolve(handle));
    const stats = try registry.stats();
    try std.testing.expectEqual(@as(u64, 0), stats.staged_cpu_bytes);
    try std.testing.expectEqual(@as(u64, 0), stats.in_flight_upload_bytes);
    try std.testing.expectEqual(@as(u64, 0), stats.resident_gpu_bytes);
}

test "teardown releases resident and unsignaled submitted resources exactly once" {
    var recorder = FakeRecorder{};
    var registry = try testRegistry(&recorder);
    const resident = try registry.reserve();
    try registry.stage(resident, test_scene);
    _ = try registry.pump();
    recorder.signaled[0] = true;
    _ = try registry.pump();
    const submitted = try registry.reserve();
    try registry.stage(submitted, test_scene);
    _ = try registry.pump();
    registry.deinit();
    try std.testing.expectEqual(@as(u8, 2), recorder.released_candidates);
    try std.testing.expectEqual(@as(u8, 2), recorder.released_submissions);
}

test "scene validation preserves meshes materials textures and authored instances" {
    const sizes = try validateAndSize(test_scene);
    try std.testing.expect(sizes.cpu_bytes > sizes.upload_bytes);
    try std.testing.expectEqual(@as(u64, 112), sizes.upload_bytes);
    var invalid_instances = test_instances;
    invalid_instances[0].mesh_index = 1;
    var invalid = test_scene;
    invalid.instances = &invalid_instances;
    try std.testing.expectError(error.InvalidSceneInstance, validateAndSize(invalid));
}

test "SDL backend declarations compile without introducing fence waits" {
    std.testing.refAllDecls(SdlBackend);
    try std.testing.expect(@hasDecl(c, "SDL_QueryGPUFence"));
}

test "registry mutation is confined to its owner thread" {
    var recorder = FakeRecorder{};
    var registry = try testRegistry(&recorder);
    defer registry.deinit();
    const Context = struct {
        registry: *FakeRegistry,
        observed: ?anyerror = null,

        fn run(context: *@This()) void {
            _ = context.registry.reserve() catch |err| {
                context.observed = err;
                return;
            };
        }
    };
    var context = Context{ .registry = &registry };
    const thread = try std.Thread.spawn(.{}, Context.run, .{&context});
    thread.join();
    try std.testing.expectEqual(error.WrongDistrictGpuThread, context.observed.?);
}
