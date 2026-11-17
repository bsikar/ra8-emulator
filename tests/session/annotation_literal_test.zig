//! Decoding a literal must never cause an extra access to peripheral memory.
const std = @import("std");

const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;

const Memory = struct {
    reads: usize = 0,
    fn read(context: *anyopaque, _: u32, into: []u8) bus.Error!void {
        const self: *Memory = @ptrCast(@alignCast(context));
        self.reads += 1;
        if (into.len != 4) return error.Unmapped;
        std.mem.writeInt(u32, into[0..4], 0xE000_ED0C, .little);
    }
    fn write(_: *anyopaque, _: u32, _: []const u8) bus.Error!void {}
};

test "literal annotation excludes device windows and reads current ordinary memory once" {
    var memory: Memory = .{};
    var cpu: ra8.chip.core.cpu.cpu.Cpu = .{
        .bus = .{ .ctx = &memory, .vtable = &.{ .read = Memory.read, .write = Memory.write } },
    };
    const view: ra8.session.core_view.View = .{ .zig = .{ .cpu = &cpu } };
    var text: ra8.chip.core.cpu.text.text.Text = .{};
    text.put("ldr r0, [pc, #0]", .{});
    ra8.session.annotation_literal.append(view, .{ .address = 0xE000_0000, .hw1 = 0x4800, .size = 2 }, &text);
    try std.testing.expectEqual(@as(usize, 0), memory.reads);
    ra8.session.annotation_literal.append(view, .{ .address = 0x0200_0000, .hw1 = 0x4800, .size = 2 }, &text);
    try std.testing.expectEqual(@as(usize, 1), memory.reads);
    try std.testing.expectEqualStrings("ldr r0, [pc, #0] ; =SCB.aircr", text.slice());
}
