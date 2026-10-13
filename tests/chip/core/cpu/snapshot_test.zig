//! RA8EMU-658: a core run N instructions, snapshotted and restored into a
//! fresh core, runs the next M exactly as the original does.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("exception/ram.zig");
const Fake = @import("exception/fake_source.zig").Fake;
const file = ra8.snapshot.file;
const snap = ra8.chip.core.cpu.snapshot;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;

const pendsv: u9 = 14;

/// A loop that keeps r0..r3 changing: ADDS r0,#1; LSLS r1,r0,#1;
/// EORS r2,r1; ADDS r3,r2,r1; B back. PendSV runs NOPs then BX LR.
fn program(ram: *fixture.Ram) void {
    const loop = [_]u16{ 0x3001, 0x0041, 0x404A, 0x1853, 0xE7FA };
    for (loop, 0..) |half, i| ram.putHalf(fixture.code + 2 * @as(u32, @intCast(i)), half);
    for (0..6) |i| ram.putHalf(fixture.handler + 2 * @as(u32, @intCast(i)), 0xBF00);
    ram.putHalf(fixture.handler + 12, 0x4770);
    ram.putWord(fixture.base + 4 * @as(u32, pendsv), fixture.handler | 1);
}

fn snapshot(cpu: *const Cpu, core: u8, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try snap.save(cpu, core, &list.writer);
}

fn expectSame(want: *const Cpu, got: *const Cpu) !void {
    try std.testing.expectEqualDeep(want.regs, got.regs);
    try std.testing.expectEqualDeep(want.fp, got.fp);
    try std.testing.expectEqualDeep(want.banked, got.banked);
    try std.testing.expectEqual(want.retired, got.retired);
    try std.testing.expectEqual(want.slots, got.slots);
    try std.testing.expectEqual(want.sync_entries, got.sync_entries);
    try std.testing.expectEqual(want.booted, got.booted);
    try std.testing.expectEqual(want.active.depth, got.active.depth);
    try std.testing.expectEqualSlices(ra8.chip.core.cpu.exception.active.Entry, want.active.stack[0..want.active.depth], got.active.stack[0..got.active.depth]);
    try std.testing.expectEqual(want.waiting, got.waiting);
    try std.testing.expectEqual(want.exclusive, got.exclusive);
}

fn sent(context: *anyopaque) void {
    const count: *u32 = @ptrCast(@alignCast(context));
    count.* += 1;
}

test "state current both core sections preserve lifecycle counters and target event wiring" {
    try std.testing.expect(comptime snap.complete());
    var memories: [2]fixture.Ram = @splat(.{});
    var cores = [_]Cpu{ try fixture.boot(&memories[0]), .{ .bus = memories[1].view() } };
    cores[0].retired = 17;
    cores[0].slots = 23;
    cores[0].sync_entries = 6;
    var source_hits: u32 = 0;
    cores[0].event_sender = .{ .context = &source_hits, .sendFn = sent };
    var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bytes.deinit();
    try file.writeHeader(&bytes.writer);
    for (&cores, 0..) |*core, index| try snap.save(core, @intCast(index), &bytes.writer);
    for (0..2) |index| {
        var target_memory = memories[index];
        var target: Cpu = .{ .bus = target_memory.view(), .slots = 999, .sync_entries = 9, .booted = !cores[index].booted };
        var hits: u32 = 0;
        const binding: @typeInfo(@FieldType(Cpu, "event_sender")).optional.child = .{ .context = &hits, .sendFn = sent };
        target.event_sender = binding;
        try snap.load(&target, @intCast(index), bytes.written());
        try expectSame(&cores[index], &target);
        try std.testing.expect(target.event_sender.?.context == binding.context);
        try std.testing.expect(target.event_sender.?.sendFn == binding.sendFn);
        target.event_sender.?.sendFn(target.event_sender.?.context);
        try std.testing.expectEqual(@as(u32, 1), hits);
    }
    try std.testing.expectEqual(@as(u32, 0), source_hits);
}

test "state current restored zero-slot booted cores warm-reset both SCS banks" {
    for (0..2) |index| {
        var memory: fixture.Ram = .{};
        const source = try fixture.boot(&memory);
        try std.testing.expectEqual(@as(u64, 0), source.slots);
        for ([_]u32{ fixture.scs, fixture.scs_ns }) |bank| {
            memory.putWord(bank + 0xd08, fixture.base + 0x40);
            memory.putWord(bank + 0x100, 0xffffffff);
            memory.putWord(bank + 0x200, 0xffffffff);
        }
        var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer bytes.deinit();
        try snapshot(&source, @intCast(index), &bytes);
        var copy = memory;
        var target: Cpu = .{ .bus = copy.view(), .slots = 999 };
        try snap.load(&target, @intCast(index), bytes.written());
        try std.testing.expect(target.booted);
        try std.testing.expectEqual(@as(u64, 0), target.slots);
        try target.reset(fixture.base);
        for ([_]u32{ fixture.scs, fixture.scs_ns }) |bank| {
            try std.testing.expectEqual(@as(u32, 0), copy.word(bank + 0xd08));
            try std.testing.expectEqual(@as(u32, 0), copy.word(bank + 0x100));
            try std.testing.expectEqual(@as(u32, 0), copy.word(bank + 0x200));
        }
    }
}

