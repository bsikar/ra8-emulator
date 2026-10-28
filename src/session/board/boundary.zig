//! The board's boundary as the debugger's run passes it (RA8EMU-709).
//! Board.tick wants the guest events are pended on; under the debugger
//! that is CPU0's memory, the same guest a plain run ticks with. CPU1's
//! lines are re-pended by the boundary itself (events.rependOn).
//! A sleeping CPU0 may reach to the board's next edge (RA8EMU-767), as a
//! plain run's idle skip does (src/interfaces/cli/zig/run.zig asleepWidth).
const Board = @import("ra8_board").board.Board;
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const Cpu = @import("ra8_chip").core.cpu.cpu.Cpu;
const Reboot = @import("ra8_chip").core.reboot.Reboot;
const systick_bank = @import("ra8_chip").core.systick_bank;
const clocks = @import("ra8_chip").periph.clocks;
const zig_boundary = @import("../zig/boundary.zig");
const second_core = @import("ra8_chip").core.second.core;
const chunk_clock = @import("../chunk_clock.zig");
const registry = @import("ra8_chip").periph.registry;
const quiet_due = @import("ra8_board").quiet_due;
const board_edge = @import("ra8_board").boundary;
const sleep_pace = @import("ra8_chip").core.sleep_pace;
const scheduler = @import("ra8_chip").core.scheduler;
const Pending = @import("ra8_chip").core.cpu.cpu.systick_cut.Pending;
const backing = @import("ra8_board").external.backing;
const std = @import("std");

pub const BoardBoundary = struct {
    board: *Board,
    core: Guest,
    cpu: ?*Cpu = null,
    reboot: ?*Reboot = null,
    timebase: clocks.Clocks = .{},
    ns_timebase: clocks.Clocks = .{ .words = systick_bank.non_secure_words },
    selected: ?*const u8 = null,
    second: ?*second_core.Second = null,
    second_memory: ?Guest = null,
    /// Told when the board takes a chunk, so events inside the next one are
    /// stamped with the board time they happened at (RA8EMU-1120).
    chunk: ?*chunk_clock.ChunkClock = null,
    saved: scheduler.State = .{},
    pair: ?*second_core.zig.run.Driver = null,
    cut: @import("ra8_chip").core.cpu.cpu.systick_cut.Cut = .{},
    idle_skip: bool = true,

    pub fn hook(self: *BoardBoundary) zig_boundary.Boundary {
        self.cut.clocks = .{ &self.timebase, &self.ns_timebase };
        return .{ .context = self, .tickFn = tick, .chunk = self.timebase.per_chunk, .sleepFn = asleep, .awakeFn = awake, .saved = &self.saved, .pair = self.pair, .cut = &self.cut, .store = self.core.store };
    }

    /// An awake CPU0's width: up to a plain run's stretch, cut to the
    /// nearest edge `asleep` would wait for or the input script's next
    /// event, so each lands on its own boundary (RA8EMU-1120). A found RTT
    /// block drains per boundary, so it keeps `normal`, as do the cases
    /// `asleep` keeps it for.
    fn awake(context: *anyopaque, normal: u32) u32 {
        const self: *BoardBoundary = @ptrCast(@alignCast(context));
        return scheduler.stretch.width(normal, &self.edges(), self.idle_skip and self.wide());
    }

    /// CPU0 alone and selected, and no block moving per boundary.
    fn wide(self: *const BoardBoundary) bool {
        if (self.second != null) return false;
        return quiet_due.quietUntilDue(self.board);
    }

    /// Cycles to each edge a chunk must not cross; zero for none.
    fn edges(self: *const BoardBoundary) [6]u64 {
        const script = if (self.board.input_script.nextDue()) |at| self.board.time.base.cyclesUntil(at) else 0;
        return .{
            self.timebase.untilWrap(self.core),
            self.ns_timebase.untilWrap(self.core),
            board_edge.cyclesToDue(self.board),
            quiet_due.vsyncDue(self.board),
            quiet_due.gptDue(self.board),
            script,
        };
    }

    /// A sleeping CPU0's width: whole chunks to the nearest SysTick wrap of
    /// either bank, queued board event, vsync or GPT edge. Board time here
    /// is one cycle per instruction, so the edges need no scaling. CPU1
    /// bound or selected, or a block that moves per boundary, keeps `normal`.
    fn asleep(context: *anyopaque, normal: u32) u32 {
        return awake(context, normal);
    }

    fn tick(context: *anyopaque, instructions: u32) anyerror!void {
        const self: *BoardBoundary = @ptrCast(@alignCast(context));
        if (self.chunk) |chunk| chunk.handOver();
        const fabric = backing.fabricOf(self.core.store);
        const cpu0_stall = if (fabric) |unit| unit.takePending(.cpu0) else 0;
        const cpu1_stall = if (fabric) |unit| unit.takePending(.cpu1) else 0;
        const ethos_stall = if (fabric) |unit| unit.takePending(.ethos_u55) else 0;
        const cpu1_ran = if (self.pair) |pair| if (self.saved.cut) @as(u64, 0) else pair.last_ran else 0;
        const duration = @max(@max(instructions +| cpu0_stall, cpu1_ran +| cpu1_stall), ethos_stall);
        if (self.pair) |pair| pair.advanceTime(duration -| cpu1_ran);
        if (fabric) |unit| unit.setWall(unit.wall +| duration);
        var left = duration;
        var pending_cut = self.saved.cut_pending;
        while (left != 0) {
            const piece: u32 = @intCast(@min(left, std.math.maxInt(u32)));
            try charge(&self.timebase, &self.ns_timebase, self.core, piece, self.saved.cut, &pending_cut);
            try self.board.tickFrom(self.core, piece, .cpu0);
            left -= piece;
        }
        if (self.board.display.output.vsync) |*vsync| try vsync.settle(self.board.time.base.now());
        const pending = self.reboot orelse return;
        if (!pending.requested) return;
        const cpu = self.cpu orelse return error.NoRebootCore;
        pending.requested = false;
        pending.performed +%= 1;
        const retired = cpu.retired;
        try cpu.reset(pending.vector_base);
        self.board.events.clearLatches();
        cpu.retired = retired;
    }
};

