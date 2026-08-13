//! Fail-closed loader for an external, immutable spatial evaluation bundle.
//!
//! A trial bundle is deliberately not installed game content. The graphical
//! developer host receives one absolute root, validates its exact ABI and
//! package inventory, and then gives only the Core ML package and preprocessing
//! constants to the macOS adapter.

const std = @import("std");
const engine = @import("incinerator_engine");

const contract = engine.neural_rendering;
const kind = "incinerator.rf8.coreml-direct-spatial-trial-bundle";
const status = "trial_only_unpromoted";
const model_package = "model.mlpackage";
const continuous_plane_count = 11;
const digest_hex_bytes = 64;

pub const VocabularyEntry = struct {
    encoded: u32,
    index: u32,
};

const FileRecord = struct {
    path: []const u8,
    bytes: u64,
    sha256: []const u8,
};

const Model = struct {
    format: []const u8,
    package: []const u8,
    files: []const FileRecord,
    input_names: []const []const u8,
    output_name: []const u8,
    minimum_deployment_target: []const u8,
    compute_precision: []const u8,
};

const Input = struct {
    channels: []const []const u8,
    continuous_planes: []const []const u8,
    extent: [2]u32,
    global_controls: []const []const u8,
    schema_name: []const u8,
    schema_version: u16,
};

const Output = struct {
    color_space: []const u8,
    developer_display_transform: []const u8,
    extent: [2]u32,
    name: []const u8,
};

const Preprocessing = struct {
    appearance: []const u8,
    categorical_encoding: []const u8,
    control_maximum: [contract.global_control_count]f32,
    control_minimum: [contract.global_control_count]f32,
    instance_vocabulary: []const VocabularyEntry,
    linear_depth: []const u8,
    motion: []const u8,
    semantic_vocabulary: []const VocabularyEntry,
    world_normal: []const u8,
};

const SourceCandidate = struct {
    checkpoint_sha256: []const u8,
    conclusion_sha256: []const u8,
    external_pretrained_weights: bool,
    run: []const u8,
    run_sha256: []const u8,
};

const Manifest = struct {
    schema: u16,
    kind: []const u8,
    status: []const u8,
    promotion_authorized: bool,
    model: Model,
    input: Input,
    output: Output,
    preprocessing: Preprocessing,
    source_candidate: SourceCandidate,

    fn validate(self: Manifest) !void {
        if (self.schema != 3 or
            !std.mem.eql(u8, self.kind, kind) or
            !std.mem.eql(u8, self.status, status) or
            self.promotion_authorized or
            self.source_candidate.external_pretrained_weights)
        {
            return error.UnsupportedNeuralTrialBundle;
        }
        if (!std.mem.eql(u8, self.model.format, "coreml_mlprogram_float32") or
            !std.mem.eql(u8, self.model.package, model_package) or
            !std.mem.eql(u8, self.model.output_name, "scene_color") or
            !std.mem.eql(u8, self.model.minimum_deployment_target, "macOS15") or
            !std.mem.eql(u8, self.model.compute_precision, "float32") or
            self.model.files.len == 0)
        {
            return error.IncompatibleNeuralTrialModel;
        }
        const input_names = [_][]const u8{
            "continuous", "semantic", "instance", "global_controls",
        };
        try expectStrings(self.model.input_names, &input_names);
        if (self.input.schema_version != contract.schema_version or
            !std.mem.eql(u8, self.input.schema_name, contract.schema_name) or
            !std.meta.eql(self.input.extent, [2]u32{ contract.cheap_width, contract.cheap_height }))
        {
            return error.IncompatibleNeuralTrialInput;
        }
        var channel_names: [contract.channels.len][]const u8 = undefined;
        for (contract.channels, 0..) |channel, index| {
            channel_names[index] = contract.channelName(channel);
        }
        try expectStrings(self.input.channels, &channel_names);
        if (self.input.continuous_planes.len != continuous_plane_count) {
            return error.IncompatibleNeuralTrialInput;
        }
        const global_names = [_][]const u8{
            "sun_strength", "world_strength", "local_light_strength", "emissive_strength",
        };
        try expectStrings(self.input.global_controls, &global_names);
        if (!std.meta.eql(self.output.extent, [2]u32{ contract.target_width, contract.target_height }) or
            !std.mem.eql(u8, self.output.name, "scene_color") or
            !std.mem.eql(u8, self.output.color_space, "linear_hdr_rgb") or
            !std.mem.eql(u8, self.output.developer_display_transform, "reinhard_then_linear_to_srgb"))
        {
            return error.IncompatibleNeuralTrialOutput;
        }
        try validateVocabulary(self.preprocessing.semantic_vocabulary);
        try validateVocabulary(self.preprocessing.instance_vocabulary);
        for (self.preprocessing.control_minimum, self.preprocessing.control_maximum) |minimum, maximum| {
            if (!std.math.isFinite(minimum) or !std.math.isFinite(maximum) or maximum < minimum) {
                return error.InvalidNeuralTrialControlRange;
            }
        }
        for ([_][]const u8{
            self.source_candidate.checkpoint_sha256,
            self.source_candidate.conclusion_sha256,
            self.source_candidate.run_sha256,
        }) |digest| {
            if (digest.len != digest_hex_bytes) return error.InvalidNeuralTrialDigest;
            var decoded: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&decoded, digest) catch return error.InvalidNeuralTrialDigest;
        }
        if (!std.fs.path.isAbsolute(self.source_candidate.run)) {
            return error.NeuralTrialSourceRunMustBeAbsolute;
        }
        for (self.model.files, 0..) |file, index| {
            try validateRelativePath(file.path);
            try validateDigest(file.sha256);
            for (self.model.files[0..index]) |previous| {
                if (std.mem.eql(u8, previous.path, file.path)) {
                    return error.DuplicateNeuralTrialPackagePath;
                }
            }
        }
    }
};

