//! CPU1's half of a --cpu zig run (RA8EMU-234). When CPU0 runs on its own
//! store, CPU1 gets a store of its own that borrows CPU0's shared SRAM, and
//! no engine is opened for it (RA8EMU-588); its `Second` then only carries
//! its run state and units. Otherwise CPU1 still gets the engine-backed
//! `Second` that Unicorn runs use. Either way the Zig half reads and writes
//! only through CPU1's memory.Guest (RA8EMU-535). The instructions themselves run on CPU1's Zig core
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
const second_zig = @import("second_zig.zig");
const Store = @import("cpu/memory/store.zig").Store;
const Guest = @import("cpu/memory/guest.zig").Guest;

pub const Driver = struct {
    second: second_core.Second,
    core: SecondZig,
    /// CPU1's Non-secure SysTick (RA8EMU-449); `second.state.timebase` is its
    /// Secure one and keeps DWT_CYCCNT.
    ns_timebase: clocks.Clocks,
    /// CPU1's own store when CPU0 runs on one; `second`'s engine is then
    /// never opened (RA8EMU-588).
    store: ?Store,

    /// CPU1 from the image at `path`, on `owner`'s board, ready to take
    /// turns. `memory` is CPU0's: on a store, CPU1 borrows its shared SRAM.
    /// Built in storage the caller holds: both halves keep pointers into it.
    pub fn open(self: *Driver, allocator: std.mem.Allocator, owner: *engine.Engine, board: *Board, path: []const u8, memory: Guest) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const bytes = try file.readToEndAlloc(allocator, second_core.limits.image_bytes);
        defer allocator.free(bytes);
        const image = try elf.Image.init(bytes);
        self.ns_timebase = .{ .words = systick_bank.non_secure_words };
        self.store = null;
        switch (memory) {
            .store => |lender| return self.openOwn(lender, board, image),
            .engine => {},
        }
        try self.second.open(owner, board, image);
        errdefer self.second.close();
        try self.core.open(&self.second, &board.bus);
    }

    fn openOwn(self: *Driver, lender: *const Store, board: *Board, image: elf.Image) !void {
        self.second = .{ .core = undefined };
        self.store = try Store.init(lender);
        errdefer self.dropStore();
        const units = &self.second;
        const seeded = try second_zig.bringUp(&self.core, .{ .store = &self.store.? }, board, .{
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
    }

    fn dropStore(self: *Driver) void {
        if (self.store) |*owned| owned.deinit();
        self.store = null;
    }

    pub fn close(self: *Driver) void {
        self.core.dropBlocks();
        if (self.store != null) return self.dropStore();
        self.second.close();
    }

    /// CPU1's memory, for what reads it after the run.
    pub fn guest(self: *const Driver) Guest {
        return self.core.memory;
    }

    fn held(self: *Driver) bool {
        if (self.store != null) return self.second.state.heldInReset(self.core.memory);
        return self.second.heldInReset();
    }

    /// CPU1's turn for one CPU0 round of `round` instructions. A core that
    /// has stopped stays stopped, the way a faulted Unicorn CPU1 does.
    pub fn round(self: *Driver, round_size: u32) void {
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
        second.state.timebase.advance(self.core.memory, @intCast(ran)) catch {};
        self.ns_timebase.advanceSysTick(self.core.memory, @intCast(ran)) catch {};
        second.state.pc = self.core.cpu.regs.pc;
        if (stopped != .count) second.state.fault = .{ .pc = second.state.pc, .detail = @tagName(stopped) };
    }
};
