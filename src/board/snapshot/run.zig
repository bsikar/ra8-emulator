//! Whole guest runs restored by preparation followed by a non-failing commit.
//! Each core has a CPU section; CPU1's owned memory has a separate section.
const std = @import("std");
/// The format, for a run owner that adds sections of its own.
pub const file = @import("ra8_snapshot").file;
pub const fields = @import("ra8_snapshot").fields;
const memory = @import("memory.zig");
const cpu = @import("ra8_chip").core.cpu.snapshot;
const board_snap = @import("board.zig");
const Store = @import("ra8_chip").core.cpu.memory.store.Store;
const Cpu = @import("ra8_chip").core.cpu.cpu.Cpu;

pub const Error = file.Error || memory.Error || cpu.Error || board_snap.Error || error{ImageMismatch};
pub const Identity = [2]?[16]u8;

pub fn imageIdentity(bytes: []const u8) [16]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(bytes, &hash, .{});
    return hash[0..16].*;
}

pub fn save(writer: anytype, store: *const Store, cores: []const *const Cpu, board: anytype) !void {
    try savePair(writer, &.{store}, cores, board, @splat(null));
}

pub fn savePair(writer: anytype, stores: []const *const Store, cores: []const *const Cpu, board: anytype, identity: Identity) !void {
    return savePairMode(writer, stores, cores, board, identity, false);
}

pub fn savePairAttached(writer: anytype, stores: []const *const Store, cores: []const *const Cpu, board: anytype, identity: Identity) !void {
    return savePairMode(writer, stores, cores, board, identity, true);
}

fn savePairMode(writer: anytype, stores: []const *const Store, cores: []const *const Cpu, board: anytype, identity: Identity, owned: bool) !void {
    if (stores.len == 0 or stores.len > 2 or cores.len == 0 or cores.len > 2) return error.BadValue;
    try file.writeHeader(writer);
    if (owned) try board_snap.saveAttached(board, writer) else try board_snap.save(board, writer);
    for (stores, 0..) |store, index| try memory.saveAs(store, if (index == 0) .memory else .second_memory, writer);
    for (cores, 0..) |core, index| try cpu.save(core, @intCast(index), writer);
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try fields.write(&counter.writer, identity);
    try file.writeSectionHeader(writer, .image, counter.fullCount());
    try fields.write(writer, identity);
}

pub fn check(bytes: []const u8, board: anytype) !void {
    try board_snap.partOf(board.part, bytes);
    _ = try file.Reader.find(bytes, .memory) orelse return Error.Missing;
}

pub fn checkImage(bytes: []const u8, expected: Identity) !void {
    const section = try file.Reader.find(bytes, .image) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    const identity = try fields.read(Identity, &cursor);
    if (!cursor.done()) return Error.BadValue;
    for (identity, expected) |got, wanted| {
        if (wanted) |hash| if (got == null or !std.mem.eql(u8, &hash, &got.?)) return Error.ImageMismatch;
    }
}

pub fn Prepared(comptime B: type) type {
    return struct {
        board: board_snap.Prepared(B),
        memories: [2]?memory.Prepared = @splat(null),
        cores: [2]Cpu = undefined,
        count: usize = 0,

        pub fn deinit(self: *@This()) void {
            for (&self.memories) |*held| if (held.*) |*one| one.deinit();
            self.board.deinit();
        }

        pub fn commit(self: *@This(), stores: []const *Store, cores: []const *Cpu, board: *B) void {
            self.board.commit(board);
            for (stores, 0..) |store, index| self.memories[index].?.commit(store);
            for (cores, 0..) |core, index| {
                core.* = self.cores[index];
                cpu.afterRestore(core);
            }
        }
    };
}

pub fn prepare(bytes: []const u8, stores: []const *Store, cores: []const *Cpu, board: anytype, identity: Identity) !Prepared(@TypeOf(board.*)) {
    return prepareMode(bytes, stores, cores, board, identity, false);
}

pub fn prepareAttached(bytes: []const u8, stores: []const *Store, cores: []const *Cpu, board: anytype, identity: Identity) !Prepared(@TypeOf(board.*)) {
    return prepareMode(bytes, stores, cores, board, identity, true);
}

fn prepareMode(bytes: []const u8, stores: []const *Store, cores: []const *Cpu, board: anytype, identity: Identity, owned: bool) !Prepared(@TypeOf(board.*)) {
    if (stores.len == 0 or stores.len > 2 or cores.len == 0 or cores.len > 2) return Error.BadValue;
    try check(bytes, board);
    try checkImage(bytes, identity);
    var memories: [2]?memory.Prepared = @splat(null);
    errdefer for (&memories) |*held| if (held.*) |*one| one.deinit();
    for (stores, 0..) |store, index| {
        const section = try file.Reader.find(bytes, if (index == 0) .memory else .second_memory) orelse return Error.Missing;
        memories[index] = try memory.prepare(store, section.payload);
    }
    var prepared = Prepared(@TypeOf(board.*)){
        .board = if (owned) try board_snap.prepareAttached(board, bytes) else try board_snap.prepare(board, bytes),
        .memories = memories,
        .count = cores.len,
    };
    errdefer prepared.board.deinit();
    for (cores, 0..) |core, index| prepared.cores[index] = try cpu.prepare(core, @intCast(index), bytes);
    return prepared;
}

pub fn load(bytes: []const u8, store: *Store, cores: []const *Cpu, board: anytype) !void {
    var staged = try prepare(bytes, &.{store}, cores, board, @splat(null));
    defer staged.deinit();
    staged.commit(&.{store}, cores, board);
}
