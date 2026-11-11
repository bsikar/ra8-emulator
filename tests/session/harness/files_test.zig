//! The harness's run file on the serving host (RA8EMU-768, RA8EMU-1020,
//! RA8EMU-1175): bare-name confinement before storage dispatch and atomic
//! refusal of missing, truncated, or malformed snapshot files without mutating
//! live machine state.
const std = @import("std");
const builtin = @import("builtin");
const ra8 = @import("ra8");

const api = ra8.session.api;
const file_ops = ra8.session.file_ops;
const memmap = ra8.chip.core.memmap;

const ui_image_path = "tests/fixtures/display/ra8_ui.elf";
const ui_input_path = "tests/fixtures/display/tap.input";
const fast_image_path = "tests/fixtures/uart/uart_irq_echo.elf";
const spare_addr = memmap.sram_base + 0x0004_0000;
const all_regs = std.enums.values(api.Register);

fn runInstructions(h: *ra8.session.harness.Harness, count: u64) !void {
    const s = h.session();
    s.live.budget = count;
    _ = try s.run(.cpu0, .cont);
}

fn readSpareWord(h: *ra8.session.harness.Harness) !u32 {
    var buf: [4]u8 = undefined;
    try h.session().read(.cpu0, spare_addr, &buf);
    return std.mem.readInt(u32, &buf, .little);
}

const MachineSnapshot = struct {
    gpa: std.mem.Allocator,
    regs: [all_regs.len]u32,
    sram_word: u32,
    pos: api.Position,
    now_ns: u64,
    bytes: []u8,

    fn capture(gpa: std.mem.Allocator, h: *ra8.session.harness.Harness) !MachineSnapshot {
        var regs: [all_regs.len]u32 = undefined;
        for (all_regs, 0..) |reg, idx| {
            regs[idx] = try h.session().register(.cpu0, reg);
        }
        var out = std.Io.Writer.Allocating.init(gpa);
        errdefer out.deinit();
        try h.state.files.writeTo(&out.writer);
        const bytes = try gpa.dupe(u8, out.written());
        out.deinit();
        return .{
            .gpa = gpa,
            .regs = regs,
            .sram_word = try readSpareWord(h),
            .pos = h.session().currentPosition(),
            .now_ns = try h.session().now(),
            .bytes = bytes,
        };
    }

    fn deinit(self: *MachineSnapshot) void {
        self.gpa.free(self.bytes);
    }

    fn expectUnchanged(self: *const MachineSnapshot, h: *ra8.session.harness.Harness) !void {
        for (all_regs, 0..) |reg, idx| {
            try std.testing.expectEqual(self.regs[idx], try h.session().register(.cpu0, reg));
        }
        try std.testing.expectEqual(self.sram_word, try readSpareWord(h));
        try std.testing.expectEqual(self.pos, h.session().currentPosition());
        try std.testing.expectEqual(self.now_ns, try h.session().now());
        var cur = std.Io.Writer.Allocating.init(self.gpa);
        defer cur.deinit();
        try h.state.files.writeTo(&cur.writer);
        try std.testing.expectEqualSlices(u8, self.bytes, cur.written());
    }
};

const CountingTrap = struct {
    calls: usize = 0,

    fn save(ctx: ?*anyopaque, _: std.Io, _: ?[]const u8, _: []const u8, _: *anyopaque, _: file_ops.WriteStreamFn) anyerror!void {
        const self: *CountingTrap = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        return error.TrapReached;
    }

    fn restore(ctx: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: usize) anyerror![]u8 {
        const self: *CountingTrap = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        return error.TrapReached;
    }
};

test "restoring from a missing file fails and the session keeps running" {
    if (builtin.mode != .fast) return error.SkipZigTest;
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = ui_image_path, .input_script = ui_input_path, .files = ra8.host.session_files.cwd(file_ops.Ops) });
    defer opened.deinit();
    try opened.session().waitSettled(2_000_000_000);
    try std.testing.expectError(error.FileNotFound, opened.stateFiles().restore("missing.ra8snap"));
    // Paths that leave the state directory are refused before any file call
    // (RA8EMU-1175).
    for ([_][]const u8{ "/tmp/x.ra8snap", "../x.ra8snap", "a/b.ra8snap", "..", "." }) |path| {
        try std.testing.expectError(error.BadStatePath, opened.stateFiles().save(path));
        try std.testing.expectError(error.BadStatePath, opened.stateFiles().restore(path));
    }
    try opened.session().waitSettled(2_000_000_000);
}

