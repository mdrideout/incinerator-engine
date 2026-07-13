//! Explicit-root cooked content loading and bounded asynchronous scene worker.

const std = @import("std");
pub const bundle = @import("district_bundle.zig");

pub const max_bundle_key_bytes: usize = 96;
pub const max_content_root_bytes: usize = 1024;
pub const bundle_extension = ".icdb";

pub const BundleKey = struct {
    storage: [max_bundle_key_bytes]u8 = undefined,
    len: u8,

    pub fn parse(raw: []const u8) !BundleKey {
        if (raw.len == 0 or raw.len > max_bundle_key_bytes) return error.InvalidBundleKey;
        if (raw[0] == '/' or raw[raw.len - 1] == '/') return error.InvalidBundleKey;
        var segment_start: usize = 0;
        for (raw, 0..) |byte, index| {
            const allowed = (byte >= 'a' and byte <= 'z') or
                (byte >= '0' and byte <= '9') or byte == '_' or byte == '-' or byte == '/';
            if (!allowed) return error.InvalidBundleKey;
            if (byte == '/') {
                const segment = raw[segment_start..index];
                if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) {
                    return error.InvalidBundleKey;
                }
                segment_start = index + 1;
            }
        }
        const final_segment = raw[segment_start..];
        if (final_segment.len == 0 or std.mem.eql(u8, final_segment, ".") or
            std.mem.eql(u8, final_segment, "..")) return error.InvalidBundleKey;

        var result = BundleKey{ .len = @intCast(raw.len) };
        @memcpy(result.storage[0..raw.len], raw);
        return result;
    }

    pub fn bytes(self: *const BundleKey) []const u8 {
        return self.storage[0..self.len];
    }

    pub fn filePath(self: *const BundleKey, buffer: *[max_bundle_key_bytes + bundle_extension.len]u8) []const u8 {
        const key = self.bytes();
        @memcpy(buffer[0..key.len], key);
        @memcpy(buffer[key.len..][0..bundle_extension.len], bundle_extension);
        return buffer[0 .. key.len + bundle_extension.len];
    }
};

pub const ContentRootPath = struct {
    storage: [max_content_root_bytes]u8 = undefined,
    len: u16,

    pub fn parse(path: []const u8) !ContentRootPath {
        if (!std.fs.path.isAbsolute(path) or path.len == 0 or path.len > max_content_root_bytes) {
            return error.InvalidContentRoot;
        }
        var result = ContentRootPath{ .len = @intCast(path.len) };
        @memcpy(result.storage[0..path.len], path);
        return result;
    }

    pub fn bytes(self: *const ContentRootPath) []const u8 {
        return self.storage[0..self.len];
    }
};

pub const ReadTooLarge = struct {
    actual: u64,
    maximum: u64,
};

pub const LoadFailure = union(enum) {
    not_found,
    access_denied,
    io_failure,
    out_of_memory,
    bundle_key_mismatch,
    too_large: ReadTooLarge,
    validation: bundle.ValidationFailure,
};

pub const LoadResult = union(enum) {
    scene: bundle.OwnedBundle,
    failed: LoadFailure,
};

