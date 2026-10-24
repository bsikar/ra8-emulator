const std = @import("std");
const ra8 = @import("ra8");
const fakes = @import("../history_fakes.zig");
const file = ra8.snapshot.file;
const elf_path = "tests/fixtures/dfu/dfu_bootloader.elf";

fn save(opened: *ra8.session.harness.Harness, gpa: std.mem.Allocator) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try opened.state.files.writeTo(&w.writer);
    return gpa.dupe(u8, w.written());
}

fn report(prev: []const u8, cur: []const u8) !void {
    var a = try file.Reader.open(prev);
    var b = try file.Reader.open(cur);
    while (try a.next()) |sa| {
        const sb = (try b.next()).?;
        if (!std.mem.eql(u8, sa.payload, sb.payload)) std.debug.print("  changed {s} len {d}->{d}\n", .{ @tagName(sa.kind), sa.payload.len, sb.payload.len });
    }
}

test "probe save stream" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var sink: fakes.Sink = .{ .gpa = gpa };
    defer sink.deinit();
    var objects: fakes.Objects = .{ .gpa = gpa };
    defer objects.deinit();
    var opened = try ra8.session.harness.open(gpa, io, .{
        .elf_path = elf_path,
        .checkpoint_every = 1,
        .history_storage = sink.storage(),
        .history_objects = objects.objects(),
    });
    defer opened.deinit();
    const session = opened.session();
    try session.setRunBudget(.cpu0, 1000);
    _ = try session.run(.cpu0, .cont);
    try session.setRunBudget(.cpu0, 1);
    var prev = try save(&opened, gpa);
    defer gpa.free(prev);
    {
        var r = try file.Reader.open(prev);
        while (try r.next()) |s| std.debug.print("section {s} {d}\n", .{ @tagName(s.kind), s.payload.len });
    }
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const e = try session.run(.cpu0, .cont);
        const cur = try save(&opened, gpa);
        std.debug.print("step {d} ended={any} pos={any}\n", .{ i, e, session.grid.?.at });
        try report(prev, cur);
        gpa.free(prev);
        prev = cur;
        if (i == 5) try session.setRunBudget(.cpu0, 20000);
        if (i == 6) try session.setRunBudget(.cpu0, 1);
    }
}
