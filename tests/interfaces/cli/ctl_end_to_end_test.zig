//! RA8EMU-748, the done condition of RA8EMU-197: a corpus image driven end
//! to end through `ctl --json` only, against a spawned `serve --listen`.
const std = @import("std");
const serve_peer = @import("serve_peer.zig");
const ctl_run = @import("ctl_run.zig");
const Term = std.process.Child.Term;

/// The fixture's vector table base and its first word, the initial stack
/// pointer 0x220fff00, as the little-endian bytes `mem` prints.
const vectors = "0x02000000";
const initial_sp_hex = "00ff0f22";

test "ctl alone loads a corpus image, speeds it up, waits for its banner, checks memory and pauses" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/e2e.sock", .{tmp.sub_path});
    defer gpa.free(path);
    const spec = try std.fmt.allocPrint(gpa, "unix:{s}", .{path});
    defer gpa.free(spec);
    var line: [256]u8 = undefined;
    var served = try serve_peer.listen(spec, &line);
    defer served.child.kill(std.testing.io);

    var loaded = try ctl_run.run(gpa, spec, &.{ "load", ctl_run.uart_image });
    defer loaded.deinit();
    try std.testing.expectEqual(Term{ .exited = 0 }, loaded.term);
    try std.testing.expectEqualStrings(ctl_run.uart_image, loaded.field("loaded").string);

    var fast = try ctl_run.run(gpa, spec, &.{ "speed", "100" });
    defer fast.deinit();
    try std.testing.expectEqual(Term{ .exited = 0 }, fast.term);

    const banner = "uart_irq_echo ready";
    var ready = try ctl_run.stream(gpa, spec, &.{ "events", "--until", banner, "--timeout", "60s" });
    defer ready.deinit(gpa);
    try std.testing.expectEqual(Term{ .exited = 0 }, ready.term);
    try std.testing.expect(std.mem.indexOf(u8, ready.text.items, banner) != null);

    var word = try ctl_run.run(gpa, spec, &.{ "mem", vectors, "4" });
    defer word.deinit();
    try std.testing.expectEqual(Term{ .exited = 0 }, word.term);
    try std.testing.expectEqual(@as(i64, 0x0200_0000), try ctl_run.expectInteger(word.field("address")));
    try std.testing.expectEqualStrings(initial_sp_hex, word.field("hex").string);

    var paused = try ctl_run.run(gpa, spec, &.{"pause"});
    defer paused.deinit();
    try std.testing.expectEqual(Term{ .exited = 0 }, paused.term);
    try std.testing.expect(paused.field("paused").bool);
}
