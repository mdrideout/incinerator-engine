//! Canonical, renderer-neutral cooked-content catalog.
//!
//! The wire format is explicit little-endian data. Declaration order, native
//! aggregate layout, filesystem paths, and resident handles never participate
//! in the encoded bytes or identity fingerprint.

const std = @import("std");

pub const Digest = [32]u8;

pub const magic = [8]u8{ 'I', 'N', 'C', 'C', 'A', 'T', 'L', 'G' };
pub const format_version: u16 = 1;
pub const schema_cohort: u16 = 1;
pub const identity_fingerprint_version: u16 = 1;

pub const header_size: usize = 160;
pub const entry_stride: usize = 112;
pub const dependency_stride: usize = 4;

pub const max_file_bytes: usize = 64 * 1024;
pub const max_strings_bytes: usize = 16 * 1024;
pub const max_entries: usize = 32;
pub const max_dependencies: usize = 256;
pub const max_dependencies_per_entry: usize = 16;
pub const max_catalog_name_bytes: usize = 96;
pub const max_semantic_id_bytes: usize = 96;
pub const max_bundle_key_bytes: usize = 96;

const total_size_offset: usize = 16;
const strings_offset_offset: usize = 24;
const strings_size_offset: usize = 32;
const entries_offset_offset: usize = 40;
const entry_count_offset: usize = 48;
const entry_stride_offset: usize = 52;
const dependencies_offset_offset: usize = 56;
const dependency_count_offset: usize = 64;
const dependency_stride_offset: usize = 68;
const source_digest_offset: usize = 72;
const integrity_digest_offset: usize = 104;
const catalog_name_offset: usize = 136;
const catalog_name_len_offset: usize = 140;
const reserved_offset: usize = 144;

pub const ChunkCoord = struct {
    x: i32,
    z: i32,

    pub fn eql(a: ChunkCoord, b: ChunkCoord) bool {
        return a.x == b.x and a.z == b.z;
    }
};

pub const BundleIdentity = struct {
    format_version: u16,
    schema_cohort: u16,
    source_digest: Digest,
    integrity_digest: Digest,

    pub fn validate(self: BundleIdentity) !void {
        if (self.format_version == 0) return error.InvalidBundleFormatVersion;
        if (self.schema_cohort == 0) return error.InvalidBundleSchemaCohort;
        if (!hasNonzeroByte(&self.source_digest)) return error.MissingBundleSourceDigest;
        if (!hasNonzeroByte(&self.integrity_digest)) return error.MissingBundleIntegrityDigest;
    }
};

pub const EntryDeclaration = struct {
    coord: ChunkCoord,
    semantic_id: []const u8,
    bundle_key: []const u8,
    recipe_version: u32,
    logical_checksum: u64,
    bundle: BundleIdentity,
    dependencies: []const []const u8 = &.{},
};

pub const Declaration = struct {
    name: []const u8,
    source_digest: Digest,
    entries: []const EntryDeclaration,
};

pub const Limits = struct {
    max_file_bytes: usize = max_file_bytes,
    max_strings_bytes: usize = max_strings_bytes,
    max_entries: usize = max_entries,
    max_dependencies: usize = max_dependencies,
    max_dependencies_per_entry: usize = max_dependencies_per_entry,

    pub fn validate(self: Limits) !void {
        if (self.max_file_bytes < header_size or self.max_file_bytes > max_file_bytes or
            self.max_strings_bytes == 0 or self.max_strings_bytes > max_strings_bytes or
            self.max_entries == 0 or self.max_entries > max_entries or
            self.max_dependencies > max_dependencies or
            self.max_dependencies_per_entry > max_dependencies_per_entry)
        {
            return error.InvalidCatalogLimits;
        }
    }
};

pub const CapacityKind = enum {
    file_bytes,
    strings,
    entries,
    dependencies,
    dependencies_per_entry,
};

pub const CapacityFailure = struct {
    kind: CapacityKind,
    actual: u64,
    maximum: u64,
};

pub const EntryIssue = struct { entry_index: u32 };
pub const DependencyIssue = struct { entry_index: u32, dependency_index: u32 };
pub const DuplicateIssue = struct { first_index: u32, second_index: u32 };

pub const ValidationFailure = union(enum) {
    truncated,
    trailing_data,
    bad_magic,
    unsupported_format_version: u16,
    incompatible_schema: u16,
    invalid_header,
    size_mismatch,
    capacity_exceeded: CapacityFailure,
    integrity_mismatch,
    empty_catalog,
    invalid_catalog_name,
    missing_catalog_source_digest,
    invalid_semantic_id: EntryIssue,
    invalid_bundle_key: EntryIssue,
    invalid_recipe_version: EntryIssue,
    invalid_logical_checksum: EntryIssue,
    invalid_bundle_identity: EntryIssue,
    duplicate_coordinate: DuplicateIssue,
    duplicate_semantic_id: DuplicateIssue,
    duplicate_bundle_key: DuplicateIssue,
    duplicate_dependency: DependencyIssue,
    missing_dependency: DependencyIssue,
    self_dependency: DependencyIssue,
    dependency_cycle: EntryIssue,
    noncanonical_wire_order,
};

pub const Identity = struct {
    name: []const u8,
    format_version: u16,
    schema_cohort: u16,
    source_digest: Digest,
    integrity_digest: Digest,

    pub fn validate(self: Identity) !void {
        if (!validPathLike(self.name, max_catalog_name_bytes, true)) {
            return error.InvalidCatalogIdentityName;
        }
        if (self.format_version == 0) return error.InvalidCatalogFormatVersion;
        if (self.schema_cohort == 0) return error.InvalidCatalogSchemaCohort;
        if (!hasNonzeroByte(&self.source_digest)) return error.MissingCatalogSourceDigest;
        if (!hasNonzeroByte(&self.integrity_digest)) return error.MissingCatalogIntegrityDigest;
    }

    pub fn canonicalFingerprint(self: Identity) !Digest {
        try self.validate();
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("incinerator.catalog.identity");
        hashU16(&hash, identity_fingerprint_version);
        hashU16(&hash, self.format_version);
        hashU16(&hash, self.schema_cohort);
        hashU32(&hash, @intCast(self.name.len));
        hash.update(self.name);
        hash.update(&self.source_digest);
        hash.update(&self.integrity_digest);
        var result: Digest = undefined;
        hash.final(&result);
        return result;
    }
};

