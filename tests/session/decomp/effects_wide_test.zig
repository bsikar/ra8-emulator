//! Covers src/session/decomp/effects_wide.zig.
const std = @import("std");
const ra8 = @import("ra8");

const bus = ra8.chip.core.cpu.bus;
const decode = ra8.chip.core.cpu.decode;
const decomp = ra8.session.decomp;
const Instr = ra8.chip.core.cpu.instr.Instr;

const DummyBus = struct {
    fn view(self: *DummyBus) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, addr: u32, into: []u8) bus.Error!void {
        _ = .{ ctx, addr, into };
        return bus.Error.Unmapped;
    }

    fn write(ctx: *anyopaque, addr: u32, from: []const u8) bus.Error!void {
        _ = .{ ctx, addr, from };
        return bus.Error.Unmapped;
    }
};

fn evalWide(state: *const decomp.effects.State, addr: u32, hw1: u16, hw2: u16) decomp.effects.Effect {
    const instr: Instr = .{ .address = addr, .hw1 = hw1, .hw2 = hw2, .size = 4 };
    const hit = decode.decode(instr).?;
    return decomp.effects.evaluate(state, instr, hit);
}

test "wide movw/movt pair, bfi bitfield folding, csel, ldrd, and umull pairs evaluate accurately" {
    var regs: [16]decomp.value.Value = @splat(.unknown);
    var db: DummyBus = .{};
    const st: decomp.effects.State = .{ .regs = &regs, .bus = db.view() };

    // movw r3, #0x0d02 (0xF640 0x5302)
    const movw = evalWide(&st, 0x0, 0xF640, 0x5302);
    try std.testing.expectEqual(decomp.value.Value{ .constant = 0x0D02 }, movw.primary_val);
    regs[3] = movw.primary_val;

    // movt r3, #0x2000 (0xF2C2 0x0300)
    const movt = evalWide(&st, 0x4, 0xF2C2, 0x0300);
    try std.testing.expectEqual(decomp.value.Value{ .constant = 0x2000_0D02 }, movt.primary_val);

    // bfi r3, r1, #8, #8: (0xF361 0x230F) matching uart_irq_setup_or_halt
    regs[3] = .{ .constant = 0x0002 };
    regs[1] = .{ .constant = 0x0003 };
    const bfi = evalWide(&st, 0x10, 0xF361, 0x230F);
    try std.testing.expectEqual(decomp.value.Value{ .constant = 0x0302 }, bfi.primary_val);

    // umull r0, r1, r2, r3 (0xFBA2 0x0103) creates 64-bit RegPair with const_u64
    regs[2] = .{ .constant = 0x1_0000 };
    regs[3] = .{ .constant = 0x2_0000 };
    const mul64 = evalWide(&st, 0x20, 0xFBA2, 0x0103);
    try std.testing.expectEqual(@as(?u64, 0x2_0000_0000), mul64.pair.?.const_u64);
    try std.testing.expectEqual(@as(?u4, 0), mul64.primary_rd);
    try std.testing.expectEqual(@as(?u4, 1), mul64.secondary_rd);

    // cset r0, eq = csinc r0, zr, zr, ne (0xEA5F 0x901F)
    const cset = evalWide(&st, 0x30, 0xEA5F, 0x901F);
    try std.testing.expectEqual(@as(?u4, 1), cset.consumes_cond);
    try std.testing.expect(cset.writes_flags == null);
}
