//! `--cpu lockstep --cpu1` (RA8EMU-235). CPU1's Unicorn engine runs on the
//! board as the oracle, the way `--cpu unicorn --cpu1` brings it up, and a
//! lockstep `Pair` checks CPU1's Zig core against it. CPU0's lockstep run
//! calls `round` every `Run.round` of its instructions; CPU1 then checks
//! its share of that round at its own clock rate, as `--cpu zig` does.
//!
//! The ELF bytes are kept for the whole run because the Zig side loads the
//! same image once CPU0's Zig-side engine exists.
const std = @import("std");
const engine = @import("../../engine.zig");
const elf = @import("../../elf.zig");
const second_core = @import("../../second_core.zig");
const Board = @import("../../../board/board.zig").Board;
const run_mod = @import("run.zig");
const report = @import("report.zig");
const Pair = @import("second.zig").Pair;

pub const Cpu1 = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    second: second_core.Second,
    pair: Pair,
    attached: bool = false,

    /// Read CPU1's ELF at `path` and bring CPU1 up on Unicorn beside
    /// `owner`, CPU0's Unicorn engine. Opened in place.
    pub fn open(self: *Cpu1, allocator: std.mem.Allocator, owner: *engine.Engine, board: *Board, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        self.allocator = allocator;
        self.attached = false;
        self.bytes = try file.readToEndAlloc(allocator, second_core.limits.image_bytes);
        errdefer allocator.free(self.bytes);
        try self.second.open(owner, board, try elf.Image.init(self.bytes));
    }

    /// Open CPU1's Zig side, sharing SRAM with `mine0`, CPU0's Zig side.
    pub fn attach(self: *Cpu1, mine0: *engine.Engine) !void {
        return self.attachWith(mine0, try elf.Image.init(self.bytes));
    }

    /// `attach` with the image named, or none when CPU1's code is already
    /// in shared SRAM.
    pub fn attachWith(self: *Cpu1, mine0: *engine.Engine, image: ?elf.Image) !void {
        try self.pair.open(mine0, self.second.core, image, self.second.state.vector_base);
        self.attached = true;
    }

    pub fn close(self: *Cpu1) void {
        if (self.attached) self.pair.close();
        self.second.close();
        self.allocator.free(self.bytes);
    }

    pub fn between(self: *Cpu1) run_mod.Between {
        return .{ .context = self, .roundFn = roundThunk };
    }

    /// Check CPU1's share of a CPU0 round of `instructions`.
    pub fn round(self: *Cpu1, instructions: u32) !void {
        const share = self.second.state.turn(instructions);
        self.second.state.turns += 1;
        const before = self.pair.cpu.retired;
        try self.pair.turn(share);
        self.second.state.ran += @intCast(self.pair.cpu.retired - before);
        self.second.state.pc = self.pair.cpu.regs.pc;
    }

    /// True when CPU1's check found nothing wrong.
    pub fn clean(self: *const Cpu1) bool {
        return self.pair.ended == null;
    }

    pub fn write(self: *const Cpu1, out: anytype) !void {
        try out.print("cpu1: {d} instructions checked over {d} turns\n", .{ self.second.state.ran, self.second.state.turns });
        try out.writeAll("cpu1 ");
        try report.write(out, &self.pair.lock, self.pair.ended orelse .budget);
        try out.print("cpu1 lockstep: {d} peripheral access(es) replayed and matched\n", .{self.pair.log.matched});
        try self.pair.lock.counts.writeTable(out);
    }
};

fn roundThunk(context: *anyopaque, instructions: u32) anyerror!void {
    const self: *Cpu1 = @ptrCast(@alignCast(context));
    return self.round(instructions);
}
