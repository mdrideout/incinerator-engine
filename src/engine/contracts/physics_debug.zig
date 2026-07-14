//! Backend-neutral, bounded physics debug geometry.
//!
//! Producers write into caller-owned storage after a completed simulation tick.
//! Consumers receive only a borrowed immutable view; the view remains valid
//! until the storage is begun again or its backing buffers are released. No
//! allocator, renderer, or physics-backend identifier crosses this boundary.

const std = @import("std");

pub const schema_version: u16 = 1;

/// Runtime policy for renderer-neutral physics evidence.
///
/// Producers may keep any required backend listeners and scratch storage alive
/// independently of this value. Toggling fields only selects which categories
/// are copied into a caller-owned [`Storage`] after a completed step.
pub const Config = struct {
    shapes: bool = true,
    bounds: bool = true,
    contacts: bool = true,
    centers_of_mass: bool = true,
    velocities: bool = true,

    pub fn enabled(self: Config) bool {
        return self.shapes or self.bounds or self.contacts or
            self.centers_of_mass or self.velocities;
    }
};

pub const Position = [3]f32;
/// Opaque RGB color for schema v1.
///
/// The first three lanes are finite renderer-neutral color components. The
/// fourth lane is reserved for a future schema and must be exactly `1.0`; it
/// does not carry alpha or blending semantics in this version.
pub const Color = [4]f32;

/// Stable debug-geometry classes. The category controls filtering and visible
/// capacity accounting; it has no effect on authoritative simulation state.
pub const Category = enum(u8) {
    shape,
    bounds,
    contact,
    center_of_mass,
    velocity,
};

pub const category_count: usize = 5;

/// An optional producer-defined correlation value.
///
/// `kind` is an opaque namespace chosen by the producer and `serial` is its
/// copy-safe logical serial. Neither value is interpreted by this contract.
pub const ObjectRef = struct {
    kind: u32,
    serial: u64,
};

pub const Line = struct {
    category: Category,
    start: Position,
    end: Position,
    color: Color,
    object: ?ObjectRef = null,

    pub fn isValid(self: Line) bool {
        return allFinite(self.start) and
            allFinite(self.end) and
            isValidColor(self.color);
    }
};

pub const Triangle = struct {
    category: Category,
    a: Position,
    b: Position,
    c: Position,
    color: Color,
    object: ?ObjectRef = null,

    pub fn isValid(self: Triangle) bool {
        return allFinite(self.a) and
            allFinite(self.b) and
            allFinite(self.c) and
            isValidColor(self.color);
    }
};

/// Saturating accounting for one primitive type in one category.
///
/// `dropped` is the directly consumable total. Its two reason counters make
/// invalid producer data distinguishable from a correctly bounded overflow.
pub const PrimitiveStats = struct {
    attempted: u64 = 0,
    admitted: u64 = 0,
    dropped: u64 = 0,
    overflow_dropped: u64 = 0,
    invalid_dropped: u64 = 0,
};

pub const CategoryStats = struct {
    lines: PrimitiveStats = .{},
    triangles: PrimitiveStats = .{},
    /// At least one producer for this category was unavailable, so admitted
    /// and dropped primitive counts are necessarily incomplete. This is a
    /// capability signal, not an estimate of an unknowable primitive count.
    source_unavailable: bool = false,
};

/// The non-fallible result of trying to append one primitive.
pub const Admission = enum {
    admitted,
    dropped_overflow,
    dropped_invalid,
    /// `begin` has not established a completed-tick batch yet.
    not_begun,
};

pub const PrimitiveKind = enum {
    line,
    triangle,
};

/// Borrowed read-only geometry for one completed simulation tick.
///
/// The primitive and accounting slices cannot mutate `Storage`. They are
/// invalidated by the next `Storage.begin` call and by release of any backing
/// storage supplied by the caller.
pub const Batch = struct {
    schema: u16,
    completed_tick: u64,
    generation: u64,
    lines: []const Line,
    triangles: []const Triangle,
    category_stats: []const CategoryStats,

    pub fn statsFor(self: Batch, category: Category) CategoryStats {
        return self.category_stats[categoryIndex(category)];
    }
};

