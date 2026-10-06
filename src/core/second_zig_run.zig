//! CPU1's half of a --cpu zig run (RA8EMU-234). CPU0 runs on its own store,
//! so CPU1 gets a store of its own that borrows CPU0's shared SRAM, and no
//! engine is opened for it (RA8EMU-588); its `Second` only carries its run
//! state and units. The engine arm is gone (RA8EMU-607). The Zig half reads
//! and writes only through CPU1's memory.Guest (RA8EMU-535). The
//! instructions themselves run on CPU1's Zig core
//! (src/core/second_zig.zig), which takes one turn per CPU0 round. Turns
//! are sized by CPUCLK1 against CPUCLK0 (src/core/core_rate.zig). CPU1's own timebase (its SysTick) advances by what it ran.
const std = @import("std");
const elf = @import("elf.zig");
const second_core = @import("second_core.zig");
const SecondZig = @import("second_zig.zig").SecondZig;
const Board = @import("../board/board.zig").Board;
const clocks = @import("../periph/clocks.zig");
const systick_bank = @import("systick_bank.zig");
const second_zig = @import("second_zig.zig");
const Store = @import("cpu/memory/store.zig").Store;
const Guest = @import("cpu/memory/guest.zig").Guest;

pub const Driver = struct {
    second: second_core.Second,
    core: SecondZig,
    /// CPU1's Non-secure SysTick (RA8EMU-449); `second.state.timebase` is its
    /// Secure one and keeps DWT_CYCCNT.
    ns_timebase: clocks.Clocks,
    /// CPU1's own store; `second`'s engine is never opened (RA8EMU-588).
    /// Null only once `close` has dropped it.
    store: ?Store,
    /// The board CPU1's store is handed to, so INTSELR events reach CPU1's
    /// NVIC and DTC1 (RA8EMU-614). Null before `open` and after `close`.
    board: ?*Board,
    /// Fractional CPU1 cycles carried between fixed-cadence rounds.
    cycle_remainder: u64 = 0,
    /// CPU1 cycles charged by the last round, for the shared 1 ns wall clock
    /// (RA8EMU-643).
    last_ran: u64 = 0,

    /// CPU1 from the image at `path`, on `board`, ready to take
    /// turns. `memory` is CPU0's store; CPU1 borrows its shared SRAM. Built
    /// in storage the caller holds: both halves keep pointers into it.
    pub fn open(self: *Driver, allocator: std.mem.Allocator, board: *Board, path: []const u8, memory: Guest) !void {
        const lender = memory.store;
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const bytes = try file.readToEndAlloc(allocator, second_core.limits.image_bytes);
        defer allocator.free(bytes);
        const image = try elf.Image.init(bytes);
        self.ns_timebase = .{ .words = systick_bank.non_secure_words };
        self.store = null;
        self.board = null;
        self.cycle_remainder = 0;
        return self.openOwn(lender, board, image);
    }

    fn openOwn(self: *Driver, lender: *const Store, board: *Board, image: elf.Image) !void {
        self.second = .{};
        self.store = try Store.init(lender);
        errdefer self.dropStore();
        const units = &self.second;
        const seeded = try second_zig.bringUp(&self.core, .{ .store = &self.store.?, .master = .cpu1 }, board, .{
            .partitions = &units.partitions,
            .regions = &units.regions,
            .guard = &units.guard,
            .control = &units.control,
            .clears = &units.clears,
        }, image);
        units.state = .{
            .written = seeded.written,
            .vector_base = seeded.vector_base,
            .interrupts = .{ .vector_base = seeded.vector_base },
            .dividers = &board.tree.divcr2,
            .board = board,
            .pc = self.core.cpu.regs.pc,
        };
        if (board.reboot) |pending| units.state.resets_seen = pending.performed;
        self.handTo(board);
    }

    /// Give `board` CPU1's store, so events INTSELR routes to CPU1 pend
    /// CPU1's NVIC and run DTC1 (board/boundary.zig). A CPU1 reset keeps
    /// the same store, so the handle stays good until `close`.
    pub fn handTo(self: *Driver, board: *Board) void {
        self.board = board;
        board.cpu1 = .{ .store = &self.store.? };
    }

    fn dropStore(self: *Driver) void {
        if (self.board) |board| board.cpu1 = null;
        self.board = null;
        if (self.store) |*owned| owned.deinit();
        self.store = null;
    }

    pub fn close(self: *Driver) void {
        self.core.dropBlocks();
        self.dropStore();
    }

    /// CPU1's memory, for what reads it after the run.
    pub fn guest(self: *const Driver) Guest {
        return self.core.memory.asMaster(.none);
    }

    fn held(self: *Driver) bool {
        return self.second.state.heldInReset(self.core.memory);
    }

    /// CPU1's turn for one CPU0 round of `round` instructions. A core that
    /// has stopped stays stopped.
    pub fn round(self: *Driver, round_size: u32) void {
        self.roundAt(round_size, clocks.timebase.default_hz);
    }

    /// CPU1's turn with retired instructions charged at its running rate.
    pub fn roundAt(self: *Driver, round_size: u32, hz: u64) void {
        self.last_ran = 0;
        if (round_size == 0) return;
        const second = &self.second;
        if (second.state.fault != null or self.held()) return;
        if (second.state.unvectored) {
            second.state.unvectored = false;
            self.core.cpu.reset(second.state.vector_base) catch |err| {
                second.state.fault = .{ .pc = second.state.vector_base, .detail = @errorName(err) };
                return;
            };
        }
        const share = second.state.turn(round_size);
        second.state.turns += 1;
        const before = self.core.cpu.retired;
        const stopped = self.core.turn(share);
        const ran = self.core.cpu.retired - before;
        second.state.ran += @intCast(ran);
        const value = ran * hz + self.cycle_remainder;
        self.cycle_remainder = value % clocks.timebase.default_hz;
        const cycles: u32 = @intCast(value / clocks.timebase.default_hz);
        self.last_ran = cycles;
        second.state.timebase.advance(self.core.memory, cycles) catch {};
        self.ns_timebase.advanceSysTick(self.core.memory, cycles) catch {};
        second.state.pc = self.core.cpu.regs.pc;
        second.takeResetRequest(self.core.memory);
        if (stopped != .count) second.state.fault = .{ .pc = second.state.pc, .detail = @tagName(stopped) };
    }
    pub fn advanceTime(self: *Driver, cycles: u64) void {
        var left = cycles;
        while (left != 0) {
            const piece: u32 = @intCast(@min(left, std.math.maxInt(u32)));
            self.second.state.timebase.advance(self.core.memory, piece) catch {};
            self.ns_timebase.advanceSysTick(self.core.memory, piece) catch {};
            left -= piece;
        }
    }
};