/// Directory-capability root. `open` requires an absolute configured path and
/// no method consults or falls back to the process working directory.
pub const ContentRoot = struct {
    dir: std.Io.Dir,
    owns_dir: bool,

    pub fn open(io: std.Io, path: ContentRootPath) !ContentRoot {
        return .{
            .dir = try std.Io.Dir.openDirAbsolute(io, path.bytes(), .{}),
            .owns_dir = true,
        };
    }

    /// Test/tool capability constructor. The caller retains directory lifetime.
    pub fn borrowed(dir: std.Io.Dir) ContentRoot {
        return .{ .dir = dir, .owns_dir = false };
    }

    pub fn deinit(self: *ContentRoot, io: std.Io) void {
        if (self.owns_dir) self.dir.close(io);
        self.* = undefined;
    }

    pub fn load(
        self: *const ContentRoot,
        io: std.Io,
        allocator: std.mem.Allocator,
        key: BundleKey,
        limits: bundle.Limits,
    ) !LoadResult {
        var path_buffer: [max_bundle_key_bytes + bundle_extension.len]u8 = undefined;
        const path = key.filePath(&path_buffer);
        var file = self.dir.openFile(io, path, .{
            .allow_directory = false,
            .follow_symlinks = true,
            .resolve_beneath = true,
        }) catch |err| return .{ .failed = mapOpenFailure(err) };
        defer file.close(io);

        const file_len = file.length(io) catch return .{ .failed = .io_failure };
        if (file_len > limits.max_file_bytes) return .{ .failed = .{ .too_large = .{
            .actual = file_len,
            .maximum = limits.max_file_bytes,
        } } };
        const byte_len = std.math.cast(usize, file_len) orelse return .{ .failed = .{ .too_large = .{
            .actual = file_len,
            .maximum = limits.max_file_bytes,
        } } };
        var read_buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &read_buffer);
        const bytes = reader.interface.readAlloc(allocator, byte_len) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .failed = .io_failure },
        };
        defer allocator.free(bytes);
        return switch (try bundle.decode(allocator, bytes, limits)) {
            .bundle => |scene_value| blk: {
                var scene = scene_value;
                const decoded_key = scene.view().name(scene.bundle_name) orelse {
                    scene.deinit();
                    break :blk .{ .failed = .bundle_key_mismatch };
                };
                if (!std.mem.eql(u8, decoded_key, key.bytes())) {
                    scene.deinit();
                    break :blk .{ .failed = .bundle_key_mismatch };
                }
                break :blk .{ .scene = scene };
            },
            .failed => |failure| .{ .failed = .{ .validation = failure } },
        };
    }
};

fn mapOpenFailure(err: anyerror) LoadFailure {
    return switch (err) {
        error.FileNotFound, error.NotDir => .not_found,
        error.AccessDenied, error.PermissionDenied => .access_denied,
        else => .io_failure,
    };
}

pub const SceneRequest = struct {
    generation: u64,
    content_root: ContentRootPath,
    key: BundleKey,
    limits: bundle.Limits = .{},

    pub fn validate(self: *const SceneRequest) !void {
        if (self.generation == 0) return error.InvalidSceneGeneration;
    }
};

pub const RequestDisposition = enum { accepted, busy, stale, invalid };
pub const CancelDisposition = enum { requested, idle, stale, invalid };
pub const PendingStage = enum { queued, reading };
pub const FailedCompletion = struct { generation: u64, failure: LoadFailure };
pub const ReadyCompletion = struct { generation: u64, scene: bundle.OwnedBundle };
pub const Completion = union(enum) {
    ready: ReadyCompletion,
    cancelled: u64,
    failed: FailedCompletion,

    pub fn generation(self: *const Completion) u64 {
        return switch (self.*) {
            .ready => |ready| ready.generation,
            .cancelled => |value| value,
            .failed => |failed| failed.generation,
        };
    }

    pub fn deinit(self: *Completion) void {
        switch (self.*) {
            .ready => |*ready| ready.scene.deinit(),
            else => {},
        }
        self.* = undefined;
    }
};

pub const PollResult = union(enum) {
    idle,
    stale,
    pending: PendingStage,
    completion: Completion,
};

