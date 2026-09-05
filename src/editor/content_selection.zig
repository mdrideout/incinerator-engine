//! Editor-local selection for cooked content assets.
//!
//! Asset selection is deliberately separate from world-instance selection:
//! choosing a material never deselects a runtime crate, NPC, or vehicle.

const std = @import("std");
const engine = @import("incinerator_engine");

pub const Id = engine.assets.AssetId;

pub const View = struct {
    entries: []const engine.assets.Entry,
    active: ?Id,

    pub fn activeEntry(self: View) ?*const engine.assets.Entry {
        const id = self.active orelse return null;
        for (self.entries) |*entry| if (std.meta.eql(entry.id, id)) return entry;
        return null;
    }
};

pub const Request = union(enum) { select: Id, clear };

pub const Requests = struct {
    values: [8]Request = undefined,
    count: u8 = 0,
    rejected: u64 = 0,

    pub fn submit(self: *Requests, request: Request) void {
        if (self.count == self.values.len) {
            self.rejected +|= 1;
            return;
        }
        self.values[self.count] = request;
        self.count += 1;
    }

    pub fn clear(self: *Requests) void {
        self.count = 0;
    }
};

pub const Controller = struct {
    active: ?Id = null,

    pub fn view(self: *const Controller, entries: []const engine.assets.Entry) View {
        return .{ .entries = entries, .active = self.active };
    }

    pub fn apply(self: *Controller, entries: []const engine.assets.Entry, requests: *Requests) bool {
        const before = self.active;
        for (requests.values[0..requests.count]) |request| switch (request) {
            .clear => self.active = null,
            .select => |id| {
                for (entries) |entry| if (std.meta.eql(entry.id, id)) {
                    self.active = id;
                    break;
                };
            },
        };
        requests.clear();
        return !optionalEql(before, self.active);
    }
};

fn optionalEql(first: ?Id, second: ?Id) bool {
    if (first == null or second == null) return first == null and second == null;
    return std.meta.eql(first.?, second.?);
}

test "content selection does not share world entity identity storage" {
    try std.testing.expect(!@hasField(Controller, "world_selection"));
    var controller = Controller{};
    var requests = Requests{};
    var digest: engine.assets.Digest = @splat(0);
    digest[0] = 1;
    const entry = engine.assets.Entry{
        .id = try engine.assets.deriveGameAssetId(.mesh, "district/test", "Mesh"),
        .kind = .mesh,
        .owner = .game,
        .label = "Mesh",
        .bundle_key = "district/test",
        .revision = 1,
        .digest = digest,
        .dependencies = &.{},
        .source_format = .gltf,
        .cook_status = .valid,
        .residency = .not_resident,
        .last_use_frame = null,
        .details = .mesh,
    };
    requests.submit(.{ .select = entry.id });
    try std.testing.expect(controller.apply(&.{entry}, &requests));
    try std.testing.expectEqual(entry.id, controller.active.?);
}
