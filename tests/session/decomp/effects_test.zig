//! Covers src/session/decomp/effects.zig.
const std = @import("std");
const ra8 = @import("ra8");

const bus = ra8.chip.core.cpu.bus;
const decode = ra8.chip.core.cpu.decode;
const decomp = ra8.session.decomp;
const Instr = ra8.chip.core.cpu.instr.Instr;

const DummyBus = struct {
    pool_word: u32 = 0xCAFE_BABE,

    fn view(self: *DummyBus) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write, .peek = peek } };
    }

    fn read(ctx: *anyopaque, addr: u32, into: []u8) bus.Error!void {
        _ = .{ ctx, addr, into };
        return bus.Error.Unmapped;
    }

    fn write(ctx: *anyopaque, addr: u32, from: []const u8) bus.Error!void {
        _ = .{ ctx, addr, from };
        return bus.Error.Unmapped;
    }

    fn peek(ctx: *anyopaque, addr: u32, into: []u8) bool {
        const self: *DummyBus = @ptrCast(@alignCast(ctx));
        if (addr == 0x20 and into.len == 4) {
            std.mem.writeInt(u32, into[0..4], self.pool_word, .little);
            return true;
        }
        return false;
    }
};

fn evalNarrow(state: *const decomp.effects.State, addr: u32, hw1: u16) decomp.effects.Effect {
    const instr: Instr = .{ .address = addr, .hw1 = hw1, .size = 2 };
    const hit = decode.decode(instr).?;
    return decomp.effects.evaluate(state, instr, hit);
}

test "narrow arithmetic, cmp, mov, sp offsets, push/pop, cbz, and IT flag suppression" {
    var regs: [16]decomp.value.Value = @splat(.unknown);
    regs[13] = .{ .sp_offset = 0 };
    var db: DummyBus = .{};
    const st: decomp.effects.State = .{ .regs = &regs, .bus = db.view() };

    // movs r0, #21 (0x2015) outside IT -> constant + flags
    const movs = evalNarrow(&st, 0x0, 0x2015);
    try std.testing.expectEqual(@as(?u4, 0), movs.primary_rd);
    try std.testing.expectEqual(decomp.value.Value{ .constant = 21 }, movs.primary_val);
    try std.testing.expect(movs.writes_flags != null);

    // inside IT: movs leaves flags untouched and consumes condition
    const it_st: decomp.effects.State = .{ .regs = &regs, .bus = db.view(), .in_it = true, .it_cond = 0 };
    const mov_in_it = evalNarrow(&it_st, 0x0, 0x2015);
    try std.testing.expect(mov_in_it.writes_flags == null);
    try std.testing.expectEqual(@as(?u4, 0), mov_in_it.consumes_cond);

    // push {r7, lr} (0xB580): sp_offset -> -8, pushed_mask records r7 and lr
    const push_eff = evalNarrow(&st, 0x2, 0xB580);
    try std.testing.expectEqual(decomp.value.Value{ .sp_offset = -8 }, push_eff.primary_val);
    try std.testing.expectEqual(@as(u16, (1 << 7) | (1 << 14)), push_eff.pushed_mask);

    // ldr r2, [pc, #imm] at 0x10 reading 0x20: (0x10 + 4) + (3*4) = 0x20 -> 0x4A03
    const lit_eff = evalNarrow(&st, 0x10, 0x4A03);
    try std.testing.expectEqual(decomp.value.Value{ .constant = 0xCAFE_BABE }, lit_eff.primary_val);

    // cbz r2, ... -> self_cond_reg = 2, cond = 0
    const cbz_eff = evalNarrow(&st, 0x12, 0xB122);
    try std.testing.expectEqual(@as(?u4, 2), cbz_eff.self_cond_reg);
    try std.testing.expectEqual(@as(?u4, 0), cbz_eff.consumes_cond);
}