/// A bounded writer over caller-owned line and triangle buffers.
///
/// Storage performs no allocation. Call `begin` once after each completed tick,
/// append primitives, then borrow the current batch with `batch`. Capacity is
/// shared within each primitive type; every rejected append is attributed to
/// the category carried by that primitive.
pub const Storage = struct {
    line_storage: []Line,
    triangle_storage: []Triangle,
    line_count: usize = 0,
    triangle_count: usize = 0,
    completed_tick: u64 = 0,
    generation: u64 = 0,
    category_stats: [category_count]CategoryStats = [_]CategoryStats{.{}} ** category_count,

    pub fn init(line_storage: []Line, triangle_storage: []Triangle) Storage {
        return .{
            .line_storage = line_storage,
            .triangle_storage = triangle_storage,
        };
    }

    /// Reset the current contents and establish a new completed-tick batch.
    /// Generations never expose zero, including after integer wraparound.
    pub fn begin(self: *Storage, completed_tick: u64) void {
        self.line_count = 0;
        self.triangle_count = 0;
        self.completed_tick = completed_tick;
        self.generation = nextGeneration(self.generation);
        self.category_stats = [_]CategoryStats{.{}} ** category_count;
    }

    pub fn addLine(self: *Storage, line: Line) Admission {
        if (self.generation == 0) return .not_begun;

        const stats = &self.category_stats[categoryIndex(line.category)].lines;
        saturatingIncrement(&stats.attempted);
        if (!line.isValid()) {
            recordInvalidDrop(stats);
            return .dropped_invalid;
        }
        if (self.line_count == self.line_storage.len) {
            recordOverflowDrop(stats);
            return .dropped_overflow;
        }

        self.line_storage[self.line_count] = line;
        self.line_count += 1;
        saturatingIncrement(&stats.admitted);
        return .admitted;
    }

    pub fn addTriangle(self: *Storage, triangle: Triangle) Admission {
        if (self.generation == 0) return .not_begun;

        const stats = &self.category_stats[categoryIndex(triangle.category)].triangles;
        saturatingIncrement(&stats.attempted);
        if (!triangle.isValid()) {
            recordInvalidDrop(stats);
            return .dropped_invalid;
        }
        if (self.triangle_count == self.triangle_storage.len) {
            recordOverflowDrop(stats);
            return .dropped_overflow;
        }

        self.triangle_storage[self.triangle_count] = triangle;
        self.triangle_count += 1;
        saturatingIncrement(&stats.admitted);
        return .admitted;
    }

    /// Attribute evidence that a bounded producer had to drop before it could
    /// materialize a primitive in this storage (for example, concurrent Jolt
    /// contact scratch saturation). This remains nonfallible and shares the
    /// same visible attempted/drop accounting as a local capacity overflow.
    pub fn recordOverflow(
        self: *Storage,
        category: Category,
        kind: PrimitiveKind,
        count: u64,
    ) bool {
        if (self.generation == 0) return false;
        if (count == 0) return true;
        const stats = switch (kind) {
            .line => &self.category_stats[categoryIndex(category)].lines,
            .triangle => &self.category_stats[categoryIndex(category)].triangles,
        };
        saturatingAdd(&stats.attempted, count);
        saturatingAdd(&stats.dropped, count);
        saturatingAdd(&stats.overflow_dropped, count);
        return true;
    }

    /// Mark a category as only partially observable for this batch.
    ///
    /// This is distinct from overflow: a producer that was never available
    /// cannot truthfully report how many primitives it would have produced.
    pub fn markSourceUnavailable(self: *Storage, category: Category) bool {
        if (self.generation == 0) return false;
        self.category_stats[categoryIndex(category)].source_unavailable = true;
        return true;
    }

    /// Return the current immutable view, or null until the first `begin`.
    pub fn batch(self: *const Storage) ?Batch {
        if (self.generation == 0) return null;
        return .{
            .schema = schema_version,
            .completed_tick = self.completed_tick,
            .generation = self.generation,
            .lines = self.line_storage[0..self.line_count],
            .triangles = self.triangle_storage[0..self.triangle_count],
            .category_stats = &self.category_stats,
        };
    }
};

pub fn saturatingIncrement(value: *u64) void {
    saturatingAdd(value, 1);
}

pub fn saturatingAdd(value: *u64, amount: u64) void {
    const remaining = std.math.maxInt(u64) - value.*;
    value.* = if (amount > remaining)
        std.math.maxInt(u64)
    else
        value.* + amount;
}

fn recordOverflowDrop(stats: *PrimitiveStats) void {
    saturatingIncrement(&stats.dropped);
    saturatingIncrement(&stats.overflow_dropped);
}

fn recordInvalidDrop(stats: *PrimitiveStats) void {
    saturatingIncrement(&stats.dropped);
    saturatingIncrement(&stats.invalid_dropped);
}