/// One-job, never-detached worker. The background thread receives only an
/// explicit absolute root, validated logical key, limits, allocator, and I/O
/// capability. It imports no simulation or graphics module.
pub const SceneWorker = struct {
    mutex: std.atomic.Mutex = .unlocked,
    owner_thread: std.Thread.Id,
    io: std.Io,
    allocator: std.mem.Allocator,
    thread: ?std.Thread = null,
    active: ?SceneRequest = null,
    completion: ?Completion = null,
    last_generation: u64 = 0,
    started: bool = false,
    cancel_requested: bool = false,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) SceneWorker {
        return .{
            .owner_thread = std.Thread.getCurrentId(),
            .io = io,
            .allocator = allocator,
        };
    }

    /// The worker must remain at a stable address until completion or deinit.
    pub fn request(self: *SceneWorker, request_value: SceneRequest) !RequestDisposition {
        try self.requireOwnerThread();
        request_value.validate() catch return .invalid;
        self.lock();
        defer self.unlock();
        if (self.active != null) return .busy;
        if (request_value.generation <= self.last_generation) return .stale;
        self.active = request_value;
        self.completion = null;
        self.started = false;
        self.cancel_requested = false;
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
            self.active = null;
            return err;
        };
        self.last_generation = request_value.generation;
        return .accepted;
    }

    pub fn cancel(self: *SceneWorker, generation: u64) CancelDisposition {
        self.assertOwnerThread();
        if (generation == 0) return .invalid;
        self.lock();
        defer self.unlock();
        const active = self.active orelse return .idle;
        if (active.generation != generation) return .stale;
        self.cancel_requested = true;
        if (self.completion) |*completion| {
            completion.deinit();
            self.completion = .{ .cancelled = generation };
        }
        return .requested;
    }

    pub fn poll(self: *SceneWorker, generation: u64) PollResult {
        self.assertOwnerThread();
        self.lock();
        defer self.unlock();
        const active = self.active orelse return .idle;
        if (active.generation != generation) return .stale;
        if (self.completion) |completion| {
            if (self.thread) |thread| thread.join();
            self.thread = null;
            self.active = null;
            self.completion = null;
            return .{ .completion = completion };
        }
        return .{ .pending = if (self.started) .reading else .queued };
    }

    pub fn deinit(self: *SceneWorker) void {
        self.assertOwnerThread();
        self.lock();
        self.cancel_requested = true;
        self.unlock();
        if (self.thread) |thread| thread.join();
        self.lock();
        if (self.completion) |*completion| completion.deinit();
        self.completion = null;
        self.active = null;
        self.thread = null;
        self.unlock();
        self.* = undefined;
    }

    pub fn hasStarted(self: *SceneWorker) bool {
        self.assertOwnerThread();
        self.lock();
        defer self.unlock();
        return self.started;
    }

    fn run(self: *SceneWorker) void {
        self.lock();
        self.started = true;
        const request_value = self.active.?;
        const cancelled_before_read = self.cancel_requested;
        self.unlock();
        if (cancelled_before_read) return self.publish(.{ .cancelled = request_value.generation });

        var root = ContentRoot.open(self.io, request_value.content_root) catch |err| {
            return self.publish(.{ .failed = .{
                .generation = request_value.generation,
                .failure = mapOpenFailure(err),
            } });
        };
        defer root.deinit(self.io);
        var result = root.load(
            self.io,
            self.allocator,
            request_value.key,
            request_value.limits,
        ) catch |err| return self.publish(.{ .failed = .{
            .generation = request_value.generation,
            .failure = if (err == error.OutOfMemory) .out_of_memory else .io_failure,
        } });
        switch (result) {
            .scene => |*scene| {
                self.lock();
                if (self.cancel_requested) {
                    self.unlock();
                    scene.deinit();
                    self.publish(.{ .cancelled = request_value.generation });
                } else {
                    const moved = scene.*;
                    self.completion = .{ .ready = .{
                        .generation = request_value.generation,
                        .scene = moved,
                    } };
                    self.unlock();
                }
            },
            .failed => |failure| self.publish(.{ .failed = .{
                .generation = request_value.generation,
                .failure = failure,
            } }),
        }
    }

    fn publish(self: *SceneWorker, completion: Completion) void {
        self.lock();
        defer self.unlock();
        if (self.cancel_requested) {
            var owned = completion;
            owned.deinit();
            self.completion = .{ .cancelled = self.active.?.generation };
        } else {
            self.completion = completion;
        }
    }

    fn requireOwnerThread(self: *const SceneWorker) !void {
        if (std.Thread.getCurrentId() != self.owner_thread) return error.WrongSceneWorkerThread;
    }

    fn assertOwnerThread(self: *const SceneWorker) void {
        self.requireOwnerThread() catch @panic("scene worker used from non-owner thread");
    }

    fn lock(self: *SceneWorker) void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *SceneWorker) void {
        self.mutex.unlock();
    }
};

