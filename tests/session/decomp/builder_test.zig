//! Covers src/session/decomp/builder.zig.
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

fn buildHalfwords(halves: []const u16, entry: u32, extent: ?decomp.extents.FunctionExtent) !decomp.cfg.Cfg {
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

    return decomp.builder.build(gpa, .{
        .bus = rom.view(),
        .decode_cache = dc,
        .entry = entry,
        .extent = extent,
    });
}

test "builder reconstructs diamond branch and merges join block without duplicates" {
    // 0x00: cmp r0,#0 (0x2800)
    // 0x02: beq +4 -> 0x0A (0xD002)
    // 0x04: movs r0,#1 (0x2001)
    // 0x06: b +2 -> 0x0C (0xE001)
    // 0x08: nop (unreachable gap)
    // 0x0A: movs r0,#2 (0x2002)
    // 0x0C: bx lr (0x4770)
    var cfg = try buildHalfwords(&.{ 0x2800, 0xD002, 0x2001, 0xE001, 0xBF00, 0x2002, 0x4770 }, 0x0, null);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 4), cfg.blocks.len);
    const join = cfg.blockAt(0x0C) orelse return error.MissingJoin;
    try std.testing.expectEqual(@as(usize, 2), cfg.blockById(join).?.preds.len);
    try std.testing.expect(cfg.blockAt(0x08) == null);
}

test "builder splits a straight run when a backward loop targets mid-block" {
    // 0x00: movs r0,#0 (0x2000)  <- entry
    // 0x02: adds r0,#1 (0x3001)  <- loop header
    // 0x04: cmp r0,#4  (0x2804)
    // 0x06: blt -8 -> 0x02 (0xDBFC: 0x06 + 4 + (-4 * 2) = 0x02)
    // 0x08: bx lr      (0x4770)
    var cfg = try buildHalfwords(&.{ 0x2000, 0x3001, 0x2804, 0xDBFC, 0x4770 }, 0x0, null);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 3), cfg.blocks.len);
    const loop_id = cfg.blockAt(0x02) orelse return error.MissingLoopBlock;
    const loop_blk = cfg.blockById(loop_id).?;
    try std.testing.expectEqual(@as(usize, 2), loop_blk.preds.len);
    try std.testing.expectEqual(@as(u32, 0x00), cfg.blocks[0].start);
    try std.testing.expectEqual(@as(u32, 0x02), cfg.blocks[0].end);
}

test "builder extends past 32-instruction block cap and across IT conditional returns" {
    var halves: [40]u16 = undefined;
    @memset(halves[0..38], 0xBF00);
    halves[38] = 0x2000;
    halves[39] = 0x4770;
    var capped = try buildHalfwords(&halves, 0x100, null);
    defer capped.deinit();
    try std.testing.expectEqual(@as(usize, 2), capped.blocks.len);
    try std.testing.expectEqual(@as(usize, 40), capped.instructionCount());

    // 0x00: itt eq (0xBF04); 0x02: moveq r0,#1; 0x04: bxeq lr; 0x06: movs r0,#0; 0x08: bx lr
    var it_cfg = try buildHalfwords(&.{ 0xBF04, 0x2001, 0x4770, 0x2000, 0x4770 }, 0x0, null);
    defer it_cfg.deinit();
    try std.testing.expect(it_cfg.blockAt(0x06) != null);
}

test "builder records unresolved indirect calls, vtable loads, and table jumps without literal pool bleed" {
    // 0x00: blx r3 (0x4798)
    // 0x02: ldr.w pc, [r0, #4] (0xF8D0 0xF004)
    // 0x06..0x09: trailing literal word 0x12345678 inside extent (must not be decoded!)
    var ind = try buildHalfwords(
        &.{ 0x4798, 0xF8D0, 0xF004, 0x5678, 0x1234 },
        0x100,
        .{ .entry = 0x100, .size = 10, .name = "dispatch" },
    );
    defer ind.deinit();

    try std.testing.expectEqual(@as(usize, 2), ind.blocks.len);
    try std.testing.expectEqual(@as(usize, 2), ind.unresolved.len);
    try std.testing.expectEqual(decode.block.flow.UnresolvedReason.indirect_call, ind.unresolved[0].reason);
    try std.testing.expectEqual(decode.block.flow.UnresolvedReason.pc_memory_load, ind.unresolved[1].reason);
    try std.testing.expectEqual(@as(usize, 2), ind.instructionCount());

    // TBB stops block and omits inline jump table bytes from CFG
    var tbb = try buildHalfwords(
        &.{ 0xE8D0, 0xF000, 0x0201, 0x0403 },
        0x200,
        .{ .entry = 0x200, .size = 8, .name = "switch_fn" },
    );
    defer tbb.deinit();
    try std.testing.expectEqual(@as(usize, 1), tbb.blocks.len);
    try std.testing.expectEqual(decode.block.flow.UnresolvedReason.table_branch, tbb.unresolved[0].reason);
}

