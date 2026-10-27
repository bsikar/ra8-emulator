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

    const budget: usize = 600;
    var wtrail = WindowTrail.init(testing.allocator, &rec, &store, budget);
    defer wtrail.deinit();

    var cpu = makeCpu();
    var arch = ArchState.capture(&cpu);

    var s: u32 = 0;
    while (s < 10) : (s += 1) {
        const pos: Position = .{ .branch = 0, .r = s, .phase = .cpu0, .o = 0, .gap = .polled };
        wtrail.startSlot(.cpu0, pos, &arch);

        cpu.regs.pc += 4;
        const write_bytes = [_]u8{ @intCast(s), @intCast(s + 1), @intCast(s + 2), @intCast(s + 3) };
        try store.write(.cpu0, memmap.sram_base + s * 16, &write_bytes);

        const post_arch = ArchState.capture(&cpu);
        try wtrail.endSlot(&post_arch, .ram_cpu);
        arch = post_arch;

        try testing.expect(wtrail.used_honest_bytes <= budget);
    }

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

    var wtrail = WindowTrail.init(testing.allocator, &rec, &store, 64 * 1024);
    defer wtrail.deinit();

    var cpu = makeCpu();
    var arch = ArchState.capture(&cpu);

    var initial_ram: [64]u8 = undefined;
    @memcpy(&initial_ram, store.span(memmap.sram_base, 64).?);

    var prng = std.Random.DefaultPrng.init(0x12345678);
    const rng = prng.random();

    var s: u32 = 0;
    while (s < 5) : (s += 1) {
        const pos: Position = .{ .branch = 0, .r = s, .phase = .cpu0, .o = 0, .gap = .polled };
        wtrail.startSlot(.cpu0, pos, &arch);

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

    var final_ram: [64]u8 = undefined;
    @memcpy(&final_ram, store.span(memmap.sram_base, 64).?);
    try testing.expect(!std.mem.eql(u8, &initial_ram, &final_ram));

    while (try wtrail.undoOne(&cpu, null)) {}
    try testing.expectEqualSlices(u8, &initial_ram, store.span(memmap.sram_base, 64).?);

    while (try wtrail.redoOne(&cpu, null)) {}
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
    cpu.regs.low[2] = 0x5555;
    cpu.fp.bank.s[0] = 0x3F80_0000;
    cpu.regs.control = 2;
    cpu.regs.primask = 1;
    cpu.slots = 100;
    cpu.retired = 90;

    const initial_arch = ArchState.capture(&cpu);
    var arch = initial_arch;

    wtrail.startSlot(.cpu0, .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .polled }, &arch);
    cpu.regs.pc = 0x0800_1004;
    cpu.regs.low[1] = 0x2222;
    cpu.fp.bank.s[0] = 0x4000_0000;
    cpu.slots = 101;
    cpu.retired = 91;
    var post1 = ArchState.capture(&cpu);
    try wtrail.endSlot(&post1, .ram_cpu);
    arch = post1;

    wtrail.startSlot(.cpu0, .{ .branch = 0, .r = 1, .phase = .cpu0, .o = 0, .gap = .polled }, &arch);
    cpu.regs.pc = 0x0800_1008;
    cpu.regs.low[2] = 0x3333;
    cpu.fp.bank.s[15] = 0x4100_0000;
    cpu.regs.basepri = 0x80;
    cpu.slots = 102;
    cpu.retired = 92;
    var post2 = ArchState.capture(&cpu);
    try wtrail.endSlot(&post2, .ram_cpu);

    const final_arch = ArchState.capture(&cpu);

    try testing.expect(try wtrail.undoOne(&cpu, null));
    try testing.expect(try wtrail.undoOne(&cpu, null));
    try testing.expect(!(try wtrail.undoOne(&cpu, null)));

    const undone_arch = ArchState.capture(&cpu);
    try testing.expectEqual(initial_arch.regs.pc, undone_arch.regs.pc);
    try testing.expectEqual(initial_arch.regs.low[1], undone_arch.regs.low[1]);
    try testing.expectEqual(initial_arch.regs.low[2], undone_arch.regs.low[2]);
    try testing.expectEqual(initial_arch.fp.bank.s[0], undone_arch.fp.bank.s[0]);
    try testing.expectEqual(initial_arch.regs.basepri, undone_arch.regs.basepri);
    try testing.expectEqual(@as(u64, 100), cpu.slots);
    try testing.expectEqual(@as(u64, 90), cpu.retired);

    try testing.expect(try wtrail.redoOne(&cpu, null));
    try testing.expect(try wtrail.redoOne(&cpu, null));
    try testing.expect(!(try wtrail.redoOne(&cpu, null)));

    const redone_arch = ArchState.capture(&cpu);
    try testing.expectEqual(final_arch.regs.pc, redone_arch.regs.pc);
    try testing.expectEqual(final_arch.regs.low[1], redone_arch.regs.low[1]);
    try testing.expectEqual(final_arch.regs.low[2], redone_arch.regs.low[2]);
    try testing.expectEqual(final_arch.fp.bank.s[0], redone_arch.fp.bank.s[0]);
    try testing.expectEqual(final_arch.fp.bank.s[15], redone_arch.fp.bank.s[15]);
    try testing.expectEqual(final_arch.regs.basepri, redone_arch.regs.basepri);
    try testing.expectEqual(@as(u64, 102), cpu.slots);
    try testing.expectEqual(@as(u64, 92), cpu.retired);
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
    wtrail.startSlot(.cpu0, .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .polled }, &arch);
    try store.write(.cpu0, test_addr, &.{ 0x11, 0x22, 0x33, 0x44 });
    const post_arch = ArchState.capture(&cpu);
    try wtrail.endSlot(&post_arch, .ram_cpu);

    lines.clear();
    lines.mark(test_addr, test_addr + 4);
    try testing.expect(lines.marked(test_addr));
    try testing.expect(!lines.dirty);

    try testing.expect(try wtrail.undoOne(&cpu, null));
    try testing.expect(lines.dirty);
    try testing.expect(!lines.marked(test_addr));

    lines.clear();
    lines.mark(test_addr, test_addr + 4);
    try testing.expect(lines.marked(test_addr));
    try testing.expect(!lines.dirty);

    try testing.expect(try wtrail.redoOne(&cpu, null));
    try testing.expect(lines.dirty);
    try testing.expect(!lines.marked(test_addr));
}