pub const EntryView = struct {
    coord: ChunkCoord,
    semantic_id: []const u8,
    bundle_key: []const u8,
    recipe_version: u32,
    logical_checksum: u64,
    bundle: BundleIdentity,
    dependency_start: u32,
    dependency_count: u32,
};

pub const View = struct {
    name: []const u8,
    source_digest: Digest,
    integrity_digest: Digest,
    entries: []const EntryView,
    dependency_indices: []const u32,

    pub fn identity(self: View) Identity {
        return .{
            .name = self.name,
            .format_version = format_version,
            .schema_cohort = schema_cohort,
            .source_digest = self.source_digest,
            .integrity_digest = self.integrity_digest,
        };
    }

    pub fn fingerprint(self: View) !Digest {
        return self.identity().canonicalFingerprint();
    }

    pub fn lookupSemanticId(self: View, semantic_id: []const u8) ?u32 {
        var low: usize = 0;
        var high: usize = self.entries.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            switch (std.mem.order(u8, self.entries[middle].semantic_id, semantic_id)) {
                .lt => low = middle + 1,
                .gt => high = middle,
                .eq => return @intCast(middle),
            }
        }
        return null;
    }

    pub fn lookupCoordinate(self: View, coord: ChunkCoord) ?u32 {
        for (self.entries, 0..) |entry, index| {
            if (ChunkCoord.eql(entry.coord, coord)) return @intCast(index);
        }
        return null;
    }

    pub fn lookupBundleKey(self: View, key: []const u8) ?u32 {
        for (self.entries, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.bundle_key, key)) return @intCast(index);
        }
        return null;
    }

    pub fn dependencies(self: View, entry_index: u32) ![]const u32 {
        if (entry_index >= self.entries.len) return error.CatalogEntryNotFound;
        const entry = self.entries[entry_index];
        const start: usize = entry.dependency_start;
        const end = std.math.add(usize, start, entry.dependency_count) catch
            return error.InvalidCatalogView;
        if (end > self.dependency_indices.len) return error.InvalidCatalogView;
        return self.dependency_indices[start..end];
    }

    /// Return the selected entry and every transitively required dependency in
    /// canonical semantic-ID order. `storage` must hold at least `entries.len`.
    pub fn dependencyClosure(
        self: View,
        entry_index: u32,
        storage: []u32,
    ) ![]const u32 {
        if (entry_index >= self.entries.len) return error.CatalogEntryNotFound;
        if (storage.len < self.entries.len) return error.DestinationTooSmall;
        var visited = [_]bool{false} ** max_entries;
        var stack: [max_entries]u32 = undefined;
        var stack_len: usize = 1;
        stack[0] = entry_index;
        visited[entry_index] = true;
        while (stack_len != 0) {
            stack_len -= 1;
            const current = stack[stack_len];
            for (try self.dependencies(current)) |dependency| {
                if (visited[dependency]) continue;
                visited[dependency] = true;
                stack[stack_len] = dependency;
                stack_len += 1;
            }
        }
        return collectVisited(self.entries.len, &visited, storage);
    }

    /// Return the changed entry and every transitive reverse-dependent in
    /// canonical semantic-ID order. This is the cook invalidation closure.
    pub fn dependentClosure(
        self: View,
        entry_index: u32,
        storage: []u32,
    ) ![]const u32 {
        if (entry_index >= self.entries.len) return error.CatalogEntryNotFound;
        if (storage.len < self.entries.len) return error.DestinationTooSmall;
        var visited = [_]bool{false} ** max_entries;
        var stack: [max_entries]u32 = undefined;
        var stack_len: usize = 1;
        stack[0] = entry_index;
        visited[entry_index] = true;
        while (stack_len != 0) {
            stack_len -= 1;
            const current = stack[stack_len];
            for (self.entries, 0..) |_, candidate_index| {
                if (visited[candidate_index]) continue;
                for (try self.dependencies(@intCast(candidate_index))) |dependency| {
                    if (dependency != current) continue;
                    visited[candidate_index] = true;
                    stack[stack_len] = @intCast(candidate_index);
                    stack_len += 1;
                    break;
                }
            }
        }
        return collectVisited(self.entries.len, &visited, storage);
    }
};

pub const OwnedCatalog = struct {
    allocator: std.mem.Allocator,
    name_offset: u32,
    name_len: u32,
    source_digest: Digest,
    integrity_digest: Digest,
    strings: []u8,
    entries: []EntryView,
    dependency_indices: []u32,

    pub fn view(self: *const OwnedCatalog) View {
        return .{
            .name = self.strings[self.name_offset..][0..self.name_len],
            .source_digest = self.source_digest,
            .integrity_digest = self.integrity_digest,
            .entries = self.entries,
            .dependency_indices = self.dependency_indices,
        };
    }

    pub fn identity(self: *const OwnedCatalog) Identity {
        return self.view().identity();
    }

    pub fn deinit(self: *OwnedCatalog) void {
        self.allocator.free(self.dependency_indices);
        self.allocator.free(self.entries);
        self.allocator.free(self.strings);
        self.* = undefined;
    }
};

pub const EncodeResult = union(enum) { bytes: []u8, failed: ValidationFailure };
pub const DecodeResult = union(enum) { catalog: OwnedCatalog, failed: ValidationFailure };

const NameRef = struct { offset: u32, len: u32 };
const ResolvedRange = struct { start: u32 = 0, count: u32 = 0 };