test "state current restored never-booted cores keep first-reset SCS configuration" {
    for (0..2) |index| {
        var memory: fixture.Ram = .{};
        memory.putWord(fixture.base, fixture.msp_top);
        memory.putWord(fixture.base + 4, fixture.code | 1);
        memory.putWord(fixture.scs + 0xd08, fixture.base + 0x40);
        memory.putWord(fixture.scs_ns + 0xd08, fixture.base + 0x80);
        const source: Cpu = .{ .bus = memory.view() };
        var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer bytes.deinit();
        try snapshot(&source, @intCast(index), &bytes);
        var copy = memory;
        var target: Cpu = .{ .bus = copy.view(), .booted = true, .slots = 123 };
        try snap.load(&target, @intCast(index), bytes.written());
        try std.testing.expect(!target.booted);
        try std.testing.expectEqual(@as(u64, 0), target.slots);
        try target.reset(fixture.base);
        try std.testing.expectEqual(fixture.base + 0x40, copy.word(fixture.scs + 0xd08));
        try std.testing.expectEqual(fixture.base + 0x80, copy.word(fixture.scs_ns + 0xd08));
        try std.testing.expect(target.booted);
    }
}

test "state current previous snapshot format is rejected without CPU mutation" {
    var memory: fixture.Ram = .{};
    var core = try fixture.boot(&memory);
    var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bytes.deinit();
    try snapshot(&core, 0, &bytes);
    std.mem.writeInt(u32, bytes.written()[file.magic.len..][0..4], 5, .little);
    core.slots = 88;
    core.retired = 77;
    core.sync_entries = 11;
    const before = core;
    try std.testing.expectError(error.BadVersion, snap.load(&core, 0, bytes.written()));
    try expectSame(&before, &core);
}

test "run N, snapshot inside a handler, restore, and the next M match" {
    var ram: fixture.Ram = .{};
    program(&ram);
    var fake: Fake = .{};
    var cpu = try fixture.boot(&ram);
    cpu.source = fake.source();
    cpu.fp.bank.s[5] = 0x3F80_0000;
    _ = cpu.run(37);
    fake.pending = .{ .number = pendsv, .priority = 0x80 };
    _ = cpu.run(2);
    try std.testing.expectEqual(@as(usize, 1), cpu.active.depth);
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try snapshot(&cpu, 0, &list);
    var copy = ram; // guest memory is RA8EMU-659's; the test copies it whole
    var fresh_fake = fake;
    var fresh = try fixture.boot(&copy);
    fresh.source = fresh_fake.source();
    try snap.load(&fresh, 0, list.written());
    try expectSame(&cpu, &fresh);
    _ = cpu.run(100);
    _ = fresh.run(100);
    try std.testing.expectEqual(@as(usize, 0), cpu.active.depth);
    try expectSame(&cpu, &fresh);
    try std.testing.expectEqualSlices(u8, &ram.bytes, &copy.bytes);
}

test "each core loads its own section" {
    var ram: fixture.Ram = .{};
    program(&ram);
    var zero = try fixture.boot(&ram);
    var one = try fixture.boot(&ram);
    one.regs.low[7] = 0x1111_1111;
    zero.regs.low[7] = 0x0000_0001;
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try file.writeHeader(&list.writer);
    try snap.save(&zero, 0, &list.writer);
    try snap.save(&one, 1, &list.writer);
    var target = try fixture.boot(&ram);
    try snap.load(&target, 1, list.written());
    try std.testing.expectEqual(@as(u32, 0x1111_1111), target.regs.low[7]);
    try snap.load(&target, 0, list.written());
    try std.testing.expectEqual(@as(u32, 0x0000_0001), target.regs.low[7]);
}

test "a missing core or a cut payload leaves the core untouched" {
    var ram: fixture.Ram = .{};
    program(&ram);
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[0] = 42;
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try snapshot(&cpu, 0, &list);
    var target = try fixture.boot(&ram);
    target.regs.low[0] = 7;
    try std.testing.expectError(error.Missing, snap.load(&target, 1, list.written()));
    // Shrink the section's length so its payload ends before the stack.
    const len_at = file.magic.len + 4 + 4;
    const len = std.mem.readInt(u64, list.written()[len_at..][0..8], .little);
    std.mem.writeInt(u64, list.written()[len_at..][0..8], len - 1, .little);
    try std.testing.expectError(error.Truncated, snap.load(&target, 0, list.written()[0 .. list.written().len - 1]));
    try std.testing.expectEqual(@as(u32, 7), target.regs.low[0]);
}