const MockPart = struct {
    last_addr: u32 = 0,
    written: [4]u8 = @splat(0),
    fn raw(ctx: *anyopaque, address: u32, bytes: []const u8) void {
        const self: *MockPart = @ptrCast(@alignCast(ctx));
        self.last_addr = address;
        @memcpy(self.written[0..bytes.len], bytes);
    }
};

test "window trail: part write classified complex, undo restores, redo requires re-execution" {
    var store = try Store.init(null);
    defer store.deinit();

    var slots: [2]u64 = .{ 0, 0 };
    var rec = Recording.init(testing.allocator, .{ &slots[0], &slots[1] }, &store);
    defer rec.deinit();

    var mock: MockPart = .{};
    const part_idx = try rec.addPart(.{ .ctx = &mock, .raw = MockPart.raw });
    const part_obs = try rec.partObserver(part_idx);

    var wtrail = WindowTrail.init(testing.allocator, &rec, &store, 64 * 1024);
    defer wtrail.deinit();

    var cpu = makeCpu();
    const arch = ArchState.capture(&cpu);

    wtrail.startSlot(.cpu0, .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .polled }, &arch);

    // Write to part with 64-bit offset >= 4 GiB
    const large_offset: u64 = 0x1_0000_2000;
    part_obs.bytes(.{ .base = 0, .offset = large_offset, .initiator = .cpu0, .pre = &.{ 0xDE, 0xAD } });
    mock.written[0..2].* = .{ 0xBE, 0xEF };

    const post_arch = ArchState.capture(&cpu);
    try wtrail.endSlot(&post_arch, .ram_cpu);

    // Slot with part write must be classified as complex
    try testing.expectEqual(slot_mod.SlotKind.complex, wtrail.slotAt(0).slot.kind);

    // Undo: part raw write called with pre-bytes and 64-bit offset without panic
    try testing.expect(try wtrail.undoOne(&cpu, null));
    try testing.expectEqual(@as(u32, 0x0000_2000), mock.last_addr);
    try testing.expectEqual(@as(u8, 0xDE), mock.written[0]);
    try testing.expectEqual(@as(u8, 0xAD), mock.written[1]);

    // Redo: must refuse fake byte-swap and require re-execution!
    try testing.expectError(error.RequiresReExecution, wtrail.redoOne(&cpu, null));
}

test "window trail: structural barrier stops undo" {
    var store = try Store.init(null);
    defer store.deinit();

    var slots: [2]u64 = .{ 0, 0 };
    var rec = Recording.init(testing.allocator, .{ &slots[0], &slots[1] }, &store);
    defer rec.deinit();
    rec.arm();

    var wtrail = WindowTrail.init(testing.allocator, &rec, &store, 64 * 1024);
    defer wtrail.deinit();

    var cpu = makeCpu();
    const arch = ArchState.capture(&cpu);

    wtrail.startSlot(.cpu0, .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .polled }, &arch);
    store.wipe(); // emits .wipe barrier
    const post_arch = ArchState.capture(&cpu);
    try wtrail.endSlot(&post_arch, .ram_cpu);

    try testing.expectEqual(slot_mod.SlotKind.barrier, wtrail.slotAt(0).slot.kind);
    try testing.expectError(error.BarrierReached, wtrail.undoOne(&cpu, null));
}

test "window trail: large memory write (>256 bytes) chunked without heap alloc" {
    var store = try Store.init(null);
    defer store.deinit();

    var slots: [2]u64 = .{ 0, 0 };
    var rec = Recording.init(testing.allocator, .{ &slots[0], &slots[1] }, &store);
    defer rec.deinit();
    rec.arm();

    var wtrail = WindowTrail.init(testing.allocator, &rec, &store, 64 * 1024);
    defer wtrail.deinit();

    var cpu = makeCpu();
    const arch = ArchState.capture(&cpu);

    var big_write: [512]u8 = undefined;
    @memset(&big_write, 0x77);

    wtrail.startSlot(.cpu0, .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .polled }, &arch);
    try store.write(.cpu0, memmap.sram_base, &big_write);
    const post_arch = ArchState.capture(&cpu);
    try wtrail.endSlot(&post_arch, .ram_cpu);

    try testing.expect(try wtrail.undoOne(&cpu, null));
    try testing.expectEqual(@as(u8, 0), store.span(memmap.sram_base, 1).?[0]);
    try testing.expect(try wtrail.redoOne(&cpu, null));
    try testing.expectEqual(@as(u8, 0x77), store.span(memmap.sram_base, 1).?[0]);
}
