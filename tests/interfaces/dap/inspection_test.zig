const std = @import("std");
const fixture = @import("fixture.zig");

test "stop handles read Session registers and expire on resume" {
    var f: fixture.Fixture = .{};
    try f.init();
    defer f.deinit();
    try fixture.connect(&f.adapter);
    try f.session.setRegister(.cpu0, .r0, 42);
    // Attach advanced the handle epoch to 2: frame 128, registers 256.
    try fixture.expectSend(&f.adapter,
        \\{"seq":4,"type":"request","command":"scopes","arguments":{"frameId":128}}
    , "\"variablesReference\":256");
    try fixture.expectSend(&f.adapter,
        \\{"seq":5,"type":"request","command":"variables","arguments":{"variablesReference":256}}
    , "0x0000002A");
    try fixture.expectSend(&f.adapter,
        \\{"seq":6,"type":"request","command":"stepIn","arguments":{"threadId":1}}
    , "\"success\":true");
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try f.adapter.pump(&out.writer);
    try fixture.expectSend(&f.adapter,
        \\{"seq":7,"type":"request","command":"variables","arguments":{"variablesReference":256}}
    , "InvalidReference");
    try fixture.expectSend(&f.adapter,
        \\{"seq":8,"type":"request","command":"stackTrace","arguments":{"threadId":1,"startFrame":100}}
    , "\"stackFrames\":[]");
}
