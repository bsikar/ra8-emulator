//! Tests for src/core/engine.zig.
const std = @import("std");
const ra8 = @import("ra8");
const clocks = ra8.periph.clocks;
const memmap = ra8.core.memmap;
const periph = ra8.periph.registry;
const mod = ra8.core.engine;

const Engine = mod.Engine;
const Watch = mod.Watch;
test "an engine opens, maps the board, and reads back what it wrote" {
    var engine = try Engine.open();
    defer engine.close();
    try engine.mapBoardRam();
    try engine.write(memmap.sram_base, &[_]u8{ 0x0D, 0xF0, 0xAD, 0x0B });
    try std.testing.expectEqual(@as(u32, 0x0BADF00D), try engine.readWord(memmap.sram_base));
    try engine.setRegister(.sp, memmap.sram_base + 0x100);
    try std.testing.expectEqual(memmap.sram_base + 0x100, try engine.register(.sp));
}

test "with the bus attached, a store into peripheral space is serviced" {
    var engine = try Engine.open();
    defer engine.close();
    try engine.mapBoardRam();

    var bus = periph.Bus.init(std.testing.allocator);
    defer bus.deinit();
    try engine.attachPeriph(&bus);

    // r0 = 0x40000000; store a byte-sized constant there and read it back.
    const code = [_]u8{
        0x40, 0xF2, 0x00, 0x00, // movw r0, #0
        0xC4, 0xF2, 0x00, 0x00, // movt r0, #0x4000
        0x55, 0x21, //             movs r1, #0x55
        0x01, 0x60, //             str  r1, [r0]
        0x02, 0x68, //             ldr  r2, [r0]
    };
    try engine.write(memmap.sram_base, &code);
    try engine.setRegister(.sp, memmap.sram_base + 0x1000);
    const fault = try engine.run(memmap.sram_base, 5, .{});
    try std.testing.expect(fault == null);
    try std.testing.expect(bus.counters.writes >= 1);
    try std.testing.expectEqual(@as(u32, 0x55), bus.read(periph.base, 4));
    try std.testing.expectEqual(@as(u32, 0x55), try engine.register(.r2));
}

test "a fault reports the address it reached for and the instruction that did it" {
    var engine = try Engine.open();
    defer engine.close();
    try engine.mapBoardRam();

    var watch = Watch{};
    try engine.attachWatch(&watch);

    // r0 = 0x90000000 (nothing is mapped there); str r1, [r0].
    const code = [_]u8{
        0x40, 0xF2, 0x00, 0x00, // movw r0, #0
        0xC9, 0xF2, 0x00, 0x00, // movt r0, #0x9000
        0x55, 0x21, //             movs r1, #0x55
        0x01, 0x60, //             str  r1, [r0]
    };
    try engine.write(memmap.sram_base, &code);
    try engine.setRegister(.sp, memmap.sram_base + 0x1000);

    const fault = (try engine.run(memmap.sram_base, 4, .{ .watch = &watch })) orelse return error.TestExpectedFault;
    const access = fault.access orelse return error.TestExpectedAccess;
    try std.testing.expectEqual(@as(u64, 0x9000_0000), access.address);
    try std.testing.expectEqual(@as(u8, 4), access.size);
    try std.testing.expect(access.kind == .write);
    try std.testing.expectEqualStrings("str r1, [r0]", (fault.instruction orelse return error.TestExpectedText).slice());
}

test "a chunked run charges the clocks and lets a CYCCNT wait finish" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();

    // What ra8_time_init arms before anything waits on the counter.
    try core.writeWord(memmap.scb.demcr, clocks.demcr_trcena);
    try core.writeWord(memmap.dwt.ctrl, clocks.dwt_ctrl_cyccntena);
    try core.writeWord(memmap.dwt.cyccnt, 0);
    try core.writeWord(memmap.syst.rvr, 99);
    try core.writeWord(memmap.syst.cvr, 99);
    try core.writeWord(memmap.syst.csr, clocks.csr_enable | clocks.csr_tickint);

    // b . : the shape of every wait loop, and what one looks like to the core.
    try core.write(memmap.sram_base, &[_]u8{ 0xFE, 0xE7 });
    try core.setRegister(.sp, memmap.sram_base + 0x1000);

    var timebase = clocks.Clocks{ .per_chunk = 64 };
    const fault = try core.run(memmap.sram_base, 256, .{ .timebase = &timebase });
    try std.testing.expect(fault == null);

    // Four chunks of 64: the cycle counter moved, so a CYCCNT wait completes.
    try std.testing.expectEqual(@as(u64, 256), timebase.cycles);
    try std.testing.expectEqual(@as(u32, 256), try core.readWord(memmap.dwt.cyccnt));
    // 256 instructions over a 100-tick period: two full periods and change.
    try std.testing.expectEqual(@as(u64, 2), timebase.ticks);
    try std.testing.expect(try core.readWord(memmap.scb.icsr) & clocks.icsr_pendstset != 0);
}

test "without a time base the run is one stretch and the clocks stand still" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    try core.writeWord(memmap.scb.demcr, clocks.demcr_trcena);
    try core.writeWord(memmap.dwt.ctrl, clocks.dwt_ctrl_cyccntena);
    try core.write(memmap.sram_base, &[_]u8{ 0xFE, 0xE7 });
    try core.setRegister(.sp, memmap.sram_base + 0x1000);

    try std.testing.expect(try core.run(memmap.sram_base, 256, .{}) == null);
    try std.testing.expectEqual(@as(u32, 0), try core.readWord(memmap.dwt.cyccnt));
}
