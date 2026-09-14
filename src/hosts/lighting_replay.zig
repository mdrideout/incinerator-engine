//! Presentation-only reconstruction. Never submits gameplay or authoring commands.
const std = @import("std");
const library = @import("content").lighting_library;
pub const Sample = struct { tick: u64, frame: u64, sequence: u64, asset: std.json.Parsed(library.Library) };
pub const Replay = struct {
    allocator: std.mem.Allocator,
    samples: std.ArrayList(Sample) = .empty,
    cursor: usize = 0,
    current: ?library.Library = null,
    pub fn deinit(self: *Replay) void {
        for (self.samples.items) |*sample| sample.asset.deinit();
        self.samples.deinit(self.allocator);
    }
    pub fn load(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !Replay {
        var result = Replay{ .allocator = allocator };
        errdefer result.deinit();
        var directory = try std.Io.Dir.openDirAbsolute(io, root, .{});
        defer directory.close(io);
        var streams = try directory.openDir(io, "streams", .{ .iterate = true });
        defer streams.close(io);
        var iterator = streams.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "timeline-") or !std.mem.endsWith(u8, entry.name, ".ndjson")) continue;
            const bytes = try streams.readFileAlloc(io, entry.name, allocator, .unlimited);
            defer allocator.free(bytes);
            var lines = std.mem.splitScalar(u8, bytes, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                var generic = try std.json.parseFromSlice(struct { kind: []const u8 }, allocator, line, .{ .ignore_unknown_fields = true });
                defer generic.deinit();
                if (!std.mem.eql(u8, generic.value.kind, "lighting_library")) continue;
                var event = try std.json.parseFromSlice(struct { schema: u16, lighting_schema: u32, authority_tick: u64, presentation_frame: u64, recorder_sequence: u64, sha256: [32]u8 }, allocator, line, .{ .ignore_unknown_fields = true });
                defer event.deinit();
                if (event.value.schema != 6 or event.value.lighting_schema != 1) return error.LightingEvidenceVersionMismatch;
                const path = try std.fmt.allocPrint(allocator, "lighting-assets/{s}.iclight", .{std.fmt.bytesToHex(&event.value.sha256, .lower)});
                defer allocator.free(path);
                const asset_bytes = try directory.readFileAlloc(io, path, allocator, .unlimited);
                defer allocator.free(asset_bytes);
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(asset_bytes, &digest, .{});
                if (!std.mem.eql(u8, &digest, &event.value.sha256)) return error.LightingEvidenceDigestMismatch;
                var asset = try library.decode(allocator, asset_bytes);
                errdefer asset.deinit();
                try result.samples.append(allocator, .{ .tick = event.value.authority_tick, .frame = event.value.presentation_frame, .sequence = event.value.recorder_sequence, .asset = asset });
            }
        }
        if (result.samples.items.len == 0) return error.LightingEvidenceMissing;
        std.mem.sort(Sample, result.samples.items, {}, struct {
            fn less(_: void, a: Sample, b: Sample) bool {
                return a.sequence < b.sequence;
            }
        }.less);
        return result;
    }
    /// Exact at a recorded frame. Graphical re-execution supplies its current
    /// tick/frame; differences in SDL cadence remain explicitly best effort.
    pub fn at(self: *Replay, tick: u64, frame: u64) ?library.Library {
        while (self.cursor < self.samples.items.len) {
            const sample = &self.samples.items[self.cursor];
            if (sample.tick > tick or (sample.tick == tick and sample.frame > frame)) break;
            self.current = sample.asset.value;
            self.cursor += 1;
        }
        return self.current;
    }
};