pub fn encode(
    allocator: std.mem.Allocator,
    declaration: Declaration,
    limits: Limits,
) !EncodeResult {
    try limits.validate();
    if (!validPathLike(declaration.name, max_catalog_name_bytes, true)) {
        return .{ .failed = .invalid_catalog_name };
    }
    if (!hasNonzeroByte(&declaration.source_digest)) {
        return .{ .failed = .missing_catalog_source_digest };
    }
    if (declaration.entries.len == 0) return .{ .failed = .empty_catalog };
    if (declaration.entries.len > limits.max_entries) return capacityFailure(
        .entries,
        declaration.entries.len,
        limits.max_entries,
    );

    var strings_size: usize = declaration.name.len;
    var dependency_count: usize = 0;
    for (declaration.entries, 0..) |entry, index| {
        const issue = EntryIssue{ .entry_index = @intCast(index) };
        if (!validPathLike(entry.semantic_id, max_semantic_id_bytes, true)) {
            return .{ .failed = .{ .invalid_semantic_id = issue } };
        }
        if (!validPathLike(entry.bundle_key, max_bundle_key_bytes, false)) {
            return .{ .failed = .{ .invalid_bundle_key = issue } };
        }
        if (entry.recipe_version == 0) return .{ .failed = .{ .invalid_recipe_version = issue } };
        if (entry.logical_checksum == 0) return .{ .failed = .{ .invalid_logical_checksum = issue } };
        entry.bundle.validate() catch return .{ .failed = .{ .invalid_bundle_identity = issue } };
        if (entry.dependencies.len > limits.max_dependencies_per_entry) return capacityFailure(
            .dependencies_per_entry,
            entry.dependencies.len,
            limits.max_dependencies_per_entry,
        );
        strings_size = std.math.add(usize, strings_size, entry.semantic_id.len) catch
            return capacityFailure(.strings, std.math.maxInt(u64), limits.max_strings_bytes);
        strings_size = std.math.add(usize, strings_size, entry.bundle_key.len) catch
            return capacityFailure(.strings, std.math.maxInt(u64), limits.max_strings_bytes);
        dependency_count = std.math.add(usize, dependency_count, entry.dependencies.len) catch
            return capacityFailure(.dependencies, std.math.maxInt(u64), limits.max_dependencies);
    }
    if (strings_size > limits.max_strings_bytes) {
        return capacityFailure(.strings, strings_size, limits.max_strings_bytes);
    }
    if (dependency_count > limits.max_dependencies) {
        return capacityFailure(.dependencies, dependency_count, limits.max_dependencies);
    }

    for (declaration.entries, 0..) |entry, index| {
        for (declaration.entries[0..index], 0..) |earlier, earlier_index| {
            const duplicate = DuplicateIssue{
                .first_index = @intCast(earlier_index),
                .second_index = @intCast(index),
            };
            if (ChunkCoord.eql(entry.coord, earlier.coord)) {
                return .{ .failed = .{ .duplicate_coordinate = duplicate } };
            }
            if (std.mem.eql(u8, entry.semantic_id, earlier.semantic_id)) {
                return .{ .failed = .{ .duplicate_semantic_id = duplicate } };
            }
            if (std.mem.eql(u8, entry.bundle_key, earlier.bundle_key)) {
                return .{ .failed = .{ .duplicate_bundle_key = duplicate } };
            }
        }
        for (entry.dependencies, 0..) |dependency, dependency_index| {
            for (entry.dependencies[0..dependency_index]) |earlier| {
                if (std.mem.eql(u8, dependency, earlier)) return .{ .failed = .{
                    .duplicate_dependency = .{
                        .entry_index = @intCast(index),
                        .dependency_index = @intCast(dependency_index),
                    },
                } };
            }
        }
    }

    const sorted = try allocator.alloc(u32, declaration.entries.len);
    defer allocator.free(sorted);
    for (sorted, 0..) |*value, index| value.* = @intCast(index);
    std.mem.sort(u32, sorted, SortContext{ .entries = declaration.entries }, lessEntryIndex);

    const ranges = try allocator.alloc(ResolvedRange, declaration.entries.len);
    defer allocator.free(ranges);
    const resolved_dependencies = try allocator.alloc(u32, dependency_count);
    defer allocator.free(resolved_dependencies);
    var dependency_cursor: usize = 0;
    for (sorted, 0..) |input_index, canonical_index| {
        const entry = declaration.entries[input_index];
        ranges[canonical_index] = .{
            .start = @intCast(dependency_cursor),
            .count = @intCast(entry.dependencies.len),
        };
        const resolved = resolved_dependencies[dependency_cursor..][0..entry.dependencies.len];
        for (entry.dependencies, 0..) |dependency, dependency_index| {
            const target = findCanonicalEntry(declaration.entries, sorted, dependency) orelse
                return .{ .failed = .{ .missing_dependency = .{
                    .entry_index = @intCast(input_index),
                    .dependency_index = @intCast(dependency_index),
                } } };
            if (target == canonical_index) return .{ .failed = .{ .self_dependency = .{
                .entry_index = @intCast(input_index),
                .dependency_index = @intCast(dependency_index),
            } } };
            resolved[dependency_index] = @intCast(target);
        }
        std.mem.sort(u32, resolved, {}, lessU32);
        dependency_cursor += entry.dependencies.len;
    }
    if (cycleEntry(ranges, resolved_dependencies)) |entry_index| {
        return .{ .failed = .{ .dependency_cycle = .{ .entry_index = entry_index } } };
    }

    const entries_offset = std.mem.alignForward(usize, header_size + strings_size, 4);
    const entries_bytes = std.math.mul(usize, declaration.entries.len, entry_stride) catch
        return capacityFailure(.file_bytes, std.math.maxInt(u64), limits.max_file_bytes);
    const dependencies_offset = std.math.add(usize, entries_offset, entries_bytes) catch
        return capacityFailure(.file_bytes, std.math.maxInt(u64), limits.max_file_bytes);
    const dependencies_bytes = std.math.mul(usize, dependency_count, dependency_stride) catch
        return capacityFailure(.file_bytes, std.math.maxInt(u64), limits.max_file_bytes);
    const total_size = std.math.add(usize, dependencies_offset, dependencies_bytes) catch
        return capacityFailure(.file_bytes, std.math.maxInt(u64), limits.max_file_bytes);
    if (total_size > limits.max_file_bytes) {
        return capacityFailure(.file_bytes, total_size, limits.max_file_bytes);
    }

    const bytes = try allocator.alloc(u8, total_size);
    errdefer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..magic.len], &magic);
    putU16(bytes, 8, format_version);
    putU16(bytes, 10, schema_cohort);
    putU32(bytes, 12, header_size);
    putU64(bytes, total_size_offset, total_size);
    putU64(bytes, strings_offset_offset, header_size);
    putU64(bytes, strings_size_offset, strings_size);
    putU64(bytes, entries_offset_offset, entries_offset);
    putU32(bytes, entry_count_offset, declaration.entries.len);
    putU32(bytes, entry_stride_offset, entry_stride);
    putU64(bytes, dependencies_offset_offset, dependencies_offset);
    putU32(bytes, dependency_count_offset, dependency_count);
    putU32(bytes, dependency_stride_offset, dependency_stride);
    @memcpy(bytes[source_digest_offset..integrity_digest_offset], &declaration.source_digest);
    putU32(bytes, catalog_name_offset, 0);
    putU32(bytes, catalog_name_len_offset, declaration.name.len);

    var semantic_refs: [max_entries]NameRef = undefined;
    var key_refs: [max_entries]NameRef = undefined;
    var string_cursor: usize = header_size;
    @memcpy(bytes[string_cursor..][0..declaration.name.len], declaration.name);
    string_cursor += declaration.name.len;
    for (sorted, 0..) |input_index, canonical_index| {
        const entry = declaration.entries[input_index];
        semantic_refs[canonical_index] = .{
            .offset = @intCast(string_cursor - header_size),
            .len = @intCast(entry.semantic_id.len),
        };
        @memcpy(bytes[string_cursor..][0..entry.semantic_id.len], entry.semantic_id);
        string_cursor += entry.semantic_id.len;
        key_refs[canonical_index] = .{
            .offset = @intCast(string_cursor - header_size),
            .len = @intCast(entry.bundle_key.len),
        };
        @memcpy(bytes[string_cursor..][0..entry.bundle_key.len], entry.bundle_key);
        string_cursor += entry.bundle_key.len;
    }
    std.debug.assert(string_cursor == header_size + strings_size);

    for (sorted, 0..) |input_index, canonical_index| {
        encodeEntry(
            bytes[entries_offset + canonical_index * entry_stride ..][0..entry_stride],
            declaration.entries[input_index],
            semantic_refs[canonical_index],
            key_refs[canonical_index],
            ranges[canonical_index],
        );
    }
    for (resolved_dependencies, 0..) |dependency, index| {
        putU32(bytes, dependencies_offset + index * dependency_stride, dependency);
    }
    var integrity: Digest = undefined;
    calculateIntegrity(bytes, &integrity);
    @memcpy(bytes[integrity_digest_offset..catalog_name_offset], &integrity);
    return .{ .bytes = bytes };
}

