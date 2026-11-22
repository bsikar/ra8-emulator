//! Covers src/session/decomp/cfg.zig.
const std = @import("std");
const ra8 = @import("ra8");

const decomp = ra8.session.decomp;

test "Cfg queries blockAt, blockContaining, blockById, and deinit cleanly" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    const aa = arena.allocator();

    const blocks = try aa.alloc(decomp.cfg.BasicBlock, 2);
    blocks[0] = .{
        .id = 0,
        .start = 0x1000,
        .end = 0x1008,
        .summary = .{ .kind = .fallthrough, .fallthrough = 0x1008 },
        .insns = &.{},
        .succs = &.{},
        .preds = &.{},
    };
    blocks[1] = .{
        .id = 1,
        .start = 0x1008,
        .end = 0x1010,
        .summary = .{ .kind = .ret },
        .insns = &.{},
        .succs = &.{},
        .preds = &.{0},
    };

    var cfg: decomp.cfg.Cfg = .{
        .arena = arena,
        .entry = 0x1000,
        .extent_size = 0x10,
        .name = try aa.dupe(u8, "sample_fn"),
        .blocks = blocks,
        .unresolved = &.{},
    };
    defer cfg.deinit();

    try std.testing.expectEqual(@as(?decomp.cfg.BlockId, 0), cfg.blockAt(0x1001));
    try std.testing.expectEqual(@as(?decomp.cfg.BlockId, 1), cfg.blockAt(0x1008));
    try std.testing.expectEqual(@as(?decomp.cfg.BlockId, null), cfg.blockAt(0x1004));
    try std.testing.expectEqual(@as(?decomp.cfg.BlockId, 0), cfg.blockContaining(0x1004));
    try std.testing.expectEqual(@as(?decomp.cfg.BlockId, 1), cfg.blockContaining(0x100A));
    try std.testing.expectEqual(@as(?decomp.cfg.BlockId, null), cfg.blockContaining(0x1010));
    try std.testing.expect(cfg.blockById(1) != null);
    try std.testing.expect(cfg.blockById(99) == null);
    try std.testing.expectEqual(@as(usize, 0), cfg.instructionCount());
}
