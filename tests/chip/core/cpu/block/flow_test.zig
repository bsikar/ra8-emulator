//! Covers src/chip/core/cpu/block/flow.zig.
const std = @import("std");
const ra8 = @import("ra8");

const bus = ra8.chip.core.cpu.bus;
const decode = ra8.chip.core.cpu.decode;
const block = decode.block;
const flow = block.flow;
const DecodeCache = decode.cache.DecodeCache;

const Rom = struct {
    bytes: []const u8,

    fn view(self: *Rom) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Rom = @ptrCast(@alignCast(ctx));
        if (address + into.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        _ = .{ ctx, address, from };
        return bus.Error.Unmapped;
    }
};

fn formFrom(halves: []const u16) block.Block {
    var bytes: [256]u8 = undefined;
    for (halves, 0..) |h, i| {
        std.mem.writeInt(u16, bytes[i * 2 ..][0..2], h, .little);
    }
    var rom: Rom = .{ .bytes = bytes[0 .. halves.len * 2] };
    var cache: DecodeCache = .{};
    return block.Block.form(rom.view(), &cache, decode.profile.Profile.m85, 0);
}

fn narrow(address: u32, hw1: u16, in_it: bool) flow.EdgeSummary {
    return flow.classify(.{ .address = address, .hw1 = hw1, .size = 2 }, in_it);
}

fn wide(address: u32, hw1: u16, hw2: u16, in_it: bool) flow.EdgeSummary {
    return flow.classify(.{ .address = address, .hw1 = hw1, .hw2 = hw2, .size = 4 }, in_it);
}

test "narrow branches, cbz, and loops compute exact taken and fallthrough addresses" {
    // beq 0x10 + 4 + (2 * 2) = 0x18
    const b_eq = narrow(0x10, 0xD002, false);
    try std.testing.expectEqual(flow.Kind.cond_branch, b_eq.kind);
    try std.testing.expectEqual(@as(?u32, 0x18), b_eq.target);
    try std.testing.expectEqual(@as(?u32, 0x12), b_eq.fallthrough);

    // beq -4 -> 0x20 + 4 + (-4 * 2) = 0x1C
    const b_back = narrow(0x20, 0xD0FC, false);
    try std.testing.expectEqual(@as(?u32, 0x1C), b_back.target);

    // b.n self (0xE7FE): offset -2 => 0x10 + 4 - 4 = 0x10, no fallthrough
    const b_self = narrow(0x10, 0xE7FE, false);
    try std.testing.expectEqual(flow.Kind.branch, b_self.kind);
    try std.testing.expectEqual(@as(?u32, 0x10), b_self.target);
    try std.testing.expectEqual(@as(?u32, null), b_self.fallthrough);

    // cbz r0, +8 (imm5=4 -> +8 -> 0x10 + 4 + 8 = 0x1C)
    const cbz_fwd = narrow(0x10, 0xB120, false);
    try std.testing.expectEqual(flow.Kind.cond_branch, cbz_fwd.kind);
    try std.testing.expectEqual(@as(?u32, 0x1C), cbz_fwd.target);
    try std.testing.expectEqual(@as(?u32, 0x12), cbz_fwd.fallthrough);
}

test "returns, calls, indirect edges, traps, and IT slots classify accurately" {
    const bx_lr = narrow(0x20, 0x4770, false);
    try std.testing.expectEqual(flow.Kind.ret, bx_lr.kind);
    try std.testing.expectEqual(@as(?u32, null), bx_lr.fallthrough);

    // Conditionalized inside IT retains fallthrough
    const bx_lr_it = narrow(0x20, 0x4770, true);
    try std.testing.expectEqual(flow.Kind.ret, bx_lr_it.kind);
    try std.testing.expectEqual(@as(?u32, 0x22), bx_lr_it.fallthrough);

    const bx_r3 = narrow(0x20, 0x4718, false);
    try std.testing.expectEqual(flow.Kind.indirect_jump, bx_r3.kind);
    try std.testing.expectEqual(@as(?flow.UnresolvedReason, .indirect_branch), bx_r3.unresolved);

    const blx_r3 = narrow(0x20, 0x4798, false);
    try std.testing.expectEqual(flow.Kind.indirect_call, blx_r3.kind);
    try std.testing.expectEqual(@as(?flow.UnresolvedReason, .indirect_call), blx_r3.unresolved);
    try std.testing.expectEqual(@as(?u32, 0x22), blx_r3.fallthrough);

    const mov_pc_lr = narrow(0x20, 0x46F7, false);
    try std.testing.expectEqual(flow.Kind.ret, mov_pc_lr.kind);
    const cmp_pc_r3 = narrow(0x20, 0x459F, false);
    try std.testing.expectEqual(flow.Kind.fallthrough, cmp_pc_r3.kind);
    const add_pc_r3 = narrow(0x20, 0x449F, false);
    try std.testing.expectEqual(@as(?flow.UnresolvedReason, .indirect_branch), add_pc_r3.unresolved);

    const pop_pc = narrow(0x20, 0xBD10, false);
    try std.testing.expectEqual(flow.Kind.ret, pop_pc.kind);

    try std.testing.expectEqual(@as(u3, 1), narrow(0x10, 0xBF08, false).it_slots);
    try std.testing.expectEqual(@as(u3, 2), narrow(0x10, 0xBF04, false).it_slots);
    try std.testing.expectEqual(@as(u3, 3), narrow(0x10, 0xBF02, false).it_slots);
    try std.testing.expectEqual(@as(u3, 4), narrow(0x10, 0xBF01, false).it_slots);

    try std.testing.expectEqual(flow.Kind.svc, narrow(0x10, 0xDF00, false).kind);
    try std.testing.expectEqual(flow.Kind.halt, narrow(0x10, 0xBE00, false).kind);
    try std.testing.expectEqual(flow.Kind.halt, narrow(0x10, 0xDE00, false).kind);
}