pub fn decode(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    limits: Limits,
) !DecodeResult {
    try limits.validate();
    const layout = switch (preflight(bytes, limits)) {
        .failed => |failure| return .{ .failed = failure },
        .valid => |value| value,
    };

    const strings = try allocator.dupe(u8, bytes[layout.strings_offset..][0..layout.strings_size]);
    errdefer allocator.free(strings);
    const entries = try allocator.alloc(EntryView, layout.entry_count);
    errdefer allocator.free(entries);
    const dependency_indices = try allocator.alloc(u32, layout.dependency_count);
    errdefer allocator.free(dependency_indices);

    for (entries, 0..) |*entry, index| {
        const encoded = bytes[layout.entries_offset + index * entry_stride ..][0..entry_stride];
        const semantic = readNameRef(encoded, 8);
        const key = readNameRef(encoded, 16);
        entry.* = .{
            .coord = .{ .x = getI32(encoded, 0), .z = getI32(encoded, 4) },
            .semantic_id = strings[semantic.offset..][0..semantic.len],
            .bundle_key = strings[key.offset..][0..key.len],
            .recipe_version = getU32(encoded, 24),
            .logical_checksum = getU64(encoded, 28),
            .bundle = .{
                .format_version = getU16(encoded, 36),
                .schema_cohort = getU16(encoded, 38),
                .source_digest = encoded[40..72].*,
                .integrity_digest = encoded[72..104].*,
            },
            .dependency_start = getU32(encoded, 104),
            .dependency_count = getU32(encoded, 108),
        };
    }
    for (dependency_indices, 0..) |*dependency, index| {
        dependency.* = getU32(bytes, layout.dependencies_offset + index * dependency_stride);
    }
    return .{ .catalog = .{
        .allocator = allocator,
        .name_offset = layout.name.offset,
        .name_len = layout.name.len,
        .source_digest = layout.source_digest,
        .integrity_digest = layout.integrity_digest,
        .strings = strings,
        .entries = entries,
        .dependency_indices = dependency_indices,
    } };
}

const Layout = struct {
    strings_offset: usize,
    strings_size: usize,
    entries_offset: usize,
    entry_count: usize,
    dependencies_offset: usize,
    dependency_count: usize,
    name: NameRef,
    source_digest: Digest,
    integrity_digest: Digest,
};

const PreflightResult = union(enum) { valid: Layout, failed: ValidationFailure };

