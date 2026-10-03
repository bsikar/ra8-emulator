//! CPU1's half of a --cpu zig run (RA8EMU-234). CPU1 still gets the
//! `Second` that Unicorn runs use, because that brings up its engine (the
//! memory it shares with CPU0), its per-core wiring on the board, and its
//! loaded image. The instructions themselves run on CPU1's Zig core
//! (src/core/second_zig.zig), which takes one turn per CPU0 round. Turns
//! are sized by CPUCLK1 against CPUCLK0 (src/core/core_rate.zig), exactly as
//! on Unicorn. CPU1's own timebase (its SysTick) advances by what it ran.
const std = @import("std");
const elf = @import("elf.zig");
const engine = @import("engine.zig");
const second_core = @import("second_core.zig");
const SecondZig = @import("second_zig.zig").SecondZig;
const Board = @import("../board/board.zig").Board;
const clocks = @import("../periph/clocks.zig");
const systick_bank = @import("systick_bank.zig");

pub const Driver = struct {
    second: second_core.Second,
    core: SecondZig,
    /// CPU1's Non-secure SysTick (RA8EMU-449); `second.timebase` is its
    /// Secure one and keeps DWT_CYCCNT.
    ns_timebase: clocks.Clocks,

    /// CPU1 from the image at `path`, on `owner`'s board, ready to take
    /// turns. Built in storage the caller holds: both halves keep pointers
    /// into it.
    pub fn open(self: *Driver, allocator: std.mem.Allocator, owner: *engine.Engine, board: *Board, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const bytes = try file.readToEndAlloc(allocator, second_core.limits.image_bytes);
        defer allocator.free(bytes);
        try self.second.open(owner, board, try elf.Image.init(bytes));
        errdefer self.second.close();
        try self.core.open(&self.second, &board.bus);
        self.ns_timebase = .{ .words = systick_bank.non_secure_words };
    }

    pub fn close(self: *Driver) void {
        self.core.dropBlocks();
        self.second.close();
    }

    /// CPU1's turn for one CPU0 round of `round` instructions. A core that
    /// has stopped stays stopped, the way a faulted Unicorn CPU1 does.
    pub fn round(self: *Driver, round_size: u32) void {
        const second = &self.second;
        if (second.fault != null or second.heldInReset()) return;
        if (second.unvectored) {
            second.unvectored = false;
            self.core.cpu.reset(second.vector_base) catch |err| {
                second.fault = .{ .pc = second.vector_base, .detail = @errorName(err) };
                return;
            };
        }
        const share = second.turn(round_size);
        second.turns += 1;
        const before = self.core.cpu.retired;
        const stopped = self.core.turn(share);
        const ran = self.core.cpu.retired - before;
        second.ran += @intCast(ran);
        second.timebase.advance(second.core, @intCast(ran)) catch {};
        self.ns_timebase.advanceSysTick(second.core, @intCast(ran)) catch {};
        second.pc = self.core.cpu.regs.pc;
        if (stopped != .count) second.fault = .{ .pc = second.pc, .detail = @tagName(stopped) };
    }
};