test "wide branches, table jumps, PC memory loads, POP.W, and LOB loops classify cleanly" {
    // bl +4 (0x100 + 4 + 4 = 0x108), fallthrough 0x104
    const bl = wide(0x100, 0xF000, 0xF802, false);
    try std.testing.expectEqual(flow.Kind.call, bl.kind);
    try std.testing.expectEqual(@as(?u32, 0x108), bl.target);
    try std.testing.expectEqual(@as(?u32, 0x104), bl.fallthrough);

    // b.w -4 (0x100 + 4 - 4 = 0x100)
    const bw = wide(0x100, 0xF7FF, 0xBFFE, false);
    try std.testing.expectEqual(flow.Kind.branch, bw.kind);
    try std.testing.expectEqual(@as(?u32, 0x100), bw.target);
    try std.testing.expectEqual(@as(?u32, null), bw.fallthrough);

    // beq.w +4 (0x100 + 4 + 4 = 0x108), fallthrough 0x104
    const beq_w = wide(0x100, 0xF000, 0x8002, false);
    try std.testing.expectEqual(flow.Kind.cond_branch, beq_w.kind);
    try std.testing.expectEqual(@as(?u32, 0x108), beq_w.target);
    try std.testing.expectEqual(@as(?u32, 0x104), beq_w.fallthrough);

    // wls lr, r2, +12 (0x104 + 12 = 0x110) and dls
    const wls = wide(0x100, 0xF042, 0xC007, false);
    try std.testing.expectEqual(flow.Kind.cond_branch, wls.kind);
    try std.testing.expectEqual(@as(?u32, 0x110), wls.target);
    try std.testing.expectEqual(@as(?u32, 0x104), wls.fallthrough);
    try std.testing.expectEqual(flow.Kind.fallthrough, wide(0x100, 0xF040, 0xE001, false).kind);

    // le lr, -6 (0x124 - 6 = 0x11E)
    const le = wide(0x120, 0xF00F, 0xC803, false);
    try std.testing.expectEqual(flow.Kind.cond_branch, le.kind);
    try std.testing.expectEqual(@as(?u32, 0x11E), le.target);
    try std.testing.expectEqual(@as(?u32, 0x124), le.fallthrough);

    // MVE wlstp / letp
    const wlstp = wide(0x100, 0xF003, 0xC011, false);
    try std.testing.expectEqual(flow.Kind.cond_branch, wlstp.kind);
    try std.testing.expect(wlstp.target.? > 0x104);
    const letp = wide(0x120, 0xF01F, 0xC007, false);
    try std.testing.expectEqual(flow.Kind.cond_branch, letp.kind);
    try std.testing.expectEqual(@as(?u32, 0x118), letp.target);

    const tbb = wide(0x100, 0xE8D0, 0xF000, false);
    try std.testing.expectEqual(@as(?flow.UnresolvedReason, .table_branch), tbb.unresolved);
    const tbh = wide(0x100, 0xE8D0, 0xF010, false);
    try std.testing.expectEqual(@as(?flow.UnresolvedReason, .table_branch), tbh.unresolved);

    const pop_w = wide(0x100, 0xE8BD, 0x8010, false);
    try std.testing.expectEqual(flow.Kind.ret, pop_w.kind);
    const pop_pc_w = wide(0x100, 0xF85D, 0xFB04, false);
    try std.testing.expectEqual(flow.Kind.ret, pop_pc_w.kind);
    const subs_pc_lr = wide(0x100, 0xF3DE, 0x8F00, false);
    try std.testing.expectEqual(flow.Kind.ret, subs_pc_lr.kind);

    const ldr_pc = wide(0x100, 0xF8DD, 0xF004, false);
    try std.testing.expectEqual(@as(?flow.UnresolvedReason, .pc_memory_load), ldr_pc.unresolved);
    const ldm_pc = wide(0x100, 0xE890, 0x8010, false);
    try std.testing.expectEqual(@as(?flow.UnresolvedReason, .pc_memory_load), ldm_pc.unresolved);

    // Hints/barriers/system controls keep linear flow
    try std.testing.expectEqual(flow.Kind.fallthrough, wide(0x100, 0xF380, 0x8814, false).kind);
    try std.testing.expectEqual(flow.Kind.fallthrough, wide(0x100, 0xE97F, 0xE97F, false).kind);
    try std.testing.expectEqual(flow.Kind.fallthrough, wide(0x100, 0xF890, 0xF000, false).kind);
    try std.testing.expectEqual(flow.Kind.halt, wide(0x100, 0xF7F0, 0xA000, false).kind);
}

test "fromBlock handles empty, capped, and terminator blocks" {
    const empty_blk: block.Block = .{};
    const empty_sum = flow.fromBlock(empty_blk, false);
    try std.testing.expectEqual(flow.Kind.halt, empty_sum.kind);
    try std.testing.expect(empty_sum.decode_stop);

    var nops: [block.cap + 4]u16 = undefined;
    @memset(&nops, 0xBF00);
    const capped = formFrom(&nops);
    const cap_sum = flow.fromBlock(capped, false);
    try std.testing.expectEqual(flow.Kind.fallthrough, cap_sum.kind);
    try std.testing.expectEqual(@as(?u32, block.cap * 2), cap_sum.fallthrough);

    const ret_blk = formFrom(&.{ 0x2001, 0xBD10 });
    try std.testing.expectEqual(flow.Kind.ret, flow.fromBlock(ret_blk, false).kind);
}