test "bundle keys and roots reject ambiguous or cwd-dependent lookup" {
    const valid = try BundleKey.parse("district/s3_fixture");
    try std.testing.expectEqualStrings("district/s3_fixture", valid.bytes());
    try std.testing.expectError(error.InvalidBundleKey, BundleKey.parse("../escape"));
    try std.testing.expectError(error.InvalidBundleKey, BundleKey.parse("district//fixture"));
    try std.testing.expectError(error.InvalidBundleKey, BundleKey.parse("District/fixture"));
    try std.testing.expectError(error.InvalidContentRoot, ContentRootPath.parse("relative/content"));
}

test "explicit root returns structured missing and validation failures" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = ContentRoot.borrowed(temporary.dir);
    const key = try BundleKey.parse("district/missing");
    try std.testing.expect((try root.load(std.testing.io, std.testing.allocator, key, .{})).failed == .not_found);

    try temporary.dir.createDir(std.testing.io, "district", .default_dir);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "district/bad.icdb", .data = "not a bundle" });
    const invalid = try root.load(std.testing.io, std.testing.allocator, try BundleKey.parse("district/bad"), .{});
    try std.testing.expect(invalid.failed == .validation);
    try std.testing.expect(invalid.failed.validation == .invalid_header);

    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "district/large.icdb", .data = &([_]u8{0} ** 32) });
    var narrow_limits = bundle.Limits{};
    narrow_limits.max_file_bytes = 16;
    const too_large = try root.load(
        std.testing.io,
        std.testing.allocator,
        try BundleKey.parse("district/large"),
        narrow_limits,
    );
    try std.testing.expect(too_large.failed == .too_large);
    try std.testing.expectEqual(@as(u64, 32), too_large.failed.too_large.actual);

    const valid_bytes = (try bundle.encode(std.testing.allocator, workerTestBundle(), .{})).bytes;
    defer std.testing.allocator.free(valid_bytes);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "district/wrong.icdb",
        .data = valid_bytes,
    });
    const wrong_identity = try root.load(
        std.testing.io,
        std.testing.allocator,
        try BundleKey.parse("district/wrong"),
        .{},
    );
    try std.testing.expect(wrong_identity.failed == .bundle_key_mismatch);
}

test "scene worker reports missing content, joins, and rejects stale generation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_len = try temporary.dir.realPath(std.testing.io, &absolute_buffer);
    const root_path = try ContentRootPath.parse(absolute_buffer[0..absolute_len]);

    var worker = SceneWorker.init(std.testing.io, std.testing.allocator);
    defer worker.deinit();
    const request_value = SceneRequest{
        .generation = 1,
        .content_root = root_path,
        .key = try BundleKey.parse("district/missing"),
    };
    try std.testing.expectEqual(RequestDisposition.accepted, try worker.request(request_value));
    var completion: ?Completion = null;
    for (0..10_000) |_| {
        switch (worker.poll(1)) {
            .pending => std.Thread.yield() catch {},
            .completion => |value| {
                completion = value;
                break;
            },
            else => return error.UnexpectedWorkerState,
        }
    }
    try std.testing.expect(completion != null);
    try std.testing.expect(completion.?.failed.failure == .not_found);
    try std.testing.expectEqual(RequestDisposition.stale, try worker.request(request_value));
}