test "stateFiles bareName confinement rejects escapes before invoking StateStore" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var trap: CountingTrap = .{};
    const ops: file_ops.Ops = .{
        .reader = ra8.host.session_files.reader(file_ops.Reader),
        .writer = ra8.host.session_files.writer(file_ops.Writer),
        .state = .{ .context = &trap, .saveFn = CountingTrap.save, .restoreFn = CountingTrap.restore },
    };

    var opened = try ra8.session.harness.open(gpa, io, .{ .elf_path = fast_image_path, .files = ops });
    defer opened.deinit();
    try runInstructions(&opened, 10_000);
    var before = try MachineSnapshot.capture(gpa, &opened);
    defer before.deinit();

    const escapes = [_][]const u8{
        "",
        ".",
        "..",
        "../escape.snap",
        "..\\escape.snap",
        "sub/escape.snap",
        "sub\\escape.snap",
        "/tmp/escape.snap",
        "\\escape.snap",
        "C:escape.snap",
        "C:\\escape.snap",
        "bad\x00name.snap",
    };
    for (escapes) |bad| {
        try std.testing.expectError(error.BadStatePath, opened.stateFiles().save(bad));
        try std.testing.expectError(error.BadStatePath, opened.stateFiles().restore(bad));
    }
    try std.testing.expectEqual(@as(usize, 0), trap.calls);
    try before.expectUnchanged(&opened);
}

test "stateFiles.restore refuses truncated and malformed snapshots without mutating live state" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ops = ra8.host.session_files.inDir(file_ops.Ops, &tmp.dir);

    const elf_bytes = try ra8.host.session_files.reader(file_ops.Reader).readAlloc(io, fast_image_path, gpa, 8 << 20);
    defer gpa.free(elf_bytes);
    var opened = try ra8.session.harness.open(gpa, io, .{ .elf_bytes = elf_bytes, .files = ops });
    defer opened.deinit();
    try runInstructions(&opened, 10_000);
    try opened.stateFiles().save("seed.snap");

    try runInstructions(&opened, 12_000);
    try opened.session().write(.cpu0, spare_addr, &.{ 0x44, 0x33, 0x22, 0x11 });
    try opened.session().setRegister(.cpu0, .r2, 0xaabb_ccdd);
    var live = try MachineSnapshot.capture(gpa, &opened);
    defer live.deinit();

    const valid = try tmp.dir.readFileAlloc(io, "seed.snap", gpa, .limited(16 << 20));
    defer gpa.free(valid);
    try putFile(io, tmp.dir, "empty.snap", "");
    try putFile(io, tmp.dir, "junk.snap", "corrupted-header-bytes");
    try putFile(io, tmp.dir, "short16.snap", valid[0..@min(16, valid.len)]);
    try putFile(io, tmp.dir, "half.snap", valid[0 .. valid.len / 2]);
    try putFile(io, tmp.dir, "tail_cut.snap", valid[0 .. valid.len - 3]);

    for ([_][]const u8{ "missing.snap", "empty.snap", "junk.snap", "short16.snap", "half.snap", "tail_cut.snap" }) |bad| {
        if (opened.stateFiles().restore(bad)) |_| return error.TestExpectedError else |_| {}
        try live.expectUnchanged(&opened);
    }

    try opened.stateFiles().restore("seed.snap");
    try std.testing.expect(try opened.session().now() < live.now_ns);
}

fn putFile(io: std.Io, dir: std.Io.Dir, name: []const u8, data: []const u8) !void {
    var f = try dir.createFile(io, name, .{});
    defer f.close(io);
    var buf: [1024]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll(data);
    try w.interface.flush();
}
