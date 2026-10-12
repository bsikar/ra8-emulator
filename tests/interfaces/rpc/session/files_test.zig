//! RA8EMU-768 through the serve handlers on a real harness: snapshot
//! writes the run file and restore puts the core, guest memory and virtual
//! time back where it was, a page written since included.
const std = @import("std");
const ra8 = @import("ra8");

const server = ra8.rpc.session.server;
const files = ra8.rpc.session.files;
const memmap = ra8.chip.core.memmap;

const image = "tests/fixtures/uart/uart_irq_echo.elf";
/// A word in SRAM the fixture never touches, so it reads zero when saved.
const spare = memmap.sram_base + 0x0004_0000;

fn runFor(harness: *ra8.session.harness.Harness, instructions: u64) !void {
    const session = harness.session();
    session.live.budget = instructions;
    _ = try session.run(.cpu0, .cont);
}

fn word(harness: *ra8.session.harness.Harness) !u32 {
    var bytes: [4]u8 = undefined;
    try harness.session().read(.cpu0, spare, &bytes);
    return std.mem.readInt(u32, &bytes, .little);
}

test "restore puts pc, guest memory and virtual time back where snapshot left them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = "run.ra8snap";

    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image, .state_dir = dir });
    defer opened.deinit();
    var scratch: [64]u8 = undefined;
    var context: server.Context = .{ .session = opened.session(), .scratch = &scratch, .state = opened.stateFiles() };

    try runFor(&opened, 20_000);
    const pc = try opened.session().register(.cpu0, .pc);
    const at = try opened.session().now();
    const kept = try word(&opened);
    try std.testing.expect(files.snapshot(&context, .{ .path = path }) == .ok);

    try runFor(&opened, 20_000);
    try opened.session().write(.cpu0, spare, &.{ 0xef, 0xbe, 0xad, 0xde });
    try std.testing.expect(try opened.session().now() > at);

    try std.testing.expect(files.restore(&context, .{ .path = path }) == .ok);
    try std.testing.expectEqual(pc, try opened.session().register(.cpu0, .pc));
    try std.testing.expectEqual(at, try opened.session().now());
    try std.testing.expectEqual(kept, try word(&opened));

    // The restored run carries on as the saved one did.
    try runFor(&opened, 20_000);
    try std.testing.expect(try opened.session().now() > at);
}

test "snapshot and restore are refused with no state hook or no such file" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image });
    defer opened.deinit();
    var scratch: [64]u8 = undefined;
    var bare: server.Context = .{ .session = opened.session(), .scratch = &scratch };
    try std.testing.expect(files.snapshot(&bare, .{ .path = "unused" }) == .err);
    var served: server.Context = .{ .session = opened.session(), .scratch = &scratch, .state = opened.stateFiles() };
    try std.testing.expect(files.restore(&served, .{ .path = "no-such.ra8snap" }) == .err);
}

test "snapshot and restore refuse every path that leaves the state directory (RA8EMU-1175)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);

    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image, .state_dir = dir });
    defer opened.deinit();
    var scratch: [64]u8 = undefined;
    var context: server.Context = .{ .session = opened.session(), .scratch = &scratch, .state = opened.stateFiles() };

    for ([_][]const u8{ "/tmp/x.ra8snap", "../x.ra8snap", "a/b.ra8snap", "..", ".", "" }) |path| {
        try std.testing.expectError(error.BadStatePath, opened.stateFiles().save(path));
        try std.testing.expectError(error.BadStatePath, opened.stateFiles().restore(path));
    }
    // A bare name lands in the state directory, and nothing the refusals
    // were offered was written anywhere.
    try std.testing.expect(files.snapshot(&context, .{ .path = "ok.state" }) == .ok);
    const landed = try std.fs.path.join(std.testing.allocator, &.{ dir, "ok.state" });
    defer std.testing.allocator.free(landed);
    try std.testing.expect((try tmp.dir.statFile(std.testing.io, "ok.state", .{})).kind == .file);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "../x.ra8snap", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "a/b.ra8snap", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "x.ra8snap", .{}));
}