const worker_test_strings = "district/testNodeMeshMaterial";
const worker_test_nodes = [_]bundle.Node{.{
    .name = .{ .offset = 13, .len = 4 },
    .mesh = 0,
    .local_transform = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
}};
const worker_test_meshes = [_]bundle.Mesh{.{
    .name = .{ .offset = 17, .len = 4 },
    .first_primitive = 0,
    .primitive_count = 1,
}};
const worker_test_primitives = [_]bundle.Primitive{.{
    .first_vertex = 0,
    .vertex_count = 3,
    .first_index = 0,
    .index_count = 3,
    .material = 0,
}};
const worker_test_materials = [_]bundle.Material{.{
    .name = .{ .offset = 21, .len = 8 },
    .base_color = .{ 1, 1, 1, 1 },
}};
const worker_test_vertices = [_]bundle.VertexPNU{
    .{ .position = .{ 0, 0, 0 }, .normal = .{ 0, 1, 0 }, .texcoord = .{ 0, 0 } },
    .{ .position = .{ 1, 0, 0 }, .normal = .{ 0, 1, 0 }, .texcoord = .{ 1, 0 } },
    .{ .position = .{ 0, 0, 1 }, .normal = .{ 0, 1, 0 }, .texcoord = .{ 0, 1 } },
};
const worker_test_indices = [_]u32{ 0, 1, 2 };
const worker_test_boxes = [_]bundle.StaticBox{.{
    .position = .{ 0, -0.5, 0 },
    .half_extents = .{ 1, 0.5, 1 },
}};

fn workerTestBundle() bundle.BundleView {
    return .{
        .bundle_name = .{ .offset = 0, .len = 13 },
        .source_digest = [_]u8{0x33} ** 32,
        .strings = worker_test_strings,
        .nodes = &worker_test_nodes,
        .meshes = &worker_test_meshes,
        .primitives = &worker_test_primitives,
        .materials = &worker_test_materials,
        .textures = &.{},
        .vertices = &worker_test_vertices,
        .indices = &worker_test_indices,
        .pixels = &.{},
        .static_boxes = &worker_test_boxes,
    };
}

test "scene worker cancellation releases a ready scene and the next generation transfers ownership" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "district", .default_dir);
    const encoded = (try bundle.encode(std.testing.allocator, workerTestBundle(), .{})).bytes;
    defer std.testing.allocator.free(encoded);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "district/test.icdb",
        .data = encoded,
    });

    var absolute_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_len = try temporary.dir.realPath(std.testing.io, &absolute_buffer);
    const root_path = try ContentRootPath.parse(absolute_buffer[0..absolute_len]);
    const key = try BundleKey.parse("district/test");
    var worker = SceneWorker.init(std.testing.io, std.testing.allocator);
    defer worker.deinit();

    try std.testing.expectEqual(RequestDisposition.accepted, try worker.request(.{
        .generation = 1,
        .content_root = root_path,
        .key = key,
    }));
    try std.testing.expectEqual(CancelDisposition.requested, worker.cancel(1));
    var cancelled = false;
    for (0..10_000) |_| {
        switch (worker.poll(1)) {
            .pending => std.Thread.yield() catch {},
            .completion => |completion| {
                try std.testing.expect(completion == .cancelled);
                cancelled = true;
                break;
            },
            else => return error.UnexpectedWorkerState,
        }
    }
    try std.testing.expect(cancelled);

    try std.testing.expectEqual(RequestDisposition.accepted, try worker.request(.{
        .generation = 2,
        .content_root = root_path,
        .key = key,
    }));
    var ready = false;
    for (0..10_000) |_| {
        switch (worker.poll(2)) {
            .pending => std.Thread.yield() catch {},
            .completion => |completion_value| {
                var completion = completion_value;
                defer completion.deinit();
                try std.testing.expect(completion == .ready);
                try std.testing.expectEqual(@as(usize, 1), completion.ready.scene.nodes.len);
                ready = true;
                break;
            },
            else => return error.UnexpectedWorkerState,
        }
    }
    try std.testing.expect(ready);
}