fn preflight(bytes: []const u8, limits: Limits) PreflightResult {
    if (bytes.len < magic.len) return .{ .failed = .truncated };
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return .{ .failed = .bad_magic };
    if (bytes.len < header_size) return .{ .failed = .truncated };
    const found_format = getU16(bytes, 8);
    if (found_format != format_version) return .{ .failed = .{ .unsupported_format_version = found_format } };
    const found_schema = getU16(bytes, 10);
    if (found_schema != schema_cohort) return .{ .failed = .{ .incompatible_schema = found_schema } };
    if (getU32(bytes, 12) != header_size or
        getU32(bytes, entry_stride_offset) != entry_stride or
        getU32(bytes, dependency_stride_offset) != dependency_stride or
        !std.mem.allEqual(u8, bytes[reserved_offset..header_size], 0))
    {
        return .{ .failed = .invalid_header };
    }
    const declared_total = getU64(bytes, total_size_offset);
    if (declared_total > bytes.len) return .{ .failed = .truncated };
    if (declared_total < bytes.len) return .{ .failed = .trailing_data };
    if (bytes.len > limits.max_file_bytes) return preflightCapacity(.file_bytes, bytes.len, limits.max_file_bytes);

    const strings_offset = castUsize(getU64(bytes, strings_offset_offset)) orelse return .{ .failed = .invalid_header };
    const strings_size = castUsize(getU64(bytes, strings_size_offset)) orelse return .{ .failed = .invalid_header };
    const entries_offset = castUsize(getU64(bytes, entries_offset_offset)) orelse return .{ .failed = .invalid_header };
    const entry_count: usize = getU32(bytes, entry_count_offset);
    const dependencies_offset = castUsize(getU64(bytes, dependencies_offset_offset)) orelse return .{ .failed = .invalid_header };
    const dependency_count: usize = getU32(bytes, dependency_count_offset);
    if (entry_count == 0) return .{ .failed = .empty_catalog };
    if (strings_size > limits.max_strings_bytes) return preflightCapacity(.strings, strings_size, limits.max_strings_bytes);
    if (entry_count > limits.max_entries) return preflightCapacity(.entries, entry_count, limits.max_entries);
    if (dependency_count > limits.max_dependencies) return preflightCapacity(.dependencies, dependency_count, limits.max_dependencies);

    const strings_end = std.math.add(usize, strings_offset, strings_size) catch return .{ .failed = .size_mismatch };
    const expected_entries_offset = std.mem.alignForward(usize, strings_end, 4);
    const entries_size = std.math.mul(usize, entry_count, entry_stride) catch return .{ .failed = .size_mismatch };
    const expected_dependencies_offset = std.math.add(usize, entries_offset, entries_size) catch return .{ .failed = .size_mismatch };
    const dependencies_size = std.math.mul(usize, dependency_count, dependency_stride) catch return .{ .failed = .size_mismatch };
    const expected_total = std.math.add(usize, dependencies_offset, dependencies_size) catch return .{ .failed = .size_mismatch };
    if (strings_offset != header_size or entries_offset != expected_entries_offset or
        dependencies_offset != expected_dependencies_offset or expected_total != bytes.len)
    {
        return .{ .failed = .size_mismatch };
    }
    if (!std.mem.allEqual(u8, bytes[strings_end..entries_offset], 0)) {
        return .{ .failed = .noncanonical_wire_order };
    }
    var expected_integrity: Digest = undefined;
    calculateIntegrity(bytes, &expected_integrity);
    if (!std.mem.eql(u8, &expected_integrity, bytes[integrity_digest_offset..catalog_name_offset])) {
        return .{ .failed = .integrity_mismatch };
    }
    const source_digest: Digest = bytes[source_digest_offset..integrity_digest_offset].*;
    if (!hasNonzeroByte(&source_digest)) return .{ .failed = .missing_catalog_source_digest };
    const name = NameRef{
        .offset = getU32(bytes, catalog_name_offset),
        .len = getU32(bytes, catalog_name_len_offset),
    };
    const strings = bytes[strings_offset..strings_end];
    const catalog_name = nameBytes(strings, name) orelse return .{ .failed = .invalid_header };
    if (name.offset != 0 or !validPathLike(catalog_name, max_catalog_name_bytes, true)) {
        return .{ .failed = .invalid_catalog_name };
    }

    var temp_entries: [max_entries]EntryView = undefined;
    var temp_dependencies: [max_dependencies]u32 = undefined;
    var string_cursor: usize = name.len;
    var dependency_cursor: usize = 0;
    for (temp_entries[0..entry_count], 0..) |*entry, index| {
        const encoded = bytes[entries_offset + index * entry_stride ..][0..entry_stride];
        const semantic_ref = readNameRef(encoded, 8);
        const key_ref = readNameRef(encoded, 16);
        const semantic = nameBytes(strings, semantic_ref) orelse return .{ .failed = .invalid_header };
        const key = nameBytes(strings, key_ref) orelse return .{ .failed = .invalid_header };
        if (semantic_ref.offset != string_cursor) return .{ .failed = .noncanonical_wire_order };
        string_cursor += semantic.len;
        if (key_ref.offset != string_cursor) return .{ .failed = .noncanonical_wire_order };
        string_cursor += key.len;
        const issue = EntryIssue{ .entry_index = @intCast(index) };
        if (!validPathLike(semantic, max_semantic_id_bytes, true)) return .{ .failed = .{ .invalid_semantic_id = issue } };
        if (!validPathLike(key, max_bundle_key_bytes, false)) return .{ .failed = .{ .invalid_bundle_key = issue } };
        const recipe = getU32(encoded, 24);
        const checksum = getU64(encoded, 28);
        if (recipe == 0) return .{ .failed = .{ .invalid_recipe_version = issue } };
        if (checksum == 0) return .{ .failed = .{ .invalid_logical_checksum = issue } };
        const bundle = BundleIdentity{
            .format_version = getU16(encoded, 36),
            .schema_cohort = getU16(encoded, 38),
            .source_digest = encoded[40..72].*,
            .integrity_digest = encoded[72..104].*,
        };
        bundle.validate() catch return .{ .failed = .{ .invalid_bundle_identity = issue } };
        const range = ResolvedRange{ .start = getU32(encoded, 104), .count = getU32(encoded, 108) };
        if (range.count > limits.max_dependencies_per_entry) return preflightCapacity(
            .dependencies_per_entry,
            range.count,
            limits.max_dependencies_per_entry,
        );
        const range_end = std.math.add(u32, range.start, range.count) catch
            return .{ .failed = .invalid_header };
        if (range.start != dependency_cursor or range_end > dependency_count) {
            return .{ .failed = .noncanonical_wire_order };
        }
        dependency_cursor = std.math.add(usize, dependency_cursor, range.count) catch
            return .{ .failed = .invalid_header };
        entry.* = .{
            .coord = .{ .x = getI32(encoded, 0), .z = getI32(encoded, 4) },
            .semantic_id = semantic,
            .bundle_key = key,
            .recipe_version = recipe,
            .logical_checksum = checksum,
            .bundle = bundle,
            .dependency_start = range.start,
            .dependency_count = range.count,
        };
        if (index != 0) switch (std.mem.order(u8, temp_entries[index - 1].semantic_id, semantic)) {
            .lt => {},
            .eq => return .{ .failed = .{ .duplicate_semantic_id = .{
                .first_index = @intCast(index - 1),
                .second_index = @intCast(index),
            } } },
            .gt => return .{ .failed = .noncanonical_wire_order },
        };
    }
    if (string_cursor != strings.len or dependency_cursor != dependency_count) {
        return .{ .failed = .noncanonical_wire_order };
    }
    for (temp_entries[0..entry_count], 0..) |entry, index| {
        for (temp_entries[0..index], 0..) |earlier, earlier_index| {
            const duplicate = DuplicateIssue{ .first_index = @intCast(earlier_index), .second_index = @intCast(index) };
            if (ChunkCoord.eql(entry.coord, earlier.coord)) return .{ .failed = .{ .duplicate_coordinate = duplicate } };
            if (std.mem.eql(u8, entry.bundle_key, earlier.bundle_key)) return .{ .failed = .{ .duplicate_bundle_key = duplicate } };
        }
    }
    for (temp_dependencies[0..dependency_count], 0..) |*dependency, index| {
        dependency.* = getU32(bytes, dependencies_offset + index * dependency_stride);
    }
    for (temp_entries[0..entry_count], 0..) |entry, entry_index| {
        const start: usize = entry.dependency_start;
        const dependencies = temp_dependencies[start..][0..entry.dependency_count];
        for (dependencies, 0..) |dependency, dependency_index| {
            const issue = DependencyIssue{
                .entry_index = @intCast(entry_index),
                .dependency_index = @intCast(dependency_index),
            };
            if (dependency >= entry_count) return .{ .failed = .{ .missing_dependency = issue } };
            if (dependency == entry_index) return .{ .failed = .{ .self_dependency = issue } };
            if (dependency_index != 0) {
                if (dependency == dependencies[dependency_index - 1]) return .{ .failed = .{ .duplicate_dependency = issue } };
                if (dependency < dependencies[dependency_index - 1]) return .{ .failed = .noncanonical_wire_order };
            }
        }
    }
    var ranges: [max_entries]ResolvedRange = undefined;
    for (temp_entries[0..entry_count], 0..) |entry, index| ranges[index] = .{
        .start = entry.dependency_start,
        .count = entry.dependency_count,
    };
    if (cycleEntry(ranges[0..entry_count], temp_dependencies[0..dependency_count])) |entry_index| {
        return .{ .failed = .{ .dependency_cycle = .{ .entry_index = entry_index } } };
    }

    return .{ .valid = .{
        .strings_offset = strings_offset,
        .strings_size = strings_size,
        .entries_offset = entries_offset,
        .entry_count = entry_count,
        .dependencies_offset = dependencies_offset,
        .dependency_count = dependency_count,
        .name = name,
        .source_digest = source_digest,
        .integrity_digest = bytes[integrity_digest_offset..catalog_name_offset].*,
    } };
}

