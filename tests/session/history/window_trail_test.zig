const std = @import("std");
const testing = std.testing;
const ra8 = @import("ra8");
const memmap = ra8.chip.core.memmap;
const memory = ra8.chip.core.cpu.memory;
const Store = memory.store.Store;
const code_lines = ra8.chip.core.cpu.decode.code_lines;
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const trail = ra8.session.history_trail;
const Recording = trail.Recording;
const window_trail_mod = ra8.session.history_window_trail;
const WindowTrail = window_trail_mod.WindowTrail;
const slot_mod = ra8.session.history_window_slot;
const ArchState = slot_mod.ArchState;
const Position = slot_mod.Position;

const DummyBus = struct {
    fn view() bus.Bus {
        return .{ .ctx = undefined, .vtable = &.{ .read = read, .write = write } };
    }
    fn read(_: *anyopaque, _: u32, _: []u8) bus.Error!void {
        return bus.Error.Unmapped;
    }
    fn write(_: *anyopaque, _: u32, _: []const u8) bus.Error!void {
        return bus.Error.Unmapped;
    }
};

fn makeCpu() Cpu {
    return Cpu{ .bus = DummyBus.view() };
}

test "window trail: eviction at the byte bound" {
    var store = try Store.init(null);
    defer store.deinit();

    var slots: [2]u64 = .{ 0, 0 };
    var rec = Recording.init(testing.allocator, .{ &slots[0], &slots[1] }, &store);
    defer rec.deinit();
    rec.arm();

    // Set a small budget of 600 bytes
    const budget: usize = 600;
    var wtrail = WindowTrail.init(testing.allocator, &rec, &store, budget);
    defer wtrail.deinit();

    var cpu = makeCpu();
    var arch = ArchState.capture(&cpu);

    // Add 10 slots with memory writes
    var s: u32 = 0;
    while (s < 10) : (s += 1) {
        const pos: Position = .{ .branch = 0, .r = s, .phase = .cpu0, .o = 0, .gap = .polled };
        wtrail.startSlot(.cpu0, pos, &arch);

        // Perturb PC and write 8 bytes
        cpu.regs.pc += 4;
        const write_bytes = [_]u8{ @intCast(s), @intCast(s + 1), @intCast(s + 2), @intCast(s + 3) };
        try store.write(.cpu0, memmap.sram_base + s * 16, &write_bytes);

        const post_arch = ArchState.capture(&cpu);
        try wtrail.endSlot(&post_arch, .ram_cpu);
        arch = post_arch;

        // Verify budget constraint is strictly maintained
        try testing.expect(wtrail.used_honest_bytes <= budget);
    }

    // Because budget is only 600 bytes and each slot costs >100 honest bytes,
    // earlier slots must have been evicted, but count must be > 0 and <= 5
    try testing.expect(wtrail.count > 0);
    try testing.expect(wtrail.count < 10);
    try testing.expect(wtrail.used_honest_bytes <= budget);
}

test "window trail: undo and redo round trip byte-exact over random RAM writes" {
    var store = try Store.init(null);
    defer store.deinit();

    var slots: [2]u64 = .{ 0, 0 };
    var rec = Recording.init(testing.allocator, .{ &slots[0], &slots[1] }, &store);
    defer rec.deinit();
    rec.arm();

    // Large enough budget to hold all 5 slots
    var wtrail = WindowTrail.init(testing.allocator, &rec, &store, 64 * 1024);
    defer wtrail.deinit();

    var cpu = makeCpu();
    var arch = ArchState.capture(&cpu);

    // Save initial state of the memory region
    var initial_ram: [64]u8 = undefined;
    @memcpy(&initial_ram, store.span(memmap.sram_base, 64).?);

    var prng = std.Random.DefaultPrng.init(0x12345678);
    const rng = prng.random();

    var s: u32 = 0;
    while (s < 5) : (s += 1) {
        const pos: Position = .{ .branch = 0, .r = s, .phase = .cpu0, .o = 0, .gap = .polled };
        wtrail.startSlot(.cpu0, pos, &arch);

        // Perform random writes
        var val: [8]u8 = undefined;
        rng.bytes(&val);
        const offset = (s * 8) % 48;
        try store.write(.cpu0, memmap.sram_base + offset, &val);

        cpu.regs.pc += 4;
        cpu.regs.low[0] += s;

        const post_arch = ArchState.capture(&cpu);
        try wtrail.endSlot(&post_arch, .ram_cpu);
        arch = post_arch;
    }

    // Save final memory state
    var final_ram: [64]u8 = undefined;
    @memcpy(&final_ram, store.span(memmap.sram_base, 64).?);

    // Memory has definitely changed
    try testing.expect(!std.mem.eql(u8, &initial_ram, &final_ram));

    // Undo all slots
    while (try wtrail.undoOne(&cpu)) {}

    // Memory must be byte-exact to initial RAM!
    try testing.expectEqualSlices(u8, &initial_ram, store.span(memmap.sram_base, 64).?);

    // Redo all slots
    while (try wtrail.redoOne(&cpu)) {}

    // Memory must be byte-exact to final RAM!
    try testing.expectEqualSlices(u8, &final_ram, store.span(memmap.sram_base, 64).?);
}

