const std = @import("std");

const ctl_run = @import("../ctl_run.zig");
const paths = @import("test_paths");
const serve_peer = @import("../serve_peer.zig");
const targets = @import("cli_app").target_ctl;

test "target CLI requires stable identity generation disambiguation and known actions" {
    try std.testing.expectEqual(targets.Command.list, try targets.parse(&.{"list"}));
    const cmd = try targets.parse(&.{ "use", "host", "probe", "board", "42", "-", "registers", "step" });
    try std.testing.expectEqual(@as(u64, 42), cmd.use.selection.generation);
    try std.testing.expectEqualStrings("", cmd.use.selection.disambiguation);
    try std.testing.expectEqual(@as(usize, 2), cmd.use.count);
    try std.testing.expectError(error.BadArguments, targets.parse(&.{ "use", "host", "probe", "board", "0", "-", "step" }));
    try std.testing.expectError(error.BadArguments, targets.parse(&.{ "use", "host", "probe", "board", "2", "-", "erase" }));
    try std.testing.expectError(error.BadArguments, targets.parse(&.{"0"}));
}

test "target CLI lists selects operates and releases through a real TCP RPC connection" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const config = "[{\"kind\":\"emulator\",\"target\":{\"managed\":false," ++
        "\"host_id\":\"fixture-host\",\"probe_id\":\"virtual\",\"board_id\":\"emu-a\"," ++
        "\"transport\":\"in-process\",\"identity_verified\":true}}]";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "targets.json", .data = config });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "targets.json", gpa);
    defer gpa.free(path);
    var line: [256]u8 = undefined;
    var served = try serve_peer.listenArgs(&.{ paths.emulator, "serve", "--targets", path, "--listen", "tcp:127.0.0.1:0", serve_peer.image_path }, &line);
    defer served.child.kill(std.testing.io);
    var listing = try ctl_run.run(gpa, served.bound, &.{ "targets", "list" });
    defer listing.deinit();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, listing.term);
    const entries = listing.parsed.value.array.items;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    const generation = entries[0].object.get("generation").?.integer;
    const text = try std.fmt.allocPrint(gpa, "{d}", .{generation});
    defer gpa.free(text);
    var operated = try ctl_run.run(gpa, served.bound, &.{ "targets", "use", "fixture-host", "virtual", "emu-a", text, "-", "registers" });
    defer operated.deinit();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, operated.term);
    try std.testing.expect(operated.field("pc").integer != 0);
    var after = try ctl_run.run(gpa, served.bound, &.{ "targets", "list" });
    defer after.deinit();
    try std.testing.expect(!after.parsed.value.array.items[0].object.get("reserved").?.bool);
    var failed = try ctl_run.run(gpa, served.bound, &.{ "targets", "use", "fixture-host", "virtual", "emu-a", text, "-", "flash" });
    defer failed.deinit();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, failed.term);
    var final = try ctl_run.run(gpa, served.bound, &.{ "targets", "list" });
    defer final.deinit();
    try std.testing.expect(!final.parsed.value.array.items[0].object.get("reserved").?.bool);
}