const SortContext = struct { entries: []const EntryDeclaration };

fn lessEntryIndex(context: SortContext, lhs: u32, rhs: u32) bool {
    return std.mem.order(u8, context.entries[lhs].semantic_id, context.entries[rhs].semantic_id) == .lt;
}

fn lessU32(_: void, lhs: u32, rhs: u32) bool {
    return lhs < rhs;
}

fn findCanonicalEntry(entries: []const EntryDeclaration, sorted: []const u32, semantic_id: []const u8) ?usize {
    for (sorted, 0..) |input_index, canonical_index| {
        if (std.mem.eql(u8, entries[input_index].semantic_id, semantic_id)) return canonical_index;
    }
    return null;
}

fn cycleEntry(ranges: []const ResolvedRange, dependencies: []const u32) ?u32 {
    var colors = [_]u8{0} ** max_entries;
    for (ranges, 0..) |_, index| {
        if (colors[index] != 0) continue;
        if (visitForCycle(@intCast(index), ranges, dependencies, &colors)) return @intCast(index);
    }
    return null;
}

fn visitForCycle(
    entry: u32,
    ranges: []const ResolvedRange,
    dependencies: []const u32,
    colors: *[max_entries]u8,
) bool {
    if (colors[entry] == 1) return true;
    if (colors[entry] == 2) return false;
    colors[entry] = 1;
    const range = ranges[entry];
    for (dependencies[range.start..][0..range.count]) |dependency| {
        if (visitForCycle(dependency, ranges, dependencies, colors)) return true;
    }
    colors[entry] = 2;
    return false;
}

fn collectVisited(count: usize, visited: *const [max_entries]bool, storage: []u32) []const u32 {
    var output_count: usize = 0;
    for (visited[0..count], 0..) |is_visited, index| {
        if (!is_visited) continue;
        storage[output_count] = @intCast(index);
        output_count += 1;
    }
    return storage[0..output_count];
}

fn validPathLike(value: []const u8, maximum: usize, allow_dot: bool) bool {
    if (value.len == 0 or value.len > maximum or value[0] == '/' or value[value.len - 1] == '/') return false;
    var segment_start: usize = 0;
    for (value, 0..) |byte, index| {
        const allowed = (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or byte == '_' or byte == '-' or byte == '/' or
            (allow_dot and byte == '.');
        if (!allowed) return false;
        if (byte == '/') {
            const segment = value[segment_start..index];
            if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
            segment_start = index + 1;
        }
    }
    const final = value[segment_start..];
    return final.len != 0 and !std.mem.eql(u8, final, ".") and !std.mem.eql(u8, final, "..");
}

fn encodeEntry(bytes: []u8, entry: EntryDeclaration, semantic: NameRef, key: NameRef, range: ResolvedRange) void {
    putI32(bytes, 0, entry.coord.x);
    putI32(bytes, 4, entry.coord.z);
    putNameRef(bytes, 8, semantic);
    putNameRef(bytes, 16, key);
    putU32(bytes, 24, entry.recipe_version);
    putU64(bytes, 28, entry.logical_checksum);
    putU16(bytes, 36, entry.bundle.format_version);
    putU16(bytes, 38, entry.bundle.schema_cohort);
    @memcpy(bytes[40..72], &entry.bundle.source_digest);
    @memcpy(bytes[72..104], &entry.bundle.integrity_digest);
    putU32(bytes, 104, range.start);
    putU32(bytes, 108, range.count);
}

fn calculateIntegrity(bytes: []const u8, output: *Digest) void {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("incinerator.catalog.wire.v1");
    hash.update(bytes[0..integrity_digest_offset]);
    hash.update(&([_]u8{0} ** 32));
    hash.update(bytes[catalog_name_offset..]);
    hash.final(output);
}

fn capacityFailure(kind: CapacityKind, actual: anytype, maximum: anytype) EncodeResult {
    return .{ .failed = .{ .capacity_exceeded = .{
        .kind = kind,
        .actual = std.math.cast(u64, actual) orelse std.math.maxInt(u64),
        .maximum = std.math.cast(u64, maximum) orelse std.math.maxInt(u64),
    } } };
}

fn preflightCapacity(kind: CapacityKind, actual: anytype, maximum: anytype) PreflightResult {
    return .{ .failed = .{ .capacity_exceeded = .{
        .kind = kind,
        .actual = std.math.cast(u64, actual) orelse std.math.maxInt(u64),
        .maximum = std.math.cast(u64, maximum) orelse std.math.maxInt(u64),
    } } };
}

fn nameBytes(strings: []const u8, reference: NameRef) ?[]const u8 {
    const end = std.math.add(u32, reference.offset, reference.len) catch return null;
    if (reference.len == 0 or end > strings.len) return null;
    return strings[reference.offset..end];
}

fn readNameRef(bytes: []const u8, offset: usize) NameRef {
    return .{ .offset = getU32(bytes, offset), .len = getU32(bytes, offset + 4) };
}

fn putNameRef(bytes: []u8, offset: usize, value: NameRef) void {
    putU32(bytes, offset, value.offset);
    putU32(bytes, offset + 4, value.len);
}

fn castUsize(value: u64) ?usize {
    return std.math.cast(usize, value);
}

fn hasNonzeroByte(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return true;
    return false;
}

fn hashU16(hash: *std.crypto.hash.sha2.Sha256, value: u16) void {
    var encoded: [2]u8 = undefined;
    std.mem.writeInt(u16, &encoded, value, .little);
    hash.update(&encoded);
}

fn hashU32(hash: *std.crypto.hash.sha2.Sha256, value: u32) void {
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, value, .little);
    hash.update(&encoded);
}