fn nextGeneration(current: u64) u64 {
    return if (current == std.math.maxInt(u64)) 1 else current + 1;
}

fn categoryIndex(category: Category) usize {
    return @intFromEnum(category);
}

fn allFinite(values: anytype) bool {
    for (values) |value| {
        if (!std.math.isFinite(value)) return false;
    }
    return true;
}

fn isValidColor(color: Color) bool {
    return allFinite(color) and color[3] == 1.0;
}

fn sampleLine(category: Category) Line {
    return .{
        .category = category,
        .start = .{ 0, 1, 2 },
        .end = .{ 3, 4, 5 },
        .color = .{ 0.25, 0.5, 0.75, 1 },
        .object = .{ .kind = 7, .serial = 19 },
    };
}

fn sampleTriangle(category: Category) Triangle {
    return .{
        .category = category,
        .a = .{ 0, 0, 0 },
        .b = .{ 1, 0, 0 },
        .c = .{ 0, 1, 0 },
        .color = .{ 1, 0.5, 0.25, 1 },
    };
}

test "non-finite geometry and non-opaque schema v1 colors are rejected visibly" {
    var lines: [3]Line = undefined;
    var triangles: [2]Triangle = undefined;
    var storage = Storage.init(&lines, &triangles);
    storage.begin(4);

    var invalid_line = sampleLine(.velocity);
    invalid_line.end[1] = std.math.nan(f32);
    try std.testing.expectEqual(Admission.dropped_invalid, storage.addLine(invalid_line));

    var invalid_triangle = sampleTriangle(.contact);
    invalid_triangle.color[2] = std.math.inf(f32);
    try std.testing.expectEqual(Admission.dropped_invalid, storage.addTriangle(invalid_triangle));

    var non_opaque_line = sampleLine(.shape);
    non_opaque_line.color[3] = 0.5;
    try std.testing.expectEqual(Admission.dropped_invalid, storage.addLine(non_opaque_line));

    const batch = storage.batch().?;
    try std.testing.expectEqual(@as(usize, 0), batch.lines.len);
    try std.testing.expectEqual(@as(usize, 0), batch.triangles.len);
    try std.testing.expectEqual(@as(u64, 1), batch.statsFor(.velocity).lines.attempted);
    try std.testing.expectEqual(@as(u64, 1), batch.statsFor(.velocity).lines.dropped);
    try std.testing.expectEqual(@as(u64, 1), batch.statsFor(.velocity).lines.invalid_dropped);
    try std.testing.expectEqual(@as(u64, 0), batch.statsFor(.velocity).lines.overflow_dropped);
    try std.testing.expectEqual(@as(u64, 1), batch.statsFor(.contact).triangles.invalid_dropped);
    try std.testing.expectEqual(@as(u64, 1), batch.statsFor(.shape).lines.invalid_dropped);
}

test "debug category policy reports whether extraction is enabled" {
    try std.testing.expect((Config{}).enabled());
    try std.testing.expect(!(Config{
        .shapes = false,
        .bounds = false,
        .contacts = false,
        .centers_of_mass = false,
        .velocities = false,
    }).enabled());
}

test "capacity drops are attributed independently by category and primitive type" {
    var lines: [1]Line = undefined;
    var triangles: [1]Triangle = undefined;
    var storage = Storage.init(&lines, &triangles);
    storage.begin(7);

    try std.testing.expectEqual(Admission.admitted, storage.addLine(sampleLine(.shape)));
    try std.testing.expectEqual(Admission.dropped_overflow, storage.addLine(sampleLine(.bounds)));
    try std.testing.expectEqual(Admission.admitted, storage.addTriangle(sampleTriangle(.bounds)));
    try std.testing.expectEqual(Admission.dropped_overflow, storage.addTriangle(sampleTriangle(.contact)));

    const batch = storage.batch().?;
    try std.testing.expectEqual(@as(u64, 1), batch.statsFor(.shape).lines.admitted);
    try std.testing.expectEqual(@as(u64, 1), batch.statsFor(.bounds).lines.attempted);
    try std.testing.expectEqual(@as(u64, 1), batch.statsFor(.bounds).lines.dropped);
    try std.testing.expectEqual(@as(u64, 1), batch.statsFor(.bounds).lines.overflow_dropped);
    try std.testing.expectEqual(@as(u64, 1), batch.statsFor(.bounds).triangles.admitted);
    try std.testing.expectEqual(@as(u64, 1), batch.statsFor(.contact).triangles.overflow_dropped);
}

