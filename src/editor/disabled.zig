//! Compile-time editor stub used by runtime and headless-style builds.

pub const EventRoute = struct {
    keyboard_reserved: bool = false,
    mouse_reserved: bool = false,
};

pub fn init(_: anytype, _: anytype, _: anytype) void {}

pub fn deinit() void {}

pub fn processEvent(_: anytype) EventRoute {
    return .{};
}

pub fn draw(_: anytype, _: anytype, _: anytype) void {}

pub fn wantsMouse() bool {
    return false;
}

pub fn wantsKeyboard() bool {
    return false;
}

pub fn isVisible() bool {
    return false;
}
