//! State owner saves bound arena topology and refuses an unbound one before bytes.
const std = @import("std");
const ra8 = @import("ra8");
const image = "tests/fixtures/threadx/threadx_stkof.elf";
const Endpoint = ra8.components.endpoint.Endpoint;
const gauge_at: Endpoint = .{ .i2c = .{ .line = .riic, .address = 0x36 } };
const fault_at: Endpoint = .{ .i2c = .{ .line = .riic, .address = 0x43 } };
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
fn read(opened: *ra8.session.harness.Harness, address: u7) ![2]u8 {
    var bytes: [2]u8 = undefined;
    const device = opened.board().wire.controller.devices.find(address) orelse return error.Missing;
    try std.testing.expectEqual(@as(usize, 2), device.read(&bytes));
    return bytes;
}
test "snapshot owner restores mid-run topology and refuses an unbound owner or startup asks" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image, .history_frames = 2 });
    defer opened.deinit();
    var empty = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer empty.deinit();
    try opened.state.files.writeTo(&empty.writer);
    try opened.state.files.readFrom(empty.written());
    if (opened.board().display.output.vsync) |vsync| try std.testing.expectEqual(@as(u64, 0), vsync.next_ns);
    const binding = opened.state.files.attachments;
    opened.state.files.attachments = null;
    try refuse(&opened, empty.written());
    opened.board().asks.count = 1;
    try refuse(&opened, empty.written());
    opened.board().asks.count = 0;
    opened.state.files.attachments = binding;
    try opened.plugs().set(gauge_at, "max17048");
    opened.board().wire.controller.devices.find(0x36).?.write(ra8.components.max17048.reg.soc);
    var plugged = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer plugged.deinit();
    try opened.state.files.writeTo(&plugged.writer);
    const expected = try read(&opened, 0x36);
    try opened.plugs().set(gauge_at, null);
    try opened.state.files.readFrom(plugged.written());
    try std.testing.expectEqual(@as(usize, 1), opened.plugs().instance_count);
    try std.testing.expectEqualSlices(u8, &expected, &try read(&opened, 0x36));
    try opened.state.files.readFrom(empty.written());
    try std.testing.expectEqual(@as(usize, 0), opened.plugs().instance_count);
    try std.testing.expectError(error.Missing, read(&opened, 0x36));
}
test "snapshot owner restores a fault wrapper after clear" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image, .history_frames = 2 });
    defer opened.deinit();
    try opened.state.faults.set(fault_at, .{ .stuck = 0x33 });
    var faulted = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer faulted.deinit();
    try opened.state.files.writeTo(&faulted.writer);
    const expected = try read(&opened, 0x43);
    try std.testing.expectEqualSlices(u8, &.{ 0x33, 0x33 }, &expected);
    try opened.state.faults.set(fault_at, null);
    var cleared = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer cleared.deinit();
    try opened.state.files.writeTo(&cleared.writer);
    try opened.state.files.readFrom(faulted.written());
    try std.testing.expectEqualSlices(u8, &expected, &try read(&opened, 0x43));
    try opened.state.files.readFrom(cleared.written());
    try std.testing.expect(!std.mem.eql(u8, &expected, &try read(&opened, 0x43)));
    try opened.state.files.readFrom(faulted.written());
    try std.testing.expectEqualSlices(u8, &expected, &try read(&opened, 0x43));
}
