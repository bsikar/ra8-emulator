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
//! WHAT CPU1 OWNS ALONE. The blocks on the bus are shared, but the windows
//! inside the core are not: a Cortex-M carries its own SAU, reached through
//! its own PPB, and two cores programme two different maps. CPU1 therefore
//! holds an SAU of its own here. Sharing one model let CPU1's bring-up land
//! on top of CPU0's: `cpu1_pingpong_ipc` programmes five regions and two
//! Non-Secure Callable entries on CPU0, and once its second half was mapped
//! the run reported five regions and NO callable entries, because CPU1 had
//! overwritten the first four with its own four. The count was right and
//! every value in it was wrong.
//!
//! THIS CORE IS NOT COPYABLE once it is open, and that is why `open` fills a
//! caller's `Second` in place instead of returning one. Its watch, its SAU
//! and its MPU guard are registered with Unicorn BY ADDRESS, so a `Second` returned by
//! value leaves both hooks pointing at the temporary they were taken from
//! and every record they make lands in freed memory.
//!
//! THE INTERLEAVE IS ROUND ROBIN at the chunk boundary: CPU0 runs a round,
//! then CPU1 runs a round, until CPU0's budget is spent or something ends
//! its run. It is not concurrency and does not pretend to be. What it buys
//! is the only thing the firmware actually needs: neither core can spin
//! forever without the other getting a turn, so a handshake completes.
const std = @import("std");
const engine = @import("engine.zig");
const elf = @import("elf.zig");
const memmap = @import("memmap.zig");
const cadence = @import("cadence.zig");
const sau = @import("../periph/sau.zig");
const mpu = @import("../periph/mpu/mpu.zig");
const mpu_guard = @import("mpu_guard.zig");
const cpuid = @import("../periph/cpuid.zig");
const scb = @import("../periph/scb.zig");
const fault_clear = @import("../periph/fault_clear.zig");
const nvic = @import("../periph/nvic.zig");
const clocks = @import("../periph/clocks.zig");
const hint_resume = @import("hint_resume.zig");
const second_wait = @import("second_wait.zig");

const Board = @import("../board/board.zig").Board;
const wiring = @import("../board/wiring.zig");
const report_cores = @import("../interfaces/cli/report_cores.zig");
const Engine = engine.Engine;

/// CPU1's turn length against CPU0's round, from the CPU clock dividers.
pub const rate = @import("core_rate.zig");