test "batch exposes borrowed immutable primitive and accounting views" {
    var lines: [1]Line = undefined;
    var triangles: [1]Triangle = undefined;
    var storage = Storage.init(&lines, &triangles);
    try std.testing.expectEqual(Admission.not_begun, storage.addLine(sampleLine(.shape)));
    try std.testing.expect(storage.batch() == null);

    storage.begin(11);
    try std.testing.expectEqual(Admission.admitted, storage.addLine(sampleLine(.center_of_mass)));
    try std.testing.expectEqual(Admission.admitted, storage.addTriangle(sampleTriangle(.shape)));

    const batch = storage.batch().?;
    try std.testing.expectEqual(schema_version, batch.schema);
    try std.testing.expectEqual(@as(u64, 11), batch.completed_tick);
    try std.testing.expect(batch.generation != 0);
    try std.testing.expectEqual(@as(usize, 1), batch.lines.len);
    try std.testing.expectEqual(@as(usize, 1), batch.triangles.len);
    try std.testing.expectEqual(Category.center_of_mass, batch.lines[0].category);
    try std.testing.expectEqual(ObjectRef{ .kind = 7, .serial = 19 }, batch.lines[0].object.?);
    try std.testing.expect(@typeInfo(@TypeOf(batch.lines)).pointer.is_const);
    try std.testing.expect(@typeInfo(@TypeOf(batch.triangles)).pointer.is_const);
    try std.testing.expect(@typeInfo(@TypeOf(batch.category_stats)).pointer.is_const);
}

test "begin resets contents and accounting while advancing tick and generation" {
    var lines: [1]Line = undefined;
    var triangles: [1]Triangle = undefined;
    var storage = Storage.init(&lines, &triangles);
    storage.begin(21);
    _ = storage.addLine(sampleLine(.shape));
    const first_generation = storage.batch().?.generation;

    storage.begin(22);
    const second = storage.batch().?;
    try std.testing.expectEqual(@as(u64, 22), second.completed_tick);
    try std.testing.expectEqual(first_generation + 1, second.generation);
    try std.testing.expectEqual(@as(usize, 0), second.lines.len);
    try std.testing.expectEqual(@as(usize, 0), second.triangles.len);
    try std.testing.expectEqual(PrimitiveStats{}, second.statsFor(.shape).lines);

    storage.generation = std.math.maxInt(u64);
    storage.begin(23);
    try std.testing.expectEqual(@as(u64, 1), storage.batch().?.generation);
}

test "counter helpers saturate without wrapping" {
    var value: u64 = std.math.maxInt(u64) - 2;
    saturatingAdd(&value, 1);
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, value);
    saturatingAdd(&value, 9);
    try std.testing.expectEqual(std.math.maxInt(u64), value);
    saturatingIncrement(&value);
    try std.testing.expectEqual(std.math.maxInt(u64), value);
}

test "producer-side overflow is attributed after begin" {
    var lines: [0]Line = undefined;
    var triangles: [0]Triangle = undefined;
    var storage = Storage.init(&lines, &triangles);
    try std.testing.expect(!storage.recordOverflow(.contact, .line, 4));
    storage.begin(3);
    try std.testing.expect(storage.recordOverflow(.contact, .line, 4));
    try std.testing.expect(storage.recordOverflow(.shape, .triangle, 0));
    const batch = storage.batch().?;
    try std.testing.expectEqual(@as(u64, 4), batch.statsFor(.contact).lines.attempted);
    try std.testing.expectEqual(@as(u64, 4), batch.statsFor(.contact).lines.dropped);
    try std.testing.expectEqual(@as(u64, 4), batch.statsFor(.contact).lines.overflow_dropped);
    try std.testing.expectEqual(PrimitiveStats{}, batch.statsFor(.shape).triangles);
}

test "source unavailability is visible without inventing primitive counts" {
    var lines: [0]Line = undefined;
    var triangles: [0]Triangle = undefined;
    var storage = Storage.init(&lines, &triangles);
    try std.testing.expect(!storage.markSourceUnavailable(.contact));

    storage.begin(9);
    try std.testing.expect(storage.markSourceUnavailable(.contact));
    const unavailable = storage.batch().?;
    try std.testing.expect(unavailable.statsFor(.contact).source_unavailable);
    try std.testing.expectEqual(PrimitiveStats{}, unavailable.statsFor(.contact).lines);
    try std.testing.expectEqual(PrimitiveStats{}, unavailable.statsFor(.contact).triangles);

    storage.begin(10);
    try std.testing.expect(!storage.batch().?.statsFor(.contact).source_unavailable);
}
