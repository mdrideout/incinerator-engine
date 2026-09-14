test "EA3 CLI host until durable commit" {
    try @import("main.zig").acceptLightingCLIHost();
}