/// VTOR resets to the core's initial vector base (CPU1INITVTOR for CPU1), not
/// to zero. The PPB is per-engine RAM here, so the word written lands in this
/// core's System Control Space only and CPU0's VTOR is left as it was.
pub fn primeVectorTable(core: Engine, base: u32) !void {
    try core.writeWord(memmap.scb.vtor, base);
}

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
    /// This core's own Security Attribution Unit. Core-private state, not a
    /// block on the shared bus: the header says what sharing one cost.
    partitions: sau.Sau = sau.Sau.init(),
    /// This core's own MPU table and the guard that enforces it, for the
    /// same reason: a Cortex-M's MPU sits behind its own PPB, so CPU0
    /// programming its regions must leave CPU1's untouched.
    regions: mpu.Mpu = mpu.Mpu.init(),
    guard: mpu_guard.Guard = mpu_guard.Guard.init(),
    /// CPU1's own AIRCR model: its PRIGROUP and its reset requests are its
    /// own, polled after each of its turns.
    control: scb.Scb = scb.Scb.init(),
    /// CPU1's own owed CFSR/HFSR clears, applied after each of its turns.
    clears: fault_clear.Clears = fault_clear.Clears.init(),
    /// CPU1's own NVIC: its own pends, priorities and active stack. CPU0's
    /// is the one `main` builds; neither ever dispatches the other's.
    interrupts: nvic.Nvic = .{},
    /// CPU1's own time base: its SysTick counts down on CPU1's own PPB
    /// words and pends into CPU1's own ICSR, charged for CPU1's own turns.
    timebase: clocks.Clocks = .{},
    /// The board's SCKDIVCR2, read each round to size CPU1's turn against
    /// CPU0's (`rate.turn`). Null outside a board, where a turn is a round.
    dividers: ?*const u16 = null,
    /// Parked in WFE, and what woke it: src/core/second_wait.zig.
    wait: second_wait.Wait = .{},
    /// Where its vectors were found, for the report.
    vector_base: u32 = 0,
    /// Bytes its image put in memory.
    written: u32 = 0,

    /// Open CPU1 against the board `owner` already holds, load its image and
    /// reset it out of its own vector table.
    ///
    /// IN PLACE, into the caller's storage, because two of this core's own
    /// fields are handed to Unicorn as pointers and have to keep the address
    /// they were registered at for the rest of the run.
    ///
    /// The order here is the order `main` brings CPU0 up in: share the
    /// board RAM, go on the bus, then write the image on top. The board is
    /// joined with `attachSecond`, which repeats the per-core wiring only:
    /// the blocks are registered once, on the one bus, so both cores reach
    /// the same IPCSEM and the same IPC channels, while the SAU this core
    /// carries stays its own.
    pub fn open(self: *Second, owner: *Engine, board: *Board, image: elf.Image) !void {
        self.* = .{ .core = try Engine.open() };
        errdefer self.core.close();
        try self.core.shareBoardRamWith(owner);
        try self.core.attachWatch(&self.watch);
        try self.core.attachTimebase(&self.timebase);
        try wiring.attachSecond(board, &self.core, .{
            .partitions = &self.partitions,
            .regions = &self.regions,
            .guard = &self.guard,
            .identity = cpuid.cpu1,
            .control = &self.control,
            .clears = &self.clears,
        });
        self.written = try self.core.loadImage(image);
        self.vector_base = image.vectorBase() orelse return error.NoVectorTable;
        try primeVectorTable(self.core, self.vector_base);
        self.interrupts.vector_base = self.vector_base;
        self.dividers = &board.tree.divcr2;
        try self.core.resetFromVectorTable(self.vector_base);
        self.pc = try self.core.register(.pc);
    }

    pub fn close(self: *Second) void {
        self.core.close();
    }

    /// CPU1's turn, in instructions, for one CPU0 round of `round`.
    pub fn turn(self: *const Second, round: u32) u32 {
        const word = if (self.dividers) |at| at.* else 0;
        return rate.turn(round, word);
    }

    /// One turn. A core that has faulted stays halted rather than being
    /// restarted into the same fault every round.
    pub fn step(self: *Second, instructions: usize) void {
        if (self.fault != null) return;
        self.turns += 1;
        if (self.wait.parked()) return self.idle(instructions);
        const session: engine.Session = .{
            .watch = &self.watch,
            .interrupts = &self.interrupts,
            .timebase = &self.timebase,
            .park_on_wfe = true,
        };
        const outcome = self.core.run(self.pc, instructions, session) catch |err| {
            self.fault = .{ .pc = self.pc, .detail = @errorName(err), .access = null, .instruction = null };
            return;
        };
        self.ran += instructions;
        if (outcome) |taken| {
            if (hint_resume.stoppedOn(self.core, taken) != hint_resume.wfe) {
                self.ran -= instructions;
                self.fault = taken;
                return;
            }
            // The WFE completed or parked; either way the PC is past it.
            _ = self.wait.arrive();
        }
        self.boundary();
    }

    /// A parked turn: time passes and the boundary is offered, nothing runs.
    fn idle(self: *Second, instructions: usize) void {
        self.ran += instructions;
        self.timebase.advance(self.core, @intCast(instructions)) catch {};
        self.clears.apply(self.core) catch {};
        _ = self.control.poll(self.core) catch false;
        const entered = self.interrupts.dispatch(self.core) catch null;
        self.wait.idled(entered != null);
        self.pc = self.core.register(.pc) catch self.pc;
    }

    /// The boundary between two of CPU1's turns. A turn is exactly one
    /// boundary wide, so the run loop spends it before it would service
    /// one; this is where CPU1's own pends are offered to its own NVIC.
    fn boundary(self: *Second) void {
        self.clears.apply(self.core) catch {};
        // Counted in `control.requests`; acting on one is RA8EMU-59.
        _ = self.control.poll(self.core) catch false;
        _ = self.interrupts.dispatch(self.core) catch null;
        self.pc = self.core.register(.pc) catch self.pc;
    }
};

/// CPU1, when a path was named for it, read and reset and ready for its
/// first turn, built into `into` and handed back as a pointer to it. Null
/// when the run is a single-core one, which is every image that does not
/// name a second ELF, and then `into` is left untouched.
///
/// The caller owns the storage so the core keeps one address: see `open`.
pub fn start(
    allocator: std.mem.Allocator,
    owner: *Engine,
    board: *Board,
    path: ?[]const u8,
    into: *Second,
) !?*Second {
    const named = path orelse return null;
    const file = try std.fs.cwd().openFile(named, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, limits.image_bytes);
    try into.open(owner, board, try elf.Image.init(bytes));
    return into;
}

/// The round robin between the two cores lives in interleave.zig; it is
/// re-exported here because `main` reaches it through this file.
pub const interleave = @import("interleave.zig").interleave;

/// Parking in WFE, re-exported for the same reason.
pub const parking = second_wait;

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
    // Under its own name, because this is a second map rather than more
    // detail about CPU0's. Silent on a core that never programmed one.
    try report_cores.partitionsOf(out, "CPU1 SAU", &other.partitions);
}