pub const Loaded = struct {
    allocator: std.mem.Allocator,
    root: []u8,
    manifest_bytes: []u8,
    parsed: std.json.Parsed(Manifest),
    model_path: []u8,
    manifest_digest: [32]u8,

    pub fn load(
        io: std.Io,
        allocator: std.mem.Allocator,
        root: []const u8,
    ) !Loaded {
        if (!std.fs.path.isAbsolute(root)) return error.NeuralTrialBundlePathMustBeAbsolute;
        const root_copy = try allocator.dupe(u8, root);
        errdefer allocator.free(root_copy);
        const manifest_path = try std.fs.path.join(allocator, &.{ root, "bundle.json" });
        defer allocator.free(manifest_path);
        const manifest_bytes = try readExactFile(io, allocator, manifest_path, null);
        errdefer allocator.free(manifest_bytes);
        var parsed = try std.json.parseFromSlice(Manifest, allocator, manifest_bytes, .{
            .ignore_unknown_fields = true,
        });
        errdefer parsed.deinit();
        try parsed.value.validate();
        const package_path = try std.fs.path.join(allocator, &.{ root, parsed.value.model.package });
        errdefer allocator.free(package_path);
        for (parsed.value.model.files) |file| {
            const path = try std.fs.path.join(
                allocator,
                &.{ package_path, file.path },
            );
            defer allocator.free(path);
            const bytes = try readExactFile(io, allocator, path, file.bytes);
            defer allocator.free(bytes);
            var actual: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
            var expected: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&expected, file.sha256) catch
                return error.InvalidNeuralTrialDigest;
            if (!std.mem.eql(u8, &actual, &expected)) {
                return error.NeuralTrialPackageDigestMismatch;
            }
        }
        try validatePackageInventory(io, allocator, package_path, parsed.value.model.files);
        var manifest_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(manifest_bytes, &manifest_digest, .{});
        return .{
            .allocator = allocator,
            .root = root_copy,
            .manifest_bytes = manifest_bytes,
            .parsed = parsed,
            .model_path = package_path,
            .manifest_digest = manifest_digest,
        };
    }

    pub fn deinit(self: *Loaded) void {
        self.allocator.free(self.model_path);
        self.parsed.deinit();
        self.allocator.free(self.manifest_bytes);
        self.allocator.free(self.root);
        self.* = undefined;
    }

    pub fn semanticVocabulary(self: *const Loaded) []const VocabularyEntry {
        return self.parsed.value.preprocessing.semantic_vocabulary;
    }

    pub fn instanceVocabulary(self: *const Loaded) []const VocabularyEntry {
        return self.parsed.value.preprocessing.instance_vocabulary;
    }

    pub fn controlMinimum(self: *const Loaded) [contract.global_control_count]f32 {
        return self.parsed.value.preprocessing.control_minimum;
    }

    pub fn controlMaximum(self: *const Loaded) [contract.global_control_count]f32 {
        return self.parsed.value.preprocessing.control_maximum;
    }

    pub fn checkpointDigest(self: *const Loaded) []const u8 {
        return self.parsed.value.source_candidate.checkpoint_sha256;
    }
};

