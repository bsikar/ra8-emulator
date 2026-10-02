//! Tests for src/core/hint_resume.zig, against a real engine.
const std = @import("std");
const ra8 = @import("ra8");
const engine = ra8.core.engine;
const memmap = ra8.core.memmap;
const hint_resume = ra8.core.hint_resume;
const Nvic = ra8.periph.nvic.Nvic;

const entry: u32 = memmap.sram_base + 0x2000;
const stack: u32 = memmap.sram_base + 0x8000;

/// A core with `words` at the entry and its stack set.
fn bench(words: []const u32) !engine.Engine {
    var core = try engine.Engine.open();
    errdefer core.close();
    try core.mapBoardRam();
    for (words, 0..) |word, index| try core.writeWord(entry + 4 * @as(u32, @intCast(index)), word);
    try core.setRegister(.sp, stack);
    return core;
}

fn runThrough(hint: u16) !void {
    // hint; movs r0, #7; movs r1, #8; b .
    var core = try bench(&.{ 0x2007_0000 | @as(u32, hint), 0xE7FE_2108 });
    defer core.close();
    var unit = Nvic{};
    const ended = try core.run(entry, 20, .{ .interrupts = &unit });
    try std.testing.expect(ended == null);
    try std.testing.expectEqual(@as(u32, 7), try core.register(.r0));
    try std.testing.expectEqual(@as(u32, 8), try core.register(.r1));
    try std.testing.expectEqual(entry + 6, try core.register(.pc));
}

test "a WFE completes and the run carries on" {
    try runThrough(hint_resume.wfe);
}

test "a YIELD completes and the run carries on" {
    try runThrough(hint_resume.yield);
}

test "a core waiting in a WFE loop keeps running instead of halting" {
    // 1: wfe; b 1b
    var core = try bench(&.{0xE7FD_BF20});
    defer core.close();
    var unit = Nvic{};
    const ended = try core.run(entry, 50, .{ .interrupts = &unit });
    try std.testing.expect(ended == null);
    const pc = try core.register(.pc);
    try std.testing.expect(pc == entry or pc == entry + 2);
}

test "an undefined instruction right after a WFE is still reported" {
    // wfe; then a 32-bit encoding with no instruction behind it
    var core = try bench(&.{ 0xFFFF_BF20, 0xE7FE_FFFF });
    defer core.close();
    var unit = Nvic{};
    const ended = try core.run(entry, 20, .{ .interrupts = &unit });
    try std.testing.expect(ended != null);
    try std.testing.expectEqual(entry + 2, ended.?.pc);
}

test "before reads only the two hints" {
    var core = try bench(&.{ 0xBF40_BF20, 0xBF10_BF30 });
    defer core.close();
    try std.testing.expectEqual(hint_resume.wfe, hint_resume.before(core, entry + 2).?);
    try std.testing.expect(hint_resume.before(core, entry + 4) == null);
    try std.testing.expect(hint_resume.before(core, entry + 6) == null);
    try std.testing.expectEqual(hint_resume.yield, hint_resume.before(core, entry + 8).?);
}

test "a session that parks on WFE gets the stop back" {
    var core = try bench(&.{ 0x2007_BF20, 0xE7FE_E7FE });
    defer core.close();
    var unit = Nvic{};
    const ended = try core.run(entry, 20, .{ .interrupts = &unit, .park_on_wfe = true });
    try std.testing.expect(ended != null);
    try std.testing.expectEqual(entry + 2, ended.?.pc);
    try std.testing.expectEqual(hint_resume.wfe, hint_resume.stoppedOn(core, ended.?).?);
    try std.testing.expectEqual(@as(u32, 0), try core.register(.r0));
}
