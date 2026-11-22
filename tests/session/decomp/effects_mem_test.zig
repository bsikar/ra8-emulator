//! Covers src/session/decomp/effects_mem.zig.
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

test "effects_mem handles ldrd pairs, sp-relative strh/ldrh, and push.w/pop.w sp updates" {
    var regs: [16]decomp.value.Value = @splat(.unknown);
    regs[13] = .{ .sp_offset = 0 };
    regs[7] = .{ .sp_offset = -16 };
    var db: DummyBus = .{};
    const st: decomp.effect_types.State = .{ .regs = &regs, .bus = db.view() };

    // push.w {r4, lr} -> 0xE92D 0x4010
    const push_w_instr: Instr = .{ .address = 0x0, .hw1 = 0xE92D, .hw2 = 0x4010, .size = 4 };
    const push_w = decomp.effects_mem.evaluateWide(&st, push_w_instr, "ldm_stm_wide").?;
    try std.testing.expectEqual(@as(?u4, 13), push_w.wback_reg);
    try std.testing.expectEqual(decomp.value.Value{ .sp_offset = -8 }, push_w.wback_val);
    try std.testing.expectEqual(@as(u16, (1 << 4) | (1 << 14)), push_w.pushed_mask);

    // strh r3, [r7, #6] -> 0x80FB (does not clear spills when r7 is sp_offset)
    const strh_instr: Instr = .{ .address = 0x4, .hw1 = 0x80FB, .size = 2 };
    const strh = decomp.effects_mem.evaluateNarrow(&st, strh_instr, "ldst_imm").?;
    try std.testing.expect(!strh.clears_spills);
    try std.testing.expect(strh.mem != null);
    try std.testing.expectEqual(@as(i32, 6), strh.mem.?.offset);

    // ldrd r0, r1, [sp, #8] -> 0xE9DD 0x0102
    const ldrd_instr: Instr = .{ .address = 0x10, .hw1 = 0xE9DD, .hw2 = 0x0102, .size = 4 };
    const ldrd_hit = decode.decode(ldrd_instr).?;
    const ldrd_eff = decomp.effects.evaluate(&st, ldrd_instr, ldrd_hit);
    try std.testing.expect(ldrd_eff.pair != null);
    try std.testing.expectEqual(@as(?u4, 0), ldrd_eff.primary_rd);
    try std.testing.expectEqual(@as(?u4, 1), ldrd_eff.secondary_rd);
}
