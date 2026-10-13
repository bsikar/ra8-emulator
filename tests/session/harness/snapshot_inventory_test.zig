//! State owner refuses unsupported arena topology before save or restore.
const std = @import("std");
const ra8 = @import("ra8");
const image = "tests/fixtures/threadx/threadx_stkof.elf";
fn refuse(opened: *ra8.session.harness.Harness, bytes: []const u8) !void {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const pc = opened.primaryCpu().regs.pc;
    const board_ns = opened.board().time.base.now();
    try std.testing.expectError(error.UnsupportedAttachments, opened.state.files.writeTo(&out.writer));
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    try std.testing.expectError(error.UnsupportedAttachments, opened.state.files.readFrom(bytes));
    try std.testing.expectEqual(pc, opened.primaryCpu().regs.pc);
    try std.testing.expectEqual(board_ns, opened.board().time.base.now());
}
test "snapshot owner refuses startup asks and mid-run topology even after unplug" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image, .history_frames = 2 });
    defer opened.deinit();
    var saved = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer saved.deinit();
    try opened.state.files.writeTo(&saved.writer);
    try opened.state.files.readFrom(saved.written());
    if (opened.board().display.output.vsync) |vsync| try std.testing.expectEqual(@as(u64, 0), vsync.next_ns);
    opened.state.files.plugs = null;
    try refuse(&opened, saved.written());
    opened.state.files.plugs = opened.plugs();
    opened.board().asks.count = 1;
    try refuse(&opened, saved.written());
    opened.board().asks.count = 0;
    const at: ra8.components.endpoint.Endpoint = .{ .i2c = .{ .line = .riic, .address = 0x37 } };
    try opened.plugs().set(at, "max17048");
    try refuse(&opened, saved.written());
    try opened.plugs().set(at, null);
    try refuse(&opened, saved.written());
}
test "snapshot owner refuses existing fault wrappers even after clear" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image, .history_frames = 2 });
    defer opened.deinit();
    var saved = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer saved.deinit();
    try opened.state.files.writeTo(&saved.writer);
    const at: ra8.components.endpoint.Endpoint = .{ .i2c = .{ .line = .riic, .address = 0x43 } };
    try opened.state.faults.set(at, .{ .stuck = 0x33 });
    try refuse(&opened, saved.written());
    try opened.state.faults.set(at, null);
    try refuse(&opened, saved.written());
}
