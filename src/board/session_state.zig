//! Snapshot and restore for a served session (RA8EMU-768): the file
//! `--save-state` writes (src/snapshot/run.zig, the two SysTick bases and
//! a stretch section), written from and read back into a live harness.
//!
//! A session's boundary charges whole chunks, so nothing is owed and the
//! stretch section says so; `--load-state` reads the file as its own, and
//! a session restores one `--save-state` wrote. A second core is refused,
//! as the CLI refuses it: its state is not in the file yet.
const std = @import("std");
const Board = @import("board.zig").Board;
const BoardBoundary = @import("board_boundary.zig").BoardBoundary;
const Cpu = @import("../core/cpu/cpu.zig").Cpu;
const Store = @import("../core/cpu/memory/store.zig").Store;
const run_file = @import("../snapshot/run.zig");
const systick = @import("../snapshot/systick.zig");
const stretch = @import("../snapshot/stretch.zig");

/// The largest file a restore reads.
const max_bytes = 1 << 30;

pub const Error = error{SecondCoreNotSaved};

/// What the serve handlers call; paths are on the serving host.
pub const Hook = struct {
    context: *anyopaque,
    saveFn: *const fn (*anyopaque, []const u8) anyerror!void,
    restoreFn: *const fn (*anyopaque, []const u8) anyerror!void,

    pub fn save(self: Hook, path: []const u8) anyerror!void {
        return self.saveFn(self.context, path);
    }

    pub fn restore(self: Hook, path: []const u8) anyerror!void {
        return self.restoreFn(self.context, path);
    }
};

/// The parts of a harness the file holds.
pub const Files = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *Store,
    cpu: *Cpu,
    board: *Board,
    edge: *BoardBoundary,

    pub fn hook(self: *Files) Hook {
        return .{ .context = self, .saveFn = save, .restoreFn = restore };
    }

    fn save(context: *anyopaque, path: []const u8) anyerror!void {
        const self: *Files = @ptrCast(@alignCast(context));
        try self.single();
        var out = try std.Io.Dir.cwd().createFile(self.io, path, .{});
        defer out.close(self.io);
        var buffer: [4096]u8 = undefined;
        var file_writer = out.writer(self.io, &buffer);
        const writer = &file_writer.interface;
        try run_file.save(writer, self.store, &.{self.cpu}, self.board);
        try systick.save(.{ &self.edge.timebase, &self.edge.ns_timebase }, writer);
        try stretch.save(.{}, writer);
        try writer.flush();
    }

    /// The store is wiped first: a page the file leaves out was zero when
    /// it was saved, whatever the run wrote there since.
    fn restore(context: *anyopaque, path: []const u8) anyerror!void {
        const self: *Files = @ptrCast(@alignCast(context));
        try self.single();
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(max_bytes));
        defer self.allocator.free(bytes);
        try run_file.check(bytes, self.board);
        self.store.wipe();
        try run_file.load(bytes, self.store, &.{self.cpu}, self.board);
        try systick.load(.{ &self.edge.timebase, &self.edge.ns_timebase }, bytes);
    }

    fn single(self: *const Files) Error!void {
        if (self.edge.second != null) return Error.SecondCoreNotSaved;
    }
};
