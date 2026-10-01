//! `--break-sym`'s break counted through the stop machine: the same
//! arrivals, the same stop, and the same counts the report prints as when
//! the hook counted them itself.
const std = @import("std");
const ra8 = @import("ra8");

const memmap = ra8.core.memmap;
const break_hook = ra8.core.break_hook;
const breakpoint = ra8.core.breakpoint;
const Engine = ra8.core.engine.Engine;

/// A three-instruction loop in SRAM: nop, nop, b back to the first nop.
const layout = struct {
    const code: u32 = memmap.sram_base;
    const second: u32 = code + 2;
    const stack: u32 = memmap.sram_base + 0x1F00;
    const budget: usize = 32;
};

const program = [_]u8{ 0x00, 0xBF, 0x00, 0xBF, 0xFC, 0xE7 };

fn openEngine() !Engine {
    var engine = try Engine.open();
    errdefer engine.close();
    try engine.mapBoardRam();
    try engine.write(layout.code, &program);
    try engine.setRegister(.sp, layout.stack);
    return engine;
}

test "arrivals count up to the wanted one, then keep counting without stopping again" {
    var point = breakpoint.Break{ .address = layout.second, .arrival = 2 };
    var linked = break_hook.link(&point);
    try std.testing.expect(!linked.arrive(layout.second, 2));
    try std.testing.expect(!point.reached);
    try std.testing.expect(linked.arrive(layout.second, 2));
    try std.testing.expect(point.reached);
    try std.testing.expect(!linked.arrive(layout.second, 2));
    try std.testing.expectEqual(@as(u32, 3), point.seen);
    try std.testing.expect(point.reached);
}

test "a run stops on the third arrival with the break unrun" {
    var engine = try openEngine();
    defer engine.close();
    var point = breakpoint.Break{ .address = layout.second, .arrival = 3 };
    try break_hook.attach(engine.handle, &point);
    _ = try engine.runChunk(layout.code, layout.budget, null);
    try std.testing.expectEqual(layout.second, try engine.register(.pc));
    try std.testing.expectEqual(@as(u32, 3), point.seen);
    try std.testing.expect(point.reached);
}

test "a break on the first instruction counts that first arrival" {
    var engine = try openEngine();
    defer engine.close();
    var point = breakpoint.Break{ .address = layout.code | breakpoint.limits.thumb_bit };
    try break_hook.attach(engine.handle, &point);
    _ = try engine.runChunk(layout.code, layout.budget, null);
    try std.testing.expectEqual(layout.code, try engine.register(.pc));
    try std.testing.expectEqual(@as(u32, 1), point.seen);
    try std.testing.expect(point.reached);
}

test "a run that spends its budget first reports how many arrivals it saw" {
    var engine = try openEngine();
    defer engine.close();
    var point = breakpoint.Break{ .address = layout.second, .arrival = 100 };
    try break_hook.attach(engine.handle, &point);
    _ = try engine.runChunk(layout.code, layout.budget, null);
    try std.testing.expect(!point.reached);
    try std.testing.expect(point.seen > 0);
    try std.testing.expect(point.seen < point.arrival);
}
