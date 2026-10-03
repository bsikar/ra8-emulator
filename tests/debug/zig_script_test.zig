//! Tests for src/debug/zig_script.zig: one script on the Unicorn session
//! and on the Zig core, over the program tests/debug/session_test.zig uses,
//! prints one transcript.
const std = @import("std");
const ra8 = @import("ra8");

const bus = ra8.core.cpu.bus;
const Cpu = ra8.core.cpu.cpu.Cpu;
const commands = ra8.core.commands;
const memmap = ra8.core.memmap;
const session = ra8.core.debug_session;
const stop_machine = ra8.core.stop_machine;
const step_hook = ra8.core.step_hook;
const zig_script = step_hook.zig_script;
const Engine = ra8.core.engine.Engine;

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
    \\break 0x22000008 3
    \\run
    \\info registers
    \\x 0x22000054 2
    \\p 0x22000054
    \\step
    \\step
    \\next
    \\finish
    \\bt
    \\tbreak 0x22000022
    \\continue
    \\continue
    \\delete 1
    \\break nowhere
    \\delete 7
    \\continue
    \\quit
    \\step
;

/// 8 KiB of SRAM at sram_base.
const Sram = struct {
    bytes: [0x2000]u8 = [_]u8{0} ** 0x2000,

    fn view(self: *Sram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn slice(self: *Sram, address: u32, len: usize) bus.Error![]u8 {
        if (address < image.base or address - image.base + len > self.bytes.len) return bus.Error.Unmapped;
        return self.bytes[address - image.base ..][0..len];
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Sram = @ptrCast(@alignCast(ctx));
        @memcpy(into, try self.slice(address, into.len));
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Sram = @ptrCast(@alignCast(ctx));
        @memcpy(try self.slice(address, from.len), from);
    }
};

fn play(target: anytype, into: *std.ArrayList(u8)) !void {
    var lines = std.mem.splitScalar(u8, script, '\n');
    while (lines.next()) |line| {
        const command = (try commands.parse(line)) orelse continue;
        if (try target.apply(command, into.writer()) == .quit) return;
    }
}

fn unicorn(into: *std.ArrayList(u8)) !void {
    var engine = try Engine.open();
    defer engine.close();
    try engine.mapBoardRam();
    try engine.write(image.base, &image.bytes);
    try engine.setRegister(.sp, image.stack);
    var machine: stop_machine.Machine = .{};
    var driver: step_hook.Driver = .{ .machine = &machine };
    try step_hook.attach(engine.handle, &driver, true);
    var target: session.Session = .{ .core = &engine, .driver = &driver, .entry = image.reset, .budget = image.budget };
    try play(&target, into);
}

fn zig(into: *std.ArrayList(u8)) !void {
    var memory: Sram = .{};
    @memcpy(memory.bytes[0..image.bytes.len], &image.bytes);
    var cpu: Cpu = .{ .bus = memory.view() };
    cpu.regs.xpsr = ra8.core.cpu.regs.xpsr_bits.thumb;
    var machine: stop_machine.Machine = .{};
    var target: zig_script.ZigScript = .{ .session = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = image.budget } };
    target.session.core.setRegister(.sp, image.stack);
    target.session.core.setRegister(.pc, image.reset & ~@as(u32, 1));
    try play(&target, into);
}

test "a script prints the same transcript on the Zig core as on Unicorn" {
    var expected = std.ArrayList(u8).init(std.testing.allocator);
    defer expected.deinit();
    try unicorn(&expected);
    var got = std.ArrayList(u8).init(std.testing.allocator);
    defer got.deinit();
    try zig(&got);
    try std.testing.expect(std.mem.indexOf(u8, expected.items, "Breakpoint 1, 0x22000008") != null);
    try std.testing.expectEqualStrings(expected.items, got.items);
}

test "a command the Zig core does not carry out yet says so" {
    var memory: Sram = .{};
    var cpu: Cpu = .{ .bus = memory.view() };
    var machine: stop_machine.Machine = .{};
    var target: zig_script.ZigScript = .{ .session = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 1 } };
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    _ = try target.apply(.{ .halting = true }, out.writer());
    try std.testing.expectEqualStrings("error: Unsupported\n", out.items);
}

test "core 1 with no second core says so and the session carries on" {
    var memory: Sram = .{};
    var cpu: Cpu = .{ .bus = memory.view() };
    var machine: stop_machine.Machine = .{};
    var target: zig_script.ZigScript = .{ .session = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 1 } };
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectEqual(.more, try target.apply(.{ .core = 1 }, out.writer()));
    try std.testing.expectEqualStrings("error: CoreNotAttached\n", out.items);
}
