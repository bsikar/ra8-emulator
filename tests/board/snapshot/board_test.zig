//! RA8EMU-688: a whole attached board saved and loaded into a freshly
//! attached one matches byte for byte, and a file from another part, or one
//! without a part section, is refused before anything changes.
const std = @import("std");

const ra8 = @import("ra8");
const store_board = @import("../../interfaces/cli/store_board.zig");

const Board = ra8.board.board.Board;
const file = ra8.snapshot.file;
const machine_mod = ra8.chip.core.machine;
const section = ra8.board.snapshot.board;

/// A store and the board attached to it, built in place so the board's
/// wiring points at this rig and not at a copy.
const Rig = struct {
    store: store_board.Store,
    board: Board,

    fn build(rig: *Rig) !void {
        rig.store = try store_board.Store.init(null);
        errdefer rig.store.deinit();
        rig.board = Board.init(std.testing.allocator);
        errdefer rig.board.deinit();
        try store_board.attach(&rig.board, .{ .store = &rig.store });
    }

    fn deinit(rig: *Rig) void {
        rig.board.deinit();
        rig.store.deinit();
    }
};

fn saved(board: *const Board, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try section.save(board, &list.writer);
}

test "a whole board loaded into a fresh one saves the same bytes" {
    var rig: Rig = undefined;
    try rig.build();
    defer rig.deinit();
    rig.board.c6.reply = .{0x5A};
    rig.board.c6.wire.replies_sent = 6;
    var first = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer first.deinit();
    try saved(&rig.board, &first);

    var fresh: Rig = undefined;
    try fresh.build();
    defer fresh.deinit();
    try section.load(&fresh.board, first.written());
    try std.testing.expectEqual(@as(u8, 0x5A), fresh.board.c6.reply[0]);
    try std.testing.expectEqual(@as(u32, 6), @as(u32, @intCast(fresh.board.c6.wire.replies_sent)));
    var second = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer second.deinit();
    try saved(&fresh.board, &second);
    try std.testing.expectEqualSlices(u8, first.written(), second.written());
}

test "a file from another part is refused and the board is untouched" {
    var rig: Rig = undefined;
    try rig.build();
    defer rig.deinit();
    rig.board.c6.reply = .{0x5A};
    var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bytes.deinit();
    try saved(&rig.board, &bytes);

    var other: Rig = undefined;
    try other.build();
    defer other.deinit();
    other.board.part = .ra8p1;
    const before = other.board.c6.reply[0];
    try std.testing.expectError(error.WrongPart, section.load(&other.board, bytes.written()));
    try std.testing.expectEqual(before, other.board.c6.reply[0]);
}

test "a file without a part section is refused" {
    var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bytes.deinit();
    try file.writeHeader(&bytes.writer);
    var rig: Rig = undefined;
    try rig.build();
    defer rig.deinit();
    try std.testing.expectError(error.Missing, section.load(&rig.board, bytes.written()));
}

const sole_m33: machine_mod.Machine = .{
    .name = "sole-m33",
    .label = "SOLE-M33",
    .cores = .{
        .primary = machine_mod.core.cortexM33(.{
            .security = false,
            .fpu = .single,
            .systicks = 1,
        }),
    },
    .part = .ra8d2,
};

const sole_m85: machine_mod.Machine = .{
    .name = "sole-m85",
    .label = "SOLE-M85",
    .cores = .{
        .primary = machine_mod.core.cortexM85(.{
            .security = true,
            .fpu = .double,
            .systicks = 2,
        }),
    },
    .part = .ra8d2,
};

test "shipped D2 and P1 keep 1-byte part tags while non-catalog machines encode machine name" {
    var d2: Rig = undefined;
    try d2.build();
    defer d2.deinit();
    var d2_bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer d2_bytes.deinit();
    try saved(&d2.board, &d2_bytes);
    const d2_part = (try file.Reader.find(d2_bytes.written(), .part)).?;
    try std.testing.expectEqualSlices(u8, &.{0}, d2_part.payload);

    d2.board.part = .ra8p1;
    var p1_bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer p1_bytes.deinit();
    try saved(&d2.board, &p1_bytes);
    const p1_part = (try file.Reader.find(p1_bytes.written(), .part)).?;
    try std.testing.expectEqualSlices(u8, &.{1}, p1_part.payload);

    var m33: Rig = undefined;
    try m33.build();
    defer m33.deinit();
    m33.board.machine = &sole_m33;
    m33.board.c6.reply = .{0x77};
    var m33_bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer m33_bytes.deinit();
    try saved(&m33.board, &m33_bytes);
    const m33_part = (try file.Reader.find(m33_bytes.written(), .part)).?;
    try std.testing.expectEqualSlices(u8, &([_]u8{section.named_part_tag} ++ "sole-m33".*), m33_part.payload);

    var m33_fresh: Rig = undefined;
    try m33_fresh.build();
    defer m33_fresh.deinit();
    m33_fresh.board.machine = &sole_m33;
    try section.load(&m33_fresh.board, m33_bytes.written());
    try std.testing.expectEqual(@as(u8, 0x77), m33_fresh.board.c6.reply[0]);

    // Cross-target refusal in every direction before mutating board state.
    d2.board.part = .ra8d2;
    d2.board.c6.reply = .{0x11};
    try std.testing.expectError(error.WrongPart, section.load(&d2.board, m33_bytes.written()));
    try std.testing.expectEqual(@as(u8, 0x11), d2.board.c6.reply[0]);

    m33_fresh.board.c6.reply = .{0x22};
    try std.testing.expectError(error.WrongPart, section.load(&m33_fresh.board, d2_bytes.written()));
    try std.testing.expectEqual(@as(u8, 0x22), m33_fresh.board.c6.reply[0]);

    var m85: Rig = undefined;
    try m85.build();
    defer m85.deinit();
    m85.board.machine = &sole_m85;
    m85.board.c6.reply = .{0x33};
    try std.testing.expectError(error.WrongPart, section.load(&m85.board, m33_bytes.written()));
    try std.testing.expectEqual(@as(u8, 0x33), m85.board.c6.reply[0]);
}
