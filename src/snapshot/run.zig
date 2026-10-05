//! A whole run in one snapshot file (RA8EMU-689): the header, the board
//! (part first, RA8EMU-688), guest memory, then one cpu section per core,
//! 0 for CPU0 and 1 for CPU1.
//!
//! Load into a freshly built run: a fresh store, fresh cores and a freshly
//! attached board. A file from another part is refused before anything
//! changes; any later error leaves the run partly loaded, so drop it, the
//! same rule as cpu.zig and board.zig.
const file = @import("file.zig");
const memory = @import("memory.zig");
const cpu = @import("cpu.zig");
const board_snap = @import("board.zig");
const Store = @import("../core/cpu/memory/store.zig").Store;
const Cpu = @import("../core/cpu/cpu.zig").Cpu;

pub const Error = file.Error || memory.Error || cpu.Error || board_snap.Error;

pub fn save(writer: anytype, store: *const Store, cores: []const *const Cpu, board: anytype) !void {
    try file.writeHeader(writer);
    try board_snap.save(board, writer);
    try memory.save(store, writer);
    for (cores, 0..) |core, index| try cpu.save(core, @intCast(index), writer);
}

/// Fills a fresh run from a whole file. Every core asked for must have its
/// section; extra cores in the file are ignored.
pub fn load(bytes: []const u8, store: *Store, cores: []const *Cpu, board: anytype) !void {
    try board_snap.partOf(board.part, bytes);
    const section = try file.Reader.find(bytes, .memory) orelse return Error.Missing;
    try memory.load(store, section.payload);
    for (cores, 0..) |core, index| try cpu.load(core, @intCast(index), bytes);
    try board_snap.load(board, bytes);
}
