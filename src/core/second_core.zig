//! The second core: CPU1 put in front of the same board as CPU0.
//!
//! The RA8D2 carries two Cortex-M cores against ONE board. CPU0 comes out of
//! reset owning the part; CPU1 is started by CPU0 and, in every image in this
//! tree, runs as a permanent-Non-secure controller out of its own ELF. Up to
//! now this model could only step one of them, so the four dual-core images
//! ran with their second half missing: `cpu1_pingpong_ipc_cpu1` spun 799993
//! times on a semaphore nobody was ever going to release, and the run called
//! that a clean pass.
//!
//! TWO ENGINES, ONE BOARD, and that is the whole design. The second engine
//! is mapped onto the board RAM the first already owns
//! (`Engine.shareBoardRamWith`), so a store CPU1 makes in shared SRAM is
//! there for CPU0 with nothing in between, and it is attached to the SAME
//! peripheral bus, so IPCSEM and the IPC channels are one block that both
//! cores reach rather than two models kept in step. That is the point of the
//! pingpong app and it is what the silicon does.
//!
//! WHAT CPU0 KEEPS. Modelled time is charged once, by CPU0: it owns the time
//! base, the board tick and the interrupt controller, and CPU1 runs with
//! neither a clock of its own nor exception dispatch. Two cores charging the
//! same clocks would run modelled time at twice the rate for no reason, and
//! an NVIC per core is a real modelling decision this slice does not need to
//! make to get the handshake running. CPU1 therefore executes, reads and
//! writes, and reaches the same peripherals; it does not yet take
//! interrupts. Said plainly here so a later slice does not read the silence
//! as an oversight.
//!
//! THE INTERLEAVE IS ROUND ROBIN at the chunk boundary: CPU0 runs a round,
//! then CPU1 runs a round, until CPU0's budget is spent or something ends
//! its run. It is not concurrency and does not pretend to be. What it buys
//! is the only thing the firmware actually needs: neither core can spin
//! forever without the other getting a turn, so a handshake completes.
const std = @import("std");
const engine = @import("engine.zig");
const elf = @import("elf.zig");
const cadence = @import("cadence.zig");

const Board = @import("../board/board.zig").Board;
const wiring = @import("../board/wiring.zig");
const Engine = engine.Engine;

pub const limits = struct {
    /// Instructions one core runs before the other gets its turn. The chunk
    /// boundary, so a round is one of CPU0's boundaries and the board ticks
    /// between turns rather than inside one.
    pub const round: u32 = cadence.instructions;

    /// Ceiling on a second core's image, the same one CPU0's loader uses.
    pub const image_bytes: usize = 64 * 1024 * 1024;
};