fn validateVocabulary(entries: []const VocabularyEntry) !void {
    if (entries.len == 0 or entries[0].encoded != 0 or entries[0].index != 0) {
        return error.InvalidNeuralTrialVocabulary;
    }
    for (entries, 0..) |entry, index| {
        if (entry.index != index) return error.InvalidNeuralTrialVocabulary;
        for (entries[0..index]) |previous| {
            if (previous.encoded == entry.encoded) return error.InvalidNeuralTrialVocabulary;
        }
    }
}

fn validateRelativePath(path: []const u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return error.InvalidNeuralTrialPath;
    var components = std.mem.tokenizeAny(u8, path, "/\\");
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return error.InvalidNeuralTrialPath;
    }
}

fn validateDigest(digest: []const u8) !void {
    if (digest.len != digest_hex_bytes) return error.InvalidNeuralTrialDigest;
    var decoded: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&decoded, digest) catch return error.InvalidNeuralTrialDigest;
}

fn validatePackageInventory(
    io: std.Io,
    allocator: std.mem.Allocator,
    package_path: []const u8,
    declared: []const FileRecord,
) !void {
    var package = try std.Io.Dir.cwd().openDir(io, package_path, .{ .iterate = true });
    defer package.close(io);
    var walker = try package.walk(allocator);
    defer walker.deinit();
    var discovered: usize = 0;
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => {},
        .file => {
            discovered += 1;
            for (declared) |file| {
                if (std.mem.eql(u8, file.path, entry.path)) break;
            } else return error.UndeclaredNeuralTrialPackageFile;
        },
        else => return error.UnsupportedNeuralTrialPackageEntry,
    };
    if (discovered != declared.len) return error.IncompleteNeuralTrialPackageInventory;
}

fn expectStrings(actual: []const []const u8, expected: []const []const u8) !void {
    if (actual.len != expected.len) return error.IncompatibleNeuralTrialInput;
    for (actual, expected) |left, right| {
        if (!std.mem.eql(u8, left, right)) return error.IncompatibleNeuralTrialInput;
    }
}

fn readExactFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    declared_bytes: ?u64,
) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (declared_bytes) |expected| {
        if (stat.size != expected) return error.NeuralTrialPackageByteCountMismatch;
    }
    const size = std.math.cast(usize, stat.size) orelse return error.NeuralTrialFileTooLarge;
    const read_limit = std.math.add(usize, size, 1) catch return error.NeuralTrialFileTooLarge;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(read_limit));
    if (bytes.len != size) {
        allocator.free(bytes);
        return error.NeuralTrialFileChangedDuringRead;
    }
    return bytes;
}

test "trial vocabulary requires a dense background-first mapping" {
    try validateVocabulary(&.{
        .{ .encoded = 0, .index = 0 },
        .{ .encoded = 42, .index = 1 },
    });
    try std.testing.expectError(error.InvalidNeuralTrialVocabulary, validateVocabulary(&.{
        .{ .encoded = 42, .index = 0 },
    }));
    try std.testing.expectError(error.InvalidNeuralTrialVocabulary, validateVocabulary(&.{
        .{ .encoded = 0, .index = 0 },
        .{ .encoded = 42, .index = 2 },
    }));
}

test "trial paths cannot escape their model package" {
    try validateRelativePath("Data/com.apple.CoreML/model.mlmodel");
    try std.testing.expectError(error.InvalidNeuralTrialPath, validateRelativePath("../model.mlmodel"));
    try std.testing.expectError(error.InvalidNeuralTrialPath, validateRelativePath("/tmp/model.mlmodel"));
}

test "trial package inventory rejects undeclared files" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "Data", .default_dir);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "Data/model.mlmodel",
        .data = "declared",
    });
    var absolute: [std.fs.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(std.testing.io, &absolute);
    const root = absolute[0..length];
    const declared = [_]FileRecord{.{
        .path = "Data/model.mlmodel",
        .bytes = "declared".len,
        .sha256 = "0" ** digest_hex_bytes,
    }};
    try validatePackageInventory(std.testing.io, std.testing.allocator, root, &declared);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "Data/undeclared.bin",
        .data = "drift",
    });
    try std.testing.expectError(
        error.UndeclaredNeuralTrialPackageFile,
        validatePackageInventory(std.testing.io, std.testing.allocator, root, &declared),
    );
}
