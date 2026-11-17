//! ctl syntax and byte-identical forwarding of the backend's annotated lines.
const std = @import("std");

const ctl = @import("cli_app").ctl.disasm;
const fixture = @import("../../../session/annotation_fixture.zig");
const proto = @import("ra8").rpc.session.rpc;
const session_ctl = @import("cli_app").session_ctl;

test "ctl disasm requests a bounded even-address range" {
    const args = &.{ "emu", "ctl", "--connect", "tcp::1234", "disasm", "0x100", "4" };
    const request = try session_ctl.parse(std.testing.allocator, args);
    try std.testing.expectEqual(@as(u32, 0x100), request.command.disasm.address);
    try std.testing.expectEqual(@as(u16, 4), request.command.disasm.count);
    try std.testing.expectError(error.BadArguments, ctl.parse(&.{ "0x101", "1" }));
    try std.testing.expectError(error.BadArguments, ctl.parse(&.{ "0x100", "65" }));
    try std.testing.expectError(error.BadArguments, ctl.parse(&.{ "0x100", "0" }));
}

test "ctl text is exactly the backend annotation transcript and JSON escapes its newlines" {
    var output: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);
    const reply: proto.Disassembly = .{
        .core = .cpu0,
        .count = 4,
        .next = 0x10c,
        .text = fixture.golden,
    };
    try ctl.print(&writer, false, reply);
    try std.testing.expectEqualStrings(fixture.golden, writer.buffered());
    writer.end = 0;
    try ctl.print(&writer, true, reply);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(fixture.golden, parsed.value.object.get("text").?.string);
}
