//! Tests for src/debug/watch_bus.zig: watchpoints and DWT data matches on
//! the Zig core stop where they stopped on Unicorn before RA8EMU-605.
const std = @import("std");
const ra8 = @import("ra8");

const bus = ra8.core.cpu.bus;
const Cpu = ra8.core.cpu.cpu.Cpu;
const commands = ra8.core.commands;
const memmap = ra8.core.memmap;
const session = ra8.core.debug_session;
const stop_machine = ra8.core.stop_machine;
const step_hook = ra8.core.step_hook;
const watch_bus = step_hook.watch_bus;
const zig_drive = step_hook.zig_drive;
const zig_script = step_hook.zig_script;
const dwt = ra8.core.dwt;

/// The program tests/debug/zig_script_test.zig uses: a loop at +0x18
/// calling a helper at +0x8 that adds r0 into the word at 0x22000054.
const image = struct {
    const base: u32 = memmap.sram_base;
    const reset: u32 = base + 0x18;
    const stack: u32 = memmap.sram_base + 0x1F00;
    const budget: usize = 400;
    const bytes = [_]u8{
        0x00, 0x00, 0x01, 0x22, 0x19, 0x00, 0x00, 0x22, 0x02, 0x49, 0x0a, 0x68, 0x10,
        0x44, 0x08, 0x60, 0x70, 0x47, 0x00, 0xbf, 0x54, 0x00, 0x00, 0x22, 0x10, 0xb5,
        0x00, 0x24, 0x05, 0x2c, 0x04, 0xd0, 0x20, 0x46, 0xff, 0xf7, 0xf1, 0xff, 0x01,
        0x34, 0xf8, 0xe7, 0x01, 0x20, 0xff, 0xf7, 0xec, 0xff, 0xfb, 0xe7, 0x70, 0x47,
    };
};

const script =
    \\watch 0x22000054
    \\run
    \\continue
    \\info registers
    \\delete 1
    \\rwatch 0x22000054
    \\continue
    \\quit
;

/// 8 KiB of SRAM at sram_base and the DWT's page, both plain memory.
const Memory = struct {
    sram: [0x2000]u8 = [_]u8{0} ** 0x2000,
    ppb: [0x1000]u8 = [_]u8{0} ** 0x1000,

    fn view(self: *Memory) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn slice(self: *Memory, address: u32, len: usize) bus.Error![]u8 {
        if (address >= image.base and address - image.base + len <= self.sram.len) return self.sram[address - image.base ..][0..len];
        if (address >= dwt.base and address - dwt.base + len <= self.ppb.len) return self.ppb[address - dwt.base ..][0..len];
        return bus.Error.Unmapped;
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        @memcpy(into, try self.slice(address, into.len));
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        @memcpy(try self.slice(address, from.len), from);
    }
};

/// A Zig core on `memory` with the debugger listening.
const Rig = struct {
    memory: Memory = .{},
    machine: stop_machine.Machine = .{},
    driver: step_hook.Driver = undefined,
    watching: watch_bus.WatchBus = undefined,
    cpu: Cpu = undefined,

    fn wire(self: *Rig) void {
        self.driver = .{ .machine = &self.machine };
        self.watching = .{ .inner = self.memory.view(), .driver = &self.driver };
        self.cpu = .{ .bus = self.watching.view() };
        self.cpu.regs.xpsr = ra8.core.cpu.regs.xpsr_bits.thumb;
    }
};

fn play(target: anytype, into: *std.ArrayList(u8)) !void {
    var lines = std.mem.splitScalar(u8, script, '\n');
    while (lines.next()) |line| {
        const command = (try commands.parse(line)) orelse continue;
        if (try target.apply(command, into.writer()) == .quit) return;
    }
}

fn zig(into: *std.ArrayList(u8)) !void {
    var rig: Rig = .{};
    rig.wire();
    @memcpy(rig.memory.sram[0..image.bytes.len], &image.bytes);
    var target: zig_script.ZigScript = .{ .session = .{ .core = .{ .cpu = &rig.cpu }, .machine = &rig.machine, .budget = image.budget, .watch = &rig.watching } };
    target.session.core.setRegister(.sp, image.stack);
    target.session.core.setRegister(.pc, image.reset & ~@as(u32, 1));
    try play(&target, into);
}