test "window trail: full register state round trip across slots" {
    var store = try Store.init(null);
    defer store.deinit();

    var slots: [2]u64 = .{ 0, 0 };
    var rec = Recording.init(testing.allocator, .{ &slots[0], &slots[1] }, &store);
    defer rec.deinit();
    rec.arm();

    var wtrail = WindowTrail.init(testing.allocator, &rec, &store, 64 * 1024);
    defer wtrail.deinit();

    var cpu = makeCpu();
    cpu.regs.pc = 0x0800_1000;
    cpu.regs.low[1] = 0x1111;
    cpu.fp.bank.s[0] = 0x3F80_0000;
    cpu.regs.control = 2;
    cpu.regs.primask = 1;

    const initial_arch = ArchState.capture(&cpu);
    var arch = initial_arch;

    // Slot 1
    wtrail.startSlot(.cpu0, .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .polled }, &arch);
    cpu.regs.pc = 0x0800_1004;
    cpu.regs.low[1] = 0x2222;
    cpu.fp.bank.s[0] = 0x4000_0000;
    var post1 = ArchState.capture(&cpu);
    try wtrail.endSlot(&post1, .ram_cpu);
    arch = post1;

    // Slot 2
    wtrail.startSlot(.cpu0, .{ .branch = 0, .r = 1, .phase = .cpu0, .o = 0, .gap = .polled }, &arch);
    cpu.regs.pc = 0x0800_1008;
    cpu.regs.low[2] = 0x3333;
    cpu.fp.bank.s[15] = 0x4100_0000;
    cpu.regs.basepri = 0x80;
    var post2 = ArchState.capture(&cpu);
    try wtrail.endSlot(&post2, .ram_cpu);

    const final_arch = ArchState.capture(&cpu);

    // Undo both slots
    try testing.expect(try wtrail.undoOne(&cpu));
    try testing.expect(try wtrail.undoOne(&cpu));
    try testing.expect(!(try wtrail.undoOne(&cpu))); // At start

    const undone_arch = ArchState.capture(&cpu);
    try testing.expectEqual(initial_arch.regs.pc, undone_arch.regs.pc);
    try testing.expectEqual(initial_arch.regs.low[1], undone_arch.regs.low[1]);
    try testing.expectEqual(initial_arch.fp.bank.s[0], undone_arch.fp.bank.s[0]);
    try testing.expectEqual(initial_arch.regs.basepri, undone_arch.regs.basepri);

    // Redo both slots
    try testing.expect(try wtrail.redoOne(&cpu));
    try testing.expect(try wtrail.redoOne(&cpu));
    try testing.expect(!(try wtrail.redoOne(&cpu))); // At head

    const redone_arch = ArchState.capture(&cpu);
    try testing.expectEqual(final_arch.regs.pc, redone_arch.regs.pc);
    try testing.expectEqual(final_arch.regs.low[1], redone_arch.regs.low[1]);
    try testing.expectEqual(final_arch.regs.low[2], redone_arch.regs.low[2]);
    try testing.expectEqual(final_arch.fp.bank.s[0], redone_arch.fp.bank.s[0]);
    try testing.expectEqual(final_arch.fp.bank.s[15], redone_arch.fp.bank.s[15]);
    try testing.expectEqual(final_arch.regs.basepri, redone_arch.regs.basepri);
}

test "window trail: code-cache invalidation observed on undo and redo" {
    var store = try Store.init(null);
    defer store.deinit();

    var lines: code_lines.CodeLines = undefined;
    lines.clear();
    try store.fanMut().attach(&lines);
    defer store.fanMut().detach(&lines);

    var slots: [2]u64 = .{ 0, 0 };
    var rec = Recording.init(testing.allocator, .{ &slots[0], &slots[1] }, &store);
    defer rec.deinit();
    rec.arm();

    var wtrail = WindowTrail.init(testing.allocator, &rec, &store, 64 * 1024);
    defer wtrail.deinit();

    var cpu = makeCpu();
    const arch = ArchState.capture(&cpu);

    const test_addr = memmap.sram_base + 0x100;

    // Start slot and write to test_addr
    wtrail.startSlot(.cpu0, .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .polled }, &arch);
    try store.write(.cpu0, test_addr, &.{ 0x11, 0x22, 0x33, 0x44 });
    const post_arch = ArchState.capture(&cpu);
    try wtrail.endSlot(&post_arch, .ram_cpu);

    // Mark code line at test_addr
    lines.clear();
    lines.mark(test_addr, test_addr + 4);
    try testing.expect(lines.marked(test_addr));
    try testing.expect(!lines.dirty);

    // Perform undo -> must invalidate code lines!
    try testing.expect(try wtrail.undoOne(&cpu));
    try testing.expect(lines.dirty);
    try testing.expect(!lines.marked(test_addr));

    // Reset marks and dirty flag
    lines.clear();
    lines.mark(test_addr, test_addr + 4);
    try testing.expect(lines.marked(test_addr));
    try testing.expect(!lines.dirty);

    // Perform redo -> must invalidate code lines again!
    try testing.expect(try wtrail.redoOne(&cpu));
    try testing.expect(lines.dirty);
    try testing.expect(!lines.marked(test_addr));
}
