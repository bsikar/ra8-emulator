//! Covers src/core/cpu/cpu.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.core.cpu.bus;
const regs = ra8.core.cpu.regs;
const Cpu = ra8.core.cpu.cpu.Cpu;

/// A little image at address 0: a vector table, then code at 0x08.
const Image = struct {
    bytes: []const u8,

    fn view(self: *Image) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Image = @ptrCast(@alignCast(ctx));
        if (address + into.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        _ = .{ ctx, address, from };
        return bus.Error.Unmapped;
    }
};

// sp 0x20001000, reset 0x09 ; bf00 nop ; f3af 8000 nop.w ; de00 udf #0
const boots_to_udf = [_]u8{
    0x00, 0x10, 0x00, 0x20, 0x09, 0x00, 0x00, 0x00,
    0x00, 0xBF, 0xAF, 0xF3, 0x00, 0x80, 0x00, 0xDE,
};

test "a run goes through the nops and stops on the first unknown encoding" {
    var image: Image = .{ .bytes = &boots_to_udf };
    var cpu: Cpu = .{ .bus = image.view() };
    try cpu.reset(0);
    const stopped = cpu.run(100);
    try std.testing.expectEqual(@as(u32, 0x0E), stopped.unknown.address);
    try std.testing.expectEqual(@as(u16, 0xDE00), stopped.unknown.hw1);
    try std.testing.expectEqual(@as(u32, 0x0E), cpu.regs.pc);
    try std.testing.expectEqual(@as(u64, 2), cpu.retired);
}

test "a run stops after the count it was given" {
    var image: Image = .{ .bytes = &boots_to_udf };
    var cpu: Cpu = .{ .bus = image.view() };
    try cpu.reset(0);
    try std.testing.expectEqual(.count, std.meta.activeTag(cpu.run(1)));
    try std.testing.expectEqual(@as(u32, 0x0A), cpu.regs.pc);
}

test "a clear T bit stops before the fetch" {
    var image: Image = .{ .bytes = &boots_to_udf };
    var cpu: Cpu = .{ .bus = image.view() };
    try cpu.reset(0);
    cpu.regs.xpsr = 0;
    try std.testing.expectEqual(@as(u32, 0x08), cpu.run(1).invalid_state);
}

test "running off the end of memory is a bus fault on the fetch" {
    var image: Image = .{ .bytes = &boots_to_udf };
    var cpu: Cpu = .{ .bus = image.view() };
    cpu.regs.xpsr = regs.xpsr_bits.thumb;
    cpu.regs.pc = 0x10;
    try std.testing.expectEqual(@as(u32, 0x10), cpu.run(1).bus_fault);
}