/// The cut's elapsed time belongs to the pre-instruction timers. The
/// triggering bank reads its old control and reload; the other stays live.
pub fn charge(timebase: *clocks.Clocks, ns_timebase: *clocks.Clocks, core: Guest, cycles: u32, cut: bool, pending: *Pending) !void {
    if (!cut) {
        try timebase.advance(core, cycles);
        return ns_timebase.advanceSysTick(core, cycles);
    }
    const prior: Prior = .{
        .core = core,
        .csr = if (pending.bank == .secure) timebase.words.csr else ns_timebase.words.csr,
        .reload = if (pending.bank == .secure) timebase.words.rvr else ns_timebase.words.rvr,
        .value = pending.old_reload,
        .control = pending.old_control,
        .counter = if (pending.bank == .secure) timebase.words.cvr else ns_timebase.words.cvr,
        .current = if (pending.current_written) &pending.old_current else null,
    };
    try timebase.advance(prior, cycles);
    try ns_timebase.advanceSysTick(prior, cycles);
}

/// One pre-instruction timer over the current guest words. Writes retain the
/// firmware's new control bits while applying the old interval's COUNTFLAG.
const Prior = struct {
    core: Guest,
    csr: u32,
    reload: u32,
    value: u32,
    control: u8,
    counter: u32,
    current: ?*u32,

    pub fn readWord(self: Prior, address: u32) !u32 {
        if (address == self.counter) if (self.current) |value| return value.*;
        if (address == self.reload) return self.value;
        if (address == self.csr) {
            const live = try self.core.readWord(address);
            return (live & ~(clocks.csr_enable | clocks.csr_tickint)) | self.control;
        }
        return self.core.readWord(address);
    }

    pub fn writeWord(self: Prior, address: u32, word: u32) !void {
        // Close advances the old interval, then the firmware's final CVR
        // store wins. Keep the intermediate value only for another piece
        // of this close; the saved pending state remains immutable.
        if (address == self.counter) if (self.current) |value| {
            value.* = word;
            return;
        };
        if (address == self.csr) {
            const live = try self.core.readWord(address);
            return self.core.writeWord(address, (live & ~clocks.csr_countflag) | (word & clocks.csr_countflag));
        }
        return self.core.writeWord(address, word);
    }
};
