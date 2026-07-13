//! Gameplay-neutral port used by the vehicle slice to transfer control
//! to and from a character without importing CharacterFeature internals.

const std = @import("std");
const engine = @import("incinerator_engine");

pub const DriverMode = union(enum) {
    on_foot,
    driving: engine.PersistentId,
};

pub const DriverState = struct {
    pose: engine.physics.Pose,
    mode: DriverMode,
    /// Feature-neutral eligibility projection. The driver slice owns the
    /// relationship; VehicleFeature only needs to know whether entering a
    /// vehicle would conflict with an already-held persistent object.
    carried_item: ?engine.PersistentId = null,

    pub fn validate(self: DriverState) !void {
        try self.pose.validate();
        switch (self.mode) {
            .on_foot => {},
            .driving => |vehicle_id| {
                try vehicle_id.validate();
                if (self.carried_item != null) {
                    return error.DriverCannotCarryWhileDriving;
                }
            },
        }
        if (self.carried_item) |item_id| try item_id.validate();
    }
};

/// `blocked` is an expected domain result. Adapter/controller failures remain
/// errors and leave the relationship unchanged.
pub const ExitDisposition = enum {
    exited,
    blocked,
};

/// Validate the structural port consumed by VehicleFeature.
///
/// Implementations guarantee that begin/exit transitions are atomic: an error
/// or `.blocked` result leaves the driver's prior mode and pose unchanged.
/// `cancelDriving` is the infallible inverse of the immediately preceding
/// successful `beginDriving`: it restores every driver value mutated by begin,
/// not only the mode. It is reserved for candidate-world transaction rollback;
/// normal gameplay must use `attemptEndDriving`.
pub fn assertImplementation(comptime DriverAccess: type) void {
    comptime {
        assertFallibleMethod(
            DriverAccess,
            "driverState",
            .{ *DriverAccess, engine.PersistentId },
            ?DriverState,
        );
        assertFallibleMethod(
            DriverAccess,
            "beginDriving",
            .{ *DriverAccess, engine.PersistentId, engine.PersistentId },
            void,
        );
        assertFallibleMethod(
            DriverAccess,
            "attemptEndDriving",
            .{
                *DriverAccess,
                engine.PersistentId,
                engine.PersistentId,
                engine.physics.Pose,
            },
            ExitDisposition,
        );
        assertInfallibleMethod(
            DriverAccess,
            "cancelDriving",
            .{ *DriverAccess, engine.PersistentId, engine.PersistentId },
            void,
        );
    }
}

fn assertInfallibleMethod(
    comptime DriverAccess: type,
    comptime name: []const u8,
    comptime expected_params: anytype,
    comptime expected_return: type,
) void {
    if (!@hasDecl(DriverAccess, name)) {
        @compileError("driver access implementation is missing " ++ name);
    }
    const method = switch (@typeInfo(@TypeOf(@field(DriverAccess, name)))) {
        .@"fn" => |info| info,
        else => @compileError("driver access declaration " ++ name ++ " must be a function"),
    };
    if (method.params.len != expected_params.len) {
        @compileError("driver access method " ++ name ++ " has the wrong parameter count");
    }
    inline for (expected_params, 0..) |expected, index| {
        const actual = method.params[index].type orelse
            @compileError("driver access method " ++ name ++ " cannot use an anytype parameter");
        if (actual != expected) {
            @compileError("driver access method " ++ name ++ " has an incompatible parameter");
        }
    }
    if (method.return_type == null or method.return_type.? != expected_return) {
        @compileError("driver access method " ++ name ++ " has an incompatible return type");
    }
}

fn assertFallibleMethod(
    comptime DriverAccess: type,
    comptime name: []const u8,
    comptime expected_params: anytype,
    comptime expected_payload: type,
) void {
    if (!@hasDecl(DriverAccess, name)) {
        @compileError("driver access implementation is missing " ++ name);
    }

    const method_type = @TypeOf(@field(DriverAccess, name));
    const method = switch (@typeInfo(method_type)) {
        .@"fn" => |info| info,
        else => @compileError("driver access declaration " ++ name ++ " must be a function"),
    };
    if (method.params.len != expected_params.len) {
        @compileError("driver access method " ++ name ++ " has the wrong parameter count");
    }
    inline for (expected_params, 0..) |expected, index| {
        const actual = method.params[index].type orelse
            @compileError("driver access method " ++ name ++ " cannot use an anytype parameter");
        if (actual != expected) {
            @compileError("driver access method " ++ name ++ " has an incompatible parameter");
        }
    }

    const return_type = method.return_type orelse
        @compileError("driver access method " ++ name ++ " must have a return type");
    const return_payload = switch (@typeInfo(return_type)) {
        .error_union => |info| info.payload,
        else => @compileError("driver access method " ++ name ++ " must return an error union"),
    };
    if (return_payload != expected_payload) {
        @compileError("driver access method " ++ name ++ " has an incompatible return payload");
    }
}

const ContractExample = struct {
    pub fn driverState(_: *ContractExample, _: engine.PersistentId) !?DriverState {
        return .{ .pose = .{}, .mode = .on_foot };
    }

    pub fn beginDriving(
        _: *ContractExample,
        _: engine.PersistentId,
        _: engine.PersistentId,
    ) !void {}

    pub fn attemptEndDriving(
        _: *ContractExample,
        _: engine.PersistentId,
        _: engine.PersistentId,
        _: engine.physics.Pose,
    ) !ExitDisposition {
        return .exited;
    }

    pub fn cancelDriving(
        _: *ContractExample,
        _: engine.PersistentId,
        _: engine.PersistentId,
    ) void {}
};

test "driver access example satisfies the structural port" {
    comptime assertImplementation(ContractExample);
}

test "driver state validates its pose and driving identity" {
    try (DriverState{ .pose = .{}, .mode = .on_foot }).validate();
    try (DriverState{
        .pose = .{},
        .mode = .on_foot,
        .carried_item = .{ .namespace = 1, .local = 2 },
    }).validate();
    try (DriverState{
        .pose = .{},
        .mode = .{ .driving = .{ .namespace = 1, .local = 1 } },
    }).validate();
    try std.testing.expectError(
        error.DriverCannotCarryWhileDriving,
        (DriverState{
            .pose = .{},
            .mode = .{ .driving = .{ .namespace = 1, .local = 1 } },
            .carried_item = .{ .namespace = 1, .local = 2 },
        }).validate(),
    );
}
