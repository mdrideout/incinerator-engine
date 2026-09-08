//! Explicit, attention-taking native acceptance. Never imported by the default suite.
const app = @import("main.zig");
test "EA2 native industrial drive uses admitted cooked vehicle and player controls" {
    try app.acceptVehicleDriving(false);
}
test "developer endpoint app boundary routes a concrete owner journey" {
    try app.acceptDeveloperOwnerJourney();
}
test "developer endpoint app boundary exposes typed admitted assets and independent content selection" {
    try app.acceptDeveloperAssets();
}
