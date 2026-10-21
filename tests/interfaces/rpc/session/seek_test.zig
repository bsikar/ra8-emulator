//! The seek request (RA8EMU-1196, slice 17): malformed target text is
//! bad_args, a well-formed target is refused while the execution path is
//! pending, and a host with no transport plane is refused too.
const std = @import("std");
const ra8 = @import("ra8");

const seek = ra8.rpc.session.seek;
const Rig = @import("advance_rig.zig").Rig;

test "a malformed seek target is bad_args" {
    var rig = Rig{};
    try rig.open();
    defer rig.close();
    var plane = ra8.session.transport.Transport{ .session = &rig.session };
    rig.context.transport = &plane;
    const outcome = seek.seek(&rig.context, .{ .target = "1.5ns" });
    switch (outcome) {
        .ok => return error.TestUnexpectedResult,
        .err => |code| try std.testing.expectEqualStrings("bad_args", @tagName(code)),
    }
}

test "a well-formed seek target is refused while execution is pending" {
    var rig = Rig{};
    try rig.open();
    defer rig.close();
    var plane = ra8.session.transport.Transport{ .session = &rig.session };
    rig.context.transport = &plane;
    try std.testing.expect(seek.seek(&rig.context, .{ .target = "0.5s" }) == .err);
}

test "a seek without a transport plane is refused" {
    var rig = Rig{};
    try rig.open();
    defer rig.close();
    try std.testing.expect(seek.seek(&rig.context, .{ .target = "0.5s" }) == .err);
}