fn putU16(bytes: []u8, offset: usize, value: anytype) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], @intCast(value), .little);
}

fn putU32(bytes: []u8, offset: usize, value: anytype) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], @intCast(value), .little);
}

fn putI32(bytes: []u8, offset: usize, value: i32) void {
    std.mem.writeInt(i32, bytes[offset..][0..4], value, .little);
}

fn putU64(bytes: []u8, offset: usize, value: anytype) void {
    std.mem.writeInt(u64, bytes[offset..][0..8], @intCast(value), .little);
}

fn getU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn getU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn getI32(bytes: []const u8, offset: usize) i32 {
    return std.mem.readInt(i32, bytes[offset..][0..4], .little);
}

fn getU64(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

const no_dependencies = [_][]const u8{};
const east_dependencies = [_][]const u8{"district/base"};
const world_dependencies = [_][]const u8{ "district/base", "district/east" };

fn testEntries() [3]EntryDeclaration {
    return .{
        .{
            .coord = .{ .x = 0, .z = 0 },
            .semantic_id = "district/base",
            .bundle_key = "district/base",
            .recipe_version = 1,
            .logical_checksum = 0x1111,
            .bundle = .{
                .format_version = 1,
                .schema_cohort = 1,
                .source_digest = [_]u8{0x11} ** 32,
                .integrity_digest = [_]u8{0x21} ** 32,
            },
            .dependencies = &no_dependencies,
        },
        .{
            .coord = .{ .x = 1, .z = 0 },
            .semantic_id = "district/east",
            .bundle_key = "district/east",
            .recipe_version = 1,
            .logical_checksum = 0x2222,
            .bundle = .{
                .format_version = 1,
                .schema_cohort = 1,
                .source_digest = [_]u8{0x12} ** 32,
                .integrity_digest = [_]u8{0x22} ** 32,
            },
            .dependencies = &east_dependencies,
        },
        .{
            .coord = .{ .x = 2, .z = 0 },
            .semantic_id = "district/world",
            .bundle_key = "district/world",
            .recipe_version = 1,
            .logical_checksum = 0x3333,
            .bundle = .{
                .format_version = 1,
                .schema_cohort = 1,
                .source_digest = [_]u8{0x13} ** 32,
                .integrity_digest = [_]u8{0x23} ** 32,
            },
            .dependencies = &world_dependencies,
        },
    };
}

fn testDeclaration(entries: []const EntryDeclaration) Declaration {
    return .{
        .name = "catalog/sandbox",
        .source_digest = [_]u8{0x5a} ** 32,
        .entries = entries,
    };
}

fn expectEncoded(declaration: Declaration) ![]u8 {
    return switch (try encode(std.testing.allocator, declaration, .{})) {
        .bytes => |bytes| bytes,
        .failed => |failure| {
            std.debug.print("unexpected catalog encode failure: {any}\n", .{failure});
            return error.UnexpectedCatalogEncodeFailure;
        },
    };
}

fn expectFailure(expected: std.meta.Tag(ValidationFailure), declaration: Declaration) !void {
    switch (try encode(std.testing.allocator, declaration, .{})) {
        .failed => |failure| try std.testing.expectEqual(expected, std.meta.activeTag(failure)),
        .bytes => |bytes| {
            std.testing.allocator.free(bytes);
            return error.ExpectedCatalogFailure;
        },
    }
}

fn refreshIntegrity(bytes: []u8) void {
    var digest: Digest = undefined;
    calculateIntegrity(bytes, &digest);
    @memcpy(bytes[integrity_digest_offset..catalog_name_offset], &digest);
}

test "catalog encoding is canonical across declaration order and owns decoded views" {
    const entries = testEntries();
    const first = try expectEncoded(testDeclaration(&entries));
    defer std.testing.allocator.free(first);
    const permuted = [_]EntryDeclaration{ entries[2], entries[0], entries[1] };
    const second = try expectEncoded(testDeclaration(&permuted));
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualSlices(u8, first, second);
    try std.testing.expectEqualSlices(u8, &magic, first[0..magic.len]);
    try std.testing.expectEqual(format_version, getU16(first, 8));
    try std.testing.expectEqual(@as(u64, first.len), getU64(first, total_size_offset));

    var owned = switch (try decode(std.testing.allocator, first, .{})) {
        .catalog => |catalog| catalog,
        .failed => |failure| {
            std.debug.print("unexpected catalog decode failure: {any}\n", .{failure});
            return error.UnexpectedCatalogDecodeFailure;
        },
    };
    defer owned.deinit();
    const view = owned.view();
    try std.testing.expectEqualStrings("catalog/sandbox", view.name);
    try std.testing.expectEqual(@as(usize, 3), view.entries.len);
    try std.testing.expectEqualStrings("district/base", view.entries[0].semantic_id);
    try std.testing.expectEqualStrings("district/east", view.entries[1].semantic_id);
    try std.testing.expectEqual(@as(?u32, 1), view.lookupCoordinate(.{ .x = 1, .z = 0 }));
    try std.testing.expectEqual(@as(?u32, 2), view.lookupBundleKey("district/world"));
    try std.testing.expectEqual(@as(?u32, null), view.lookupSemanticId("district/missing"));
    try std.testing.expectEqualSlices(u32, &.{0}, try view.dependencies(1));
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, try view.dependencies(2));
    try std.testing.expectEqual(try view.fingerprint(), try owned.identity().canonicalFingerprint());
}

test "dependency and reverse-dependent closures are canonical and bounded" {
    const entries = testEntries();
    const bytes = try expectEncoded(testDeclaration(&entries));
    defer std.testing.allocator.free(bytes);
    var owned = (try decode(std.testing.allocator, bytes, .{})).catalog;
    defer owned.deinit();
    const view = owned.view();
    var storage: [max_entries]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, try view.dependencyClosure(2, &storage));
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, try view.dependentClosure(0, &storage));
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, try view.dependencyClosure(1, &storage));
    try std.testing.expectError(error.DestinationTooSmall, view.dependencyClosure(2, storage[0..2]));
}