/// CPU1: its own engine and image, sharing CPU0's board.
pub const Second = struct {
    core: Engine,
    /// Where this core resumes on its next turn.
    pc: u32 = 0,
    /// Instructions handed to it so far, which is what it was offered
    /// rather than what it retired: a turn that faults is still charged.
    ran: usize = 0,
    /// Turns taken, so a report can say whether it ever got going.
    turns: usize = 0,
    /// What stopped it, once. A faulted core takes no further turns: it is
    /// halted, the way a core that has taken an unrecoverable fault is.
    fault: ?engine.Fault = null,
    watch: engine.Watch = .{},
    /// Where its vectors were found, for the report.
    vector_base: u32 = 0,
    /// Bytes its image put in memory.
    written: u32 = 0,

    /// Open CPU1 against the board `owner` already holds, load its image and
    /// reset it out of its own vector table. The caller attaches the board
    /// afterwards, because the board is the caller's.
    /// The order here is the order `main` brings CPU0 up in: share the
    /// board RAM, go on the bus, then write the image on top. The board is
    /// joined with `attachSecond`, which repeats the per-core wiring only:
    /// the blocks are registered once, on the one bus, so both cores reach
    /// the same IPCSEM and the same IPC channels.
    pub fn open(owner: *Engine, board: *Board, image: elf.Image) !Second {
        var self = Second{ .core = try Engine.open() };
        errdefer self.core.close();
        try self.core.shareBoardRamWith(owner);
        try self.core.attachWatch(&self.watch);
        try wiring.attachSecond(board, &self.core);
        self.written = try self.core.loadImage(image);
        self.vector_base = image.vectorBase() orelse return error.NoVectorTable;
        try self.core.resetFromVectorTable(self.vector_base);
        self.pc = try self.core.register(.pc);
        return self;
    }

    pub fn close(self: *Second) void {
        self.core.close();
    }

    /// One turn. A core that has faulted stays halted rather than being
    /// restarted into the same fault every round.
    pub fn step(self: *Second, instructions: usize) void {
        if (self.fault != null) return;
        self.turns += 1;
        const outcome = self.core.run(self.pc, instructions, .{ .watch = &self.watch }) catch |err| {
            self.fault = .{ .pc = self.pc, .detail = @errorName(err), .access = null, .instruction = null };
            return;
        };
        if (outcome) |taken| {
            self.fault = taken;
            return;
        }
        self.ran += instructions;
        self.pc = self.core.register(.pc) catch self.pc;
    }
};

/// CPU1, when a path was named for it, read and reset and ready for its
/// first turn. Null when the run is a single-core one, which is every image
/// that does not name a second ELF.
///
/// The board is NOT attached here: the board belongs to the caller, and a
/// core that reaches the peripheral bus has to be put on the bus the caller
/// built. `main` does that on the returned engine.
pub fn start(allocator: std.mem.Allocator, owner: *Engine, board: *Board, path: ?[]const u8) !?Second {
    const named = path orelse return null;
    const file = try std.fs.cwd().openFile(named, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, limits.image_bytes);
    return try Second.open(owner, board, try elf.Image.init(bytes));
}

/// Run CPU0 to its budget, giving CPU1 a turn between rounds.
///
/// With no second core this is `Engine.run` and nothing else, which is what
/// every single-core image gets: same call, same budget, same boundaries.
pub fn interleave(
    cpu0: Engine,
    entry: u32,
    budget: usize,
    session: engine.Session,
    second: ?*Second,
) engine.Error!?engine.Fault {
    const other = second orelse return cpu0.run(entry, budget, session);
    var pc = entry;
    var remaining = budget;
    while (remaining > 0) {
        const round = @min(@as(usize, limits.round), remaining);
        if (try cpu0.run(pc, round, session)) |taken| return taken;
        remaining -= round;
        pc = try cpu0.register(.pc);
        if (ended(cpu0, session)) break;
        other.step(limits.round);
    }
    return null;
}

/// The conditions `Engine.run` itself stops a run on, re-read here because
/// the interleave calls it a round at a time and would otherwise hand the
/// same spent run another round.
fn ended(cpu0: Engine, session: engine.Session) bool {
    if (session.brk) |point| if (point.reached) return true;
    if (session.undefined_sites) |found| if (found.stoppedAt() != null) return true;
    if (session.stop) |watch| if (watch.met(cpu0.readWord(watch.address) catch null)) return true;
    if (session.deadline) |due| if (session.timebase) |clock| {
        if (due.met(clock.ticks)) return true;
    };
    return false;
}

/// What CPU1 did, printed under CPU0's own account of the run.
pub fn report(out: anytype, second: ?*const Second) !void {
    const other = second orelse return;
    try out.print(
        "CPU1: loaded {d} bytes, vectors at 0x{X:0>8}, ran {d} instructions over {d} turn(s), pc 0x{X:0>8}\n",
        .{ other.written, other.vector_base, other.ran, other.turns, other.pc },
    );
    if (other.fault) |taken| {
        try out.print("CPU1: halted at 0x{X:0>8}: {s}\n", .{ taken.pc, taken.detail });
    }
}
