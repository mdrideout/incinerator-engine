//! Real product simulation, cooked world and Metal, without a presented window.
const app = @import("main.zig");
test "EA2 offscreen industrial vehicle motion and rendering" {
    try app.acceptVehicleDriving(true);
}
