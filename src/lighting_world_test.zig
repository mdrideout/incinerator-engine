test "EA3 installed industrial lighting and authority isolation" {
    try @import("main.zig").acceptLightingWorld();
}
test "EA3 installed Lighting Lab queued SDL ownership" {
    try @import("main.zig").acceptLightingEditorInput();
}