test "builder reconstructs real uart_irq_echo.elf functions with resolved symbol edges" {
    const gpa = std.testing.allocator;
    const image = try elf.Image.init(uart_elf_bytes);
    const list = try decomp.extents.collect(gpa, image);
    defer gpa.free(list);

    var ib: decomp.image_bus.ImageBus = .{ .image = image };
    const dc = try gpa.create(decode.cache.DecodeCache);
    defer gpa.destroy(dc);
    dc.* = .{};

    const main_ext = for (list) |e| {
        if (e.name != null and std.mem.eql(u8, e.name.?, "main")) break e;
    } else return error.MissingMain;

    var main_cfg = try decomp.builder.build(gpa, .{
        .image = image,
        .bus = ib.view(),
        .decode_cache = dc,
        .extents = list,
        .entry = main_ext.entry,
    });
    defer main_cfg.deinit();

    try std.testing.expectEqualStrings("main", main_cfg.name.?);
    try std.testing.expect(main_cfg.blocks.len >= 1);
    var saw_setup_call = false;
    var saw_back_edge = false;
    for (main_cfg.blocks) |blk| {
        for (blk.succs) |edge| {
            if (edge.kind == .call and edge.target_name != null and
                std.mem.eql(u8, edge.target_name.?, "uart_irq_setup_or_halt"))
            {
                saw_setup_call = true;
            }
            if (edge.target_block) |dst| {
                if (dst <= blk.id) saw_back_edge = true;
            }
        }
    }
    try std.testing.expect(saw_setup_call);
    try std.testing.expect(saw_back_edge);

    const setup_ext = for (list) |e| {
        if (e.name != null and std.mem.eql(u8, e.name.?, "uart_irq_setup_or_halt")) break e;
    } else return error.MissingSetup;
    var setup_cfg = try decomp.builder.build(gpa, .{
        .image = image,
        .bus = ib.view(),
        .decode_cache = dc,
        .extents = list,
        .entry = setup_ext.entry,
    });
    defer setup_cfg.deinit();
    var saw_pins_call = false;
    for (setup_cfg.blocks) |blk| {
        for (blk.succs) |edge| {
            if (edge.kind == .call and edge.target_name != null and
                std.mem.eql(u8, edge.target_name.?, "uart_irq_pins_init"))
            {
                saw_pins_call = true;
            }
        }
    }
    try std.testing.expect(saw_pins_call);

    // __aeabi_memcpy veneer tail-branches outside its 4-byte extent to memcpy
    const memcpy_veneer = for (list) |e| {
        if (e.name != null and std.mem.startsWith(u8, e.name.?, "__aeabi_memcpy")) break e;
    } else return error.MissingMemcpyVeneer;
    var veneer_cfg = try decomp.builder.build(gpa, .{
        .image = image,
        .bus = ib.view(),
        .decode_cache = dc,
        .extents = list,
        .entry = memcpy_veneer.entry,
    });
    defer veneer_cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), veneer_cfg.blocks.len);
    try std.testing.expectEqual(decomp.cfg.EdgeKind.tail_call, veneer_cfg.blocks[0].succs[0].kind);
    try std.testing.expectEqualStrings("memcpy", veneer_cfg.blocks[0].succs[0].target_name.?);

    const memcpy_ext = for (list) |e| {
        if (e.name != null and std.mem.eql(u8, e.name.?, "memcpy")) break e;
    } else return error.MissingMemcpy;
    var memcpy_cfg = try decomp.builder.build(gpa, .{
        .image = image,
        .bus = ib.view(),
        .decode_cache = dc,
        .extents = list,
        .entry = memcpy_ext.entry,
    });
    defer memcpy_cfg.deinit();
    try std.testing.expect(memcpy_cfg.blocks.len >= 3);
}
