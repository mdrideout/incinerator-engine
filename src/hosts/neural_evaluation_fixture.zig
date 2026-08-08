//! Deterministic presentation-only geometry used by NR0-D failure analysis.
//!
//! The fixture creates no gameplay, physics, ECS, navigation, or replication
//! state. Its plans are immutable draws consumed by the ordinary product and
//! neural-input presentation paths.

const std = @import("std");
const contract = @import("incinerator_engine").neural_rendering;

pub const source_fingerprint =
    "nr0-d-fixture-v1|rigid-edges|thin-features|small-objects|depth-layers|" ++
    "moving-occluder|rotating-parts|stable-identities";

pub const center = [3]f32{ 26, 2.5, 0 };
pub const fixture_identity_base: u64 = 0x4e52_3044_0000_0000;

pub fn contentDigest() [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(source_fingerprint);
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

pub const MeshKind = enum {
    cube,
    checker_cube,
    wheel,
    capsule,
};

pub const Draw = struct {
    identity: contract.DrawIdentity,
    mesh: MeshKind,
    scale: [3]f32,
    rotation: [3]f32 = .{ 0, 0, 0 },
    position: [3]f32,
    base_color: [4]f32 = .{ 1, 1, 1, 1 },
};

pub const draw_count = 23;

pub fn plans(presentation_frame: u64) [draw_count]Draw {
    const frame: f32 = @floatFromInt(presentation_frame);
    const occluder_x = center[0] + @sin(frame * 0.035) * 7.5;
    const blade_angle = frame * 0.055;
    const wheel_angle = frame * 0.09;
    return .{
        draw(1, .cube, .{ 16, 0.25, 0.25 }, .{ center[0], 0.35, -7.5 }),
        draw(2, .cube, .{ 0.25, 5.5, 0.25 }, .{ center[0] - 8, 2.85, -7.5 }),
        draw(3, .cube, .{ 0.25, 5.5, 0.25 }, .{ center[0] + 8, 2.85, -7.5 }),
        draw(4, .checker_cube, .{ 5.5, 0.35, 5.5 }, .{ center[0] - 5.5, 0.3, 0 }),
        draw(5, .cube, .{ 5.5, 0.35, 5.5 }, .{ center[0] + 5.5, 0.3, 0 }),

        draw(6, .cube, .{ 0.12, 4.5, 0.12 }, .{ center[0] - 6.0, 2.4, -3.5 }),
        draw(7, .cube, .{ 0.2, 4.5, 0.2 }, .{ center[0] - 4.5, 2.4, -3.5 }),
        draw(8, .cube, .{ 0.35, 4.5, 0.35 }, .{ center[0] - 2.8, 2.4, -3.5 }),
        draw(9, .cube, .{ 4.8, 0.1, 0.16 }, .{ center[0] + 4.8, 4.7, -3.5 }),

        draw(10, .checker_cube, .{ 0.18, 0.18, 0.18 }, .{ center[0] - 6.0, 0.55, 4.5 }),
        draw(11, .checker_cube, .{ 0.3, 0.3, 0.3 }, .{ center[0] - 4.5, 0.61, 4.5 }),
        draw(12, .checker_cube, .{ 0.5, 0.5, 0.5 }, .{ center[0] - 2.8, 0.71, 4.5 }),
        draw(13, .checker_cube, .{ 0.8, 0.8, 0.8 }, .{ center[0] - 0.8, 0.86, 4.5 }),

        draw(14, .cube, .{ 3.2, 1.4, 0.8 }, .{ center[0] - 5.5, 1.0, 7.5 }),
        draw(15, .cube, .{ 3.2, 2.6, 0.8 }, .{ center[0], 1.6, 10.5 }),
        draw(16, .cube, .{ 3.2, 3.8, 0.8 }, .{ center[0] + 5.5, 2.2, 13.5 }),

        .{
            .identity = identity(17, .environment, .whole),
            .mesh = .cube,
            .scale = .{ 0.65, 6.5, 5.5 },
            .position = .{ occluder_x, 3.35, 1.2 },
            .base_color = .{ 0.7, 0.82, 1.0, 1 },
        },
        .{
            .identity = identity(18, .environment, .whole),
            .mesh = .cube,
            .scale = .{ 6.5, 0.16, 0.5 },
            .rotation = .{ 0, blade_angle, 0 },
            .position = .{ center[0], 2.7, 1.2 },
            .base_color = .{ 1.0, 0.72, 0.25, 1 },
        },
        .{
            .identity = identity(19, .vehicle, .vehicle_wheel_front_left),
            .mesh = .wheel,
            .scale = .{ 0.55, 1.2, 1.2 },
            .rotation = .{ wheel_angle, 0, 0 },
            .position = .{ center[0] - 2.2, 1.0, -0.8 },
        },
        .{
            .identity = identity(20, .vehicle, .vehicle_wheel_front_right),
            .mesh = .wheel,
            .scale = .{ 0.55, 1.2, 1.2 },
            .rotation = .{ wheel_angle, 0, 0 },
            .position = .{ center[0] + 2.2, 1.0, -0.8 },
        },
        .{
            .identity = identity(21, .character, .whole),
            .mesh = .capsule,
            .scale = .{ 0.7, 0.7, 0.7 },
            .position = .{ center[0] - 2.8, 0.25, 2.3 },
            .base_color = .{ 0.35, 1.0, 0.45, 1 },
        },
        .{
            .identity = identity(22, .npc, .whole),
            .mesh = .capsule,
            .scale = .{ 0.45, 0.45, 0.45 },
            .position = .{ center[0] + 2.7, 0.25, 2.8 },
            .base_color = .{ 1.0, 0.3, 0.25, 1 },
        },
        .{
            .identity = identity(23, .crate, .whole),
            .mesh = .checker_cube,
            .scale = .{ 1.1, 1.1, 1.1 },
            .rotation = .{ 0, frame * 0.02, 0 },
            .position = .{ center[0], 0.85, 6.4 },
        },
    };
}

fn draw(
    ordinal: u16,
    mesh: MeshKind,
    scale: [3]f32,
    position: [3]f32,
) Draw {
    return .{
        .identity = identity(ordinal, .environment, .whole),
        .mesh = mesh,
        .scale = scale,
        .position = position,
    };
}

fn identity(
    ordinal: u16,
    semantic: contract.SemanticClass,
    part: contract.SemanticPart,
) contract.DrawIdentity {
    return .{
        .identity = .{ .fixture = fixture_identity_base + ordinal },
        .semantic = semantic,
        .part = part,
    };
}

test "fixture plans retain exact stable identities while animated transforms change" {
    const first = plans(100);
    const later = plans(140);
    try std.testing.expectEqual(@as(usize, draw_count), first.len);
    for (first, later, 0..) |a, b, index| {
        try std.testing.expectEqual(a.identity.stableKey(), b.identity.stableKey());
        for (first[index + 1 ..]) |other| {
            try std.testing.expect(a.identity.stableKey() != other.identity.stableKey());
        }
    }
    try std.testing.expect(!std.meta.eql(first[16].position, later[16].position));
    try std.testing.expect(first[17].rotation[1] != later[17].rotation[1]);
}

test "fixture fingerprint declares only represented pressure" {
    try std.testing.expect(std.mem.indexOf(u8, source_fingerprint, "thin-features") != null);
    try std.testing.expect(std.mem.indexOf(u8, source_fingerprint, "metallic") == null);
    try std.testing.expect(std.mem.indexOf(u8, source_fingerprint, "volumetric") == null);
    const digest = contentDigest();
    const zero_digest = [_]u8{0} ** 32;
    try std.testing.expect(!std.mem.eql(u8, &digest, &zero_digest));
}
