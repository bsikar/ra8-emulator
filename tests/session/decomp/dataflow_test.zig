//! Covers src/session/decomp/dataflow.zig.
const std = @import("std");
const ra8 = @import("ra8");

const bus = ra8.chip.core.cpu.bus;
const decode = ra8.chip.core.cpu.decode;
const decomp = ra8.session.decomp;
const elf = ra8.board.image.elf;

const uart_elf_bytes = @embedFile("../../fixtures/uart/uart_irq_echo.elf");

const Rom = struct {
    base: u32,
    bytes: []const u8,

    fn view(self: *Rom) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write, .allowsExec = allowsExec } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Rom = @ptrCast(@alignCast(ctx));
        if (address < self.base) return bus.Error.Unmapped;
        const off = address - self.base;
        if (off + into.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(into, self.bytes[off..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        _ = .{ ctx, address, from };
        return bus.Error.Unmapped;
    }

    fn allowsExec(ctx: *anyopaque, address: u32, len: usize) bool {
        const self: *Rom = @ptrCast(@alignCast(ctx));
        return address >= self.base and (address - self.base) + len <= self.bytes.len;
    }
};

fn analyzeHalfwords(halves: []const u16, entry: u32) !decomp.dataflow.Dataflow {
    const gpa = std.testing.allocator;
    const raw = try gpa.alloc(u8, halves.len * 2);
    defer gpa.free(raw);
    for (halves, 0..) |h, i| {
        std.mem.writeInt(u16, raw[i * 2 ..][0..2], h, .little);
    }

    var rom: Rom = .{ .base = entry, .bytes = raw };
    const dc = try gpa.create(decode.cache.DecodeCache);
    defer gpa.destroy(dc);
    dc.* = .{};

    var cfg = try decomp.builder.build(gpa, .{
        .bus = rom.view(),
        .decode_cache = dc,
        .entry = entry,
    });
    defer cfg.deinit();

    return decomp.dataflow.analyze(gpa, &cfg, .{ .bus = rom.view() });
}

test "flag setters pair across non-flag instructions, loops, csel, and IT blocks" {
    // 0x00: cmp r0, #0 (0x2800)
    // 0x02: ldr r2, [r1] (0x680A) - must not clobber flags
    // 0x04: beq +2 -> 0x0A (0xD001)
    // 0x06: subs r2, #1 (0x3A01)
    // 0x08: bne -2 -> 0x06 (0xD1FD)
    // 0x0A: cset r0, eq (0xEA5F 0x901F)
    // 0x0E: bx lr (0x4770)
    var df = try analyzeHalfwords(&.{ 0x2800, 0x680A, 0xD001, 0x3A01, 0xD1FD, 0xEA5F, 0x901F, 0x4770 }, 0x0);
    defer df.deinit();

    try std.testing.expect(df.converged);
    try std.testing.expectEqual(@as(u4, 0b0011), df.signature.used_args_mask);
    try std.testing.expectEqual(decomp.aapcs.ReturnKind.r0, df.signature.return_kind);

    var saw_cmp_beq = false;
    var saw_subs_bne = false;
    var saw_csel = false;
    for (df.cond_pairs) |cp| {
        if (cp.consumer_addr == 0x04 and cp.origin != null) {
            try std.testing.expectEqual(decomp.value.FlagKind.cmp, cp.origin.?.kind);
            try std.testing.expectEqual(@as(u32, 0x00), cp.origin.?.setter_addr);
            saw_cmp_beq = true;
        }
        if (cp.consumer_addr == 0x08 and cp.origin != null) {
            try std.testing.expectEqual(decomp.value.FlagKind.result_flags, cp.origin.?.kind);
            try std.testing.expectEqual(@as(u32, 0x06), cp.origin.?.setter_addr);
            saw_subs_bne = true;
        }
        if (cp.consumer_addr == 0x0A) {
            saw_csel = true;
        }
    }
    try std.testing.expect(saw_cmp_beq);
    try std.testing.expect(saw_subs_bne);
    try std.testing.expect(saw_csel);

    // IT block preserves flags across predicated moveq + bxeq lr
    // cmp r0,#0 (0x2800); itt eq (0xBF04); moveq r0,#1 (0x2001); bxeq lr (0x4770); movs r0,#0 (0x2000); bx lr (0x4770)
    var it_df = try analyzeHalfwords(&.{ 0x2800, 0xBF04, 0x2001, 0x4770, 0x2000, 0x4770 }, 0x100);
    defer it_df.deinit();
    const moveq_flow = it_df.insnAt(0x104) orelse return error.MissingMoveq;
    try std.testing.expectEqual(@as(?u4, 0), moveq_flow.cond_active);
    var paired_bxeq = false;
    for (it_df.cond_pairs) |cp| {
        if (cp.consumer_addr == 0x106 and cp.origin != null) {
            try std.testing.expectEqual(@as(u32, 0x100), cp.origin.?.setter_addr);
            paired_bxeq = true;
        }
    }
    try std.testing.expect(paired_bxeq);
}

test "aapcs call clobbers, callee-saved preservation, void vs 64-bit returns" {
    // 0x00: push {r4, lr} (0xB510)
    // 0x02: movs r4, #77 (0x244D)
    // 0x04: movs r0, #9  (0x2009)
    // 0x06: bl +8 -> 0x12 (0xF000 0xF804)
    // 0x0A: mov r0, r4 (0x4620) - r4 must survive the call with constant 77!
    // 0x0C: pop {r4, pc} (0xBD10)
    // 0x0E: nop (0xBF00)
    // 0x10: nop (0xBF00)
    // 0x12: bx lr (0x4770)
    var df = try analyzeHalfwords(
        &.{ 0xB510, 0x244D, 0x2009, 0xF000, 0xF804, 0x4620, 0xBD10, 0xBF00, 0xBF00, 0x4770 },
        0x1000,
    );
    defer df.deinit();

    try std.testing.expectEqual(@as(u4, 0), df.signature.used_args_mask);
    try std.testing.expectEqual(decomp.aapcs.ReturnKind.r0, df.signature.return_kind);
    try std.testing.expect((df.signature.saved_callee_mask & ((1 << 4) | (1 << 14))) != 0);

    try std.testing.expectEqual(@as(usize, 1), df.calls.len);
    try std.testing.expectEqual(decomp.value.Value{ .constant = 9 }, df.calls[0].args[0]);
    const mov_after = df.insnAt(0x100A) orelse return error.MissingMov;
    try std.testing.expectEqual(decomp.value.Value{ .constant = 77 }, mov_after.primary_val);

    // 64-bit return: umull r0, r1, r2, r3 (0xFBA2 0x0103); bx lr (0x4770)
    var ret64 = try analyzeHalfwords(&.{ 0xFBA2, 0x0103, 0x4770 }, 0x2000);
    defer ret64.deinit();
    try std.testing.expectEqual(decomp.aapcs.ReturnKind.r0_r1_pair, ret64.signature.return_kind);
    try std.testing.expectEqual(@as(u4, 0b1100), ret64.signature.used_args_mask);
    try std.testing.expectEqual(@as(usize, 1), ret64.pairs.len);

    // void leaf without touching r0
    var void_leaf = try analyzeHalfwords(&.{ 0x6001, 0x4770 }, 0x3000);
    defer void_leaf.deinit();
    try std.testing.expectEqual(decomp.aapcs.ReturnKind.none, void_leaf.signature.return_kind);
    try std.testing.expectEqual(@as(u4, 0b0011), void_leaf.signature.used_args_mask);
}

test "uart_irq_echo.elf real dataflow resolves constants, bitfields, condition pairs, and ABIs" {
    const gpa = std.testing.allocator;
    const image = try elf.Image.init(uart_elf_bytes);
    var cache = try decomp.cache.CfgCache.init(gpa, image, .{});
    defer cache.deinit();

    // 1. uart_irq_pins_init
    const pins_addr = ra8.session.symbols.addressOf(image, "uart_irq_pins_init").?;
    const pins_df = try cache.getDataflow(pins_addr);
    try std.testing.expect(pins_df.converged);
    try std.testing.expectEqual(@as(u4, 0), pins_df.signature.used_args_mask);
    try std.testing.expectEqual(decomp.aapcs.ReturnKind.r0, pins_df.signature.return_kind);
    try std.testing.expect(pins_df.calls.len >= 2);
    try std.testing.expectEqualStrings("ra8_pfs_route_peripheral", pins_df.calls[0].target_name.?);
    try std.testing.expectEqual(decomp.value.Value{ .constant = 0x0D02 }, pins_df.calls[0].args[0]);
    try std.testing.expectEqual(decomp.value.Value{ .constant = 4 }, pins_df.calls[0].args[1]);
    try std.testing.expectEqual(decomp.value.Value{ .constant = 0x0200_2B6C }, pins_df.calls[0].args[2]);

    var saw_pins_cmp = false;
    for (pins_df.cond_pairs) |cp| {
        if (cp.consumer_addr == 0x0200_0408 and cp.origin != null) {
            try std.testing.expectEqual(decomp.value.FlagKind.cmp, cp.origin.?.kind);
            try std.testing.expectEqual(@as(?u32, 0), cp.origin.?.rhs_imm);
            saw_pins_cmp = true;
        }
    }
    try std.testing.expect(saw_pins_cmp);

    // 2. uart_irq_setup_or_halt: second fw_clock_rate_for folds BFI to 0x0302 and passes sp_offset
    const setup_addr = ra8.session.symbols.addressOf(image, "uart_irq_setup_or_halt").?;
    const setup_df = try cache.getDataflow(setup_addr);
    try std.testing.expect(setup_df.converged);
    var fw_clock_count: usize = 0;
    for (setup_df.calls) |call| {
        if (call.target_name != null and std.mem.eql(u8, call.target_name.?, "fw_clock_rate_for")) {
            fw_clock_count += 1;
            if (fw_clock_count == 2) {
                try std.testing.expectEqual(decomp.value.Value{ .constant = 0x0302 }, call.args[1]);
                try std.testing.expectEqual(decomp.value.Value{ .sp_offset = -16 }, call.args[2]);
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 2), fw_clock_count);

    // 3. memcpy: used_args_mask == 0b0111, saved r4 + lr, cbz cond pairs
    const memcpy_addr = ra8.session.symbols.addressOf(image, "memcpy").?;
    const memcpy_df = try cache.getDataflow(memcpy_addr);
    try std.testing.expect(memcpy_df.converged);
    try std.testing.expectEqual(@as(u4, 0b0111), memcpy_df.signature.used_args_mask);
    try std.testing.expect((memcpy_df.signature.saved_callee_mask & ((1 << 4) | (1 << 14))) == ((1 << 4) | (1 << 14)));
    try std.testing.expect(memcpy_df.cond_pairs.len >= 2);
}