/// What this script printed on the Unicorn session before RA8EMU-605
/// retired it, kept so the Zig core stays held to it.
const transcript =
    \\Watchpoint 1 (write) at 0x22000054
    \\Watchpoint 1: write of 4 at 0x22000054, 0x22000010: bx lr
    \\Watchpoint 1: write of 4 at 0x22000054, 0x22000010: bx lr
    \\r0  0x00000001  r1  0x22000054  r2  0x00000000  r3  0x00000000
    \\r12 0x00000000  sp  0x22001EF8  lr  0x22000027  pc  0x22000010
    \\Deleted watchpoint 1
    \\Watchpoint 2 (read) at 0x22000054
    \\Watchpoint 2: read of 4 at 0x22000054, 0x2200000C: add r0, r2
    \\
;

test "a write and a read watchpoint stop on the instruction they stopped on under Unicorn" {
    var got = std.ArrayList(u8).init(std.testing.allocator);
    defer got.deinit();
    try zig(&got);
    try std.testing.expect(std.mem.indexOf(u8, got.items, "Watchpoint 1: write") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.items, "Watchpoint 2: read") != null);
    try std.testing.expectEqualStrings(transcript, got.items);
}

test "firmware that arms a DWT write comparator halts after the store on the Zig core" {
    var rig: Rig = .{};
    rig.wire();
    rig.machine.dwt.trcena = true;
    const code: u32 = image.base;
    const data: u32 = image.base + 0x1000;
    const function = dwt.match.data_write | (dwt.function_bits.action_debug << dwt.function_bits.action_shift) | (2 << dwt.function_bits.size_shift);
    // str r1,[r0,#0x20] (DWT_COMP0); str r2,[r0,#0x28] (DWT_FUNCTION0); str r4,[r3]; nop; nop.
    @memcpy(rig.memory.sram[0..10], &[_]u8{ 0x01, 0x62, 0x82, 0x62, 0x1C, 0x60, 0x00, 0xBF, 0x00, 0xBF });
    const core: step_hook.zig_core.ZigCore = .{ .cpu = &rig.cpu };
    core.setRegister(.pc, code);
    core.setRegister(.sp, image.stack);
    core.setRegister(.r0, dwt.base);
    core.setRegister(.r1, data);
    core.setRegister(.r2, function);
    core.setRegister(.r3, data);
    core.setRegister(.r4, 0x77);
    rig.machine.begin();
    const ended = zig_drive.runWatched(core, &rig.machine, 32, &rig.watching);
    try std.testing.expectEqual(@as(usize, 0), ended.stop.unit_watch);
    try std.testing.expectEqual(code + 6, core.register(.pc));
    try std.testing.expectEqual(@as(u32, 0x77), try core.readWord(data));
}

test "an instruction's own fetch is not an access" {
    var rig: Rig = .{};
    rig.wire();
    const code: u32 = image.base + 0x100;
    @memcpy(rig.memory.sram[0x100..0x108], &[_]u8{ 0x00, 0xBF, 0x00, 0xBF, 0x00, 0xBF, 0x00, 0xBF });
    _ = try rig.machine.addWatch(try ra8.core.watch_table.Watch.span(code, 4, .access));
    const core: step_hook.zig_core.ZigCore = .{ .cpu = &rig.cpu };
    core.setRegister(.pc, code);
    rig.machine.begin();
    try std.testing.expectEqual(.count, std.meta.activeTag(zig_drive.runWatched(core, &rig.machine, 3, &rig.watching)));
}

test "the core's fault latch passes through as a latch, not a store" {
    var under = @import("latch_bus.zig").Latches{};
    var watching = watch_bus.WatchBus{ .inner = under.view(), .driver = undefined };
    try watching.view().latch(0xE000_ED28, 1 << 25);
    try std.testing.expectEqual(@as(u32, 1 << 25), under.latched);
    try std.testing.expectEqual(@as(u32, 0), under.writes);
}