test "declaration validation distinguishes duplicates missing self dependencies and cycles" {
    const canonical = testEntries();

    var duplicate_coord = canonical;
    duplicate_coord[2].coord = duplicate_coord[0].coord;
    try expectFailure(.duplicate_coordinate, testDeclaration(&duplicate_coord));

    var duplicate_id = canonical;
    duplicate_id[2].semantic_id = duplicate_id[0].semantic_id;
    try expectFailure(.duplicate_semantic_id, testDeclaration(&duplicate_id));

    var duplicate_key = canonical;
    duplicate_key[2].bundle_key = duplicate_key[0].bundle_key;
    try expectFailure(.duplicate_bundle_key, testDeclaration(&duplicate_key));

    const duplicate_dependencies = [_][]const u8{ "district/base", "district/base" };
    var duplicate_dependency = canonical;
    duplicate_dependency[1].dependencies = &duplicate_dependencies;
    try expectFailure(.duplicate_dependency, testDeclaration(&duplicate_dependency));

    const missing_dependencies = [_][]const u8{"district/missing"};
    var missing = canonical;
    missing[1].dependencies = &missing_dependencies;
    try expectFailure(.missing_dependency, testDeclaration(&missing));

    const self_dependencies = [_][]const u8{"district/east"};
    var self = canonical;
    self[1].dependencies = &self_dependencies;
    try expectFailure(.self_dependency, testDeclaration(&self));

    const base_cycle_dependencies = [_][]const u8{"district/world"};
    var cycle = canonical;
    cycle[0].dependencies = &base_cycle_dependencies;
    try expectFailure(.dependency_cycle, testDeclaration(&cycle));
}

test "decoder rejects version schema truncation integrity and hostile canonical fields" {
    const entries = testEntries();
    const canonical = try expectEncoded(testDeclaration(&entries));
    defer std.testing.allocator.free(canonical);

    try std.testing.expectEqual(
        std.meta.Tag(ValidationFailure).truncated,
        std.meta.activeTag((try decode(std.testing.allocator, canonical[0 .. header_size - 1], .{})).failed),
    );

    const bad_version = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(bad_version);
    putU16(bad_version, 8, format_version + 1);
    try std.testing.expectEqual(
        std.meta.Tag(ValidationFailure).unsupported_format_version,
        std.meta.activeTag((try decode(std.testing.allocator, bad_version, .{})).failed),
    );

    const bad_schema = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(bad_schema);
    putU16(bad_schema, 10, schema_cohort + 1);
    try std.testing.expectEqual(
        std.meta.Tag(ValidationFailure).incompatible_schema,
        std.meta.activeTag((try decode(std.testing.allocator, bad_schema, .{})).failed),
    );

    const corrupt = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(corrupt);
    corrupt[header_size + 2] ^= 0x80;
    try std.testing.expectEqual(
        std.meta.Tag(ValidationFailure).integrity_mismatch,
        std.meta.activeTag((try decode(std.testing.allocator, corrupt, .{})).failed),
    );

    const noncanonical = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(noncanonical);
    const entries_offset: usize = @intCast(getU64(noncanonical, entries_offset_offset));
    var temporary: [entry_stride]u8 = undefined;
    @memcpy(&temporary, noncanonical[entries_offset..][0..entry_stride]);
    @memcpy(noncanonical[entries_offset..][0..entry_stride], noncanonical[entries_offset + entry_stride ..][0..entry_stride]);
    @memcpy(noncanonical[entries_offset + entry_stride ..][0..entry_stride], &temporary);
    refreshIntegrity(noncanonical);
    try std.testing.expectEqual(
        std.meta.Tag(ValidationFailure).noncanonical_wire_order,
        std.meta.activeTag((try decode(std.testing.allocator, noncanonical, .{})).failed),
    );
}

test "decoder distinguishes duplicate missing self unordered dependencies and cycles" {
    const entries = testEntries();
    const canonical = try expectEncoded(testDeclaration(&entries));
    defer std.testing.allocator.free(canonical);
    const dependencies_offset: usize = @intCast(getU64(canonical, dependencies_offset_offset));

    const duplicate = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(duplicate);
    putU32(duplicate, dependencies_offset + 2 * dependency_stride, 0);
    refreshIntegrity(duplicate);
    try std.testing.expectEqual(
        std.meta.Tag(ValidationFailure).duplicate_dependency,
        std.meta.activeTag((try decode(std.testing.allocator, duplicate, .{})).failed),
    );

    const missing = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(missing);
    putU32(missing, dependencies_offset, 99);
    refreshIntegrity(missing);
    try std.testing.expectEqual(
        std.meta.Tag(ValidationFailure).missing_dependency,
        std.meta.activeTag((try decode(std.testing.allocator, missing, .{})).failed),
    );

    const self = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(self);
    putU32(self, dependencies_offset, 1);
    refreshIntegrity(self);
    try std.testing.expectEqual(
        std.meta.Tag(ValidationFailure).self_dependency,
        std.meta.activeTag((try decode(std.testing.allocator, self, .{})).failed),
    );

    const unordered = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(unordered);
    putU32(unordered, dependencies_offset + dependency_stride, 1);
    putU32(unordered, dependencies_offset + 2 * dependency_stride, 0);
    refreshIntegrity(unordered);
    try std.testing.expectEqual(
        std.meta.Tag(ValidationFailure).noncanonical_wire_order,
        std.meta.activeTag((try decode(std.testing.allocator, unordered, .{})).failed),
    );

    const cycle = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(cycle);
    putU32(cycle, dependencies_offset, 2);
    refreshIntegrity(cycle);
    try std.testing.expectEqual(
        std.meta.Tag(ValidationFailure).dependency_cycle,
        std.meta.activeTag((try decode(std.testing.allocator, cycle, .{})).failed),
    );
}

test "limits are enforced before allocation and identity is domain separated" {
    const entries = testEntries();
    switch (try encode(std.testing.allocator, testDeclaration(&entries), .{ .max_entries = 2 })) {
        .failed => |failure| try std.testing.expectEqual(
            std.meta.Tag(ValidationFailure).capacity_exceeded,
            std.meta.activeTag(failure),
        ),
        .bytes => |bytes| {
            std.testing.allocator.free(bytes);
            return error.ExpectedCapacityFailure;
        },
    }

    const bytes = try expectEncoded(testDeclaration(&entries));
    defer std.testing.allocator.free(bytes);
    var owned = (try decode(std.testing.allocator, bytes, .{})).catalog;
    defer owned.deinit();
    const fingerprint = try owned.view().fingerprint();
    var other = std.crypto.hash.sha2.Sha256.init(.{});
    other.update("incinerator.bundle.identity");
    other.update(bytes[integrity_digest_offset..catalog_name_offset]);
    var bundle_domain: Digest = undefined;
    other.final(&bundle_domain);
    try std.testing.expect(!std.mem.eql(u8, &fingerprint, &bundle_domain));
}
