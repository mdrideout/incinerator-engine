//! Narrow capability contracts used by InteractionFeature.
//!
//! The interaction slice may observe and transition only the carrier state
//! exported by CharacterFeature and the exact active residency exported by
//! DistrictFeature. Neither private ECS components nor backend handles cross
//! these boundaries.

const std = @import("std");
const engine = @import("incinerator_engine");
const district_contract = @import("district_contract");

pub const CarrierMobility = enum {
    on_foot,
    driving,
};

pub const CarryMode = union(enum) {
    empty,
    holding: engine.PersistentId,
};

/// Authoritative, read-only carrier state. The persistent holder/item
/// relationship is owned and serialized by InteractionFeature; this value is
/// the narrow runtime capability used to keep CharacterFeature consistent.
pub const CarryState = struct {
    pose: engine.physics.Pose,
    mobility: CarrierMobility,
    carry_mode: CarryMode,

    pub fn validate(self: CarryState) !void {
        try self.pose.validate();
        switch (self.carry_mode) {
            .empty => {},
            .holding => |item_id| try item_id.validate(),
        }
        if (self.mobility == .driving and self.carry_mode != .empty) {
            return error.DrivingCarrierCannotHoldItem;
        }
    }

    pub fn heldItem(self: CarryState) ?engine.PersistentId {
        return switch (self.carry_mode) {
            .empty => null,
            .holding => |item_id| item_id,
        };
    }
};

/// Validate the structural character capability consumed by
/// InteractionFeature.
///
/// `beginCarry` and `endCarry` are atomic: an error leaves the prior state
/// unchanged. `cancelBeginCarry` is the infallible inverse of the immediately
/// preceding successful `beginCarry`; it is reserved for transaction rollback
/// when a later collect step fails.
pub fn assertCarrierImplementation(comptime CarrierAccess: type) void {
    comptime {
        assertFallibleMethod(
            CarrierAccess,
            "carryState",
            .{ *CarrierAccess, engine.PersistentId },
            ?CarryState,
        );
        assertFallibleMethod(
            CarrierAccess,
            "beginCarry",
            .{ *CarrierAccess, engine.PersistentId, engine.PersistentId },
            void,
        );
        assertFallibleMethod(
            CarrierAccess,
            "endCarry",
            .{ *CarrierAccess, engine.PersistentId, engine.PersistentId },
            void,
        );
        assertInfallibleMethod(
            CarrierAccess,
            "cancelBeginCarry",
            .{ *CarrierAccess, engine.PersistentId, engine.PersistentId },
            void,
        );
    }
}

/// Validate the exact-residency capability consumed by InteractionFeature.
/// A non-null result means this precise coordinate is authoritative and
/// active at the time of the owner-thread query.
pub fn assertDistrictImplementation(comptime DistrictAccess: type) void {
    comptime {
        assertInfallibleMethod(
            DistrictAccess,
            "activeTicketFor",
            .{ *DistrictAccess, district_contract.ChunkCoord },
            ?district_contract.LoadTicket,
        );
    }
}

fn assertInfallibleMethod(
    comptime Access: type,
    comptime name: []const u8,
    comptime expected_params: anytype,
    comptime expected_return: type,
) void {
    if (!@hasDecl(Access, name)) {
        @compileError("interaction access implementation is missing " ++ name);
    }
    const method = switch (@typeInfo(@TypeOf(@field(Access, name)))) {
        .@"fn" => |info| info,
        else => @compileError("interaction access declaration " ++ name ++ " must be a function"),
    };
    if (method.params.len != expected_params.len) {
        @compileError("interaction access method " ++ name ++ " has the wrong parameter count");
    }
    inline for (expected_params, 0..) |expected, index| {
        const actual = method.params[index].type orelse
            @compileError("interaction access method " ++ name ++ " cannot use an anytype parameter");
        if (actual != expected) {
            @compileError("interaction access method " ++ name ++ " has an incompatible parameter");
        }
    }
    if (method.return_type == null or method.return_type.? != expected_return) {
        @compileError("interaction access method " ++ name ++ " has an incompatible return type");
    }
}

fn assertFallibleMethod(
    comptime Access: type,
    comptime name: []const u8,
    comptime expected_params: anytype,
    comptime expected_payload: type,
) void {
    if (!@hasDecl(Access, name)) {
        @compileError("interaction access implementation is missing " ++ name);
    }
    const method = switch (@typeInfo(@TypeOf(@field(Access, name)))) {
        .@"fn" => |info| info,
        else => @compileError("interaction access declaration " ++ name ++ " must be a function"),
    };
    if (method.params.len != expected_params.len) {
        @compileError("interaction access method " ++ name ++ " has the wrong parameter count");
    }
    inline for (expected_params, 0..) |expected, index| {
        const actual = method.params[index].type orelse
            @compileError("interaction access method " ++ name ++ " cannot use an anytype parameter");
        if (actual != expected) {
            @compileError("interaction access method " ++ name ++ " has an incompatible parameter");
        }
    }
    const return_type = method.return_type orelse
        @compileError("interaction access method " ++ name ++ " must have a return type");
    const payload = switch (@typeInfo(return_type)) {
        .error_union => |info| info.payload,
        else => @compileError("interaction access method " ++ name ++ " must return an error union"),
    };
    if (payload != expected_payload) {
        @compileError("interaction access method " ++ name ++ " has an incompatible return payload");
    }
}

const CarrierExample = struct {
    pub fn carryState(_: *CarrierExample, _: engine.PersistentId) !?CarryState {
        return .{ .pose = .{}, .mobility = .on_foot, .carry_mode = .empty };
    }

    pub fn beginCarry(
        _: *CarrierExample,
        _: engine.PersistentId,
        _: engine.PersistentId,
    ) !void {}

    pub fn endCarry(
        _: *CarrierExample,
        _: engine.PersistentId,
        _: engine.PersistentId,
    ) !void {}

    pub fn cancelBeginCarry(
        _: *CarrierExample,
        _: engine.PersistentId,
        _: engine.PersistentId,
    ) void {}
};

const DistrictExample = struct {
    pub fn activeTicketFor(
        _: *DistrictExample,
        _: district_contract.ChunkCoord,
    ) ?district_contract.LoadTicket {
        return null;
    }
};

test "interaction capability examples satisfy their structural ports" {
    comptime assertCarrierImplementation(CarrierExample);
    comptime assertDistrictImplementation(DistrictExample);
}

test "carry state validates pose identity and cross-mode invariant" {
    try (CarryState{
        .pose = .{},
        .mobility = .on_foot,
        .carry_mode = .{ .holding = .{ .namespace = 1, .local = 2 } },
    }).validate();
    try std.testing.expectError(
        error.DrivingCarrierCannotHoldItem,
        (CarryState{
            .pose = .{},
            .mobility = .driving,
            .carry_mode = .{ .holding = .{ .namespace = 1, .local = 2 } },
        }).validate(),
    );
}
