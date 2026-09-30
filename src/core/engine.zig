//! The Unicorn engine, wrapped once so nothing above it touches C.
//!
//! Unicorn stays a C library: this is the boundary, and with src/core/c.zig
//! and src/core/lob_hook.zig it is the only place that handles uc_err, raw
//! pointers or C integer types.
//! Callers get Zig errors, slices and named registers.
const std = @import("std");
const c = @import("c.zig");
const elf = @import("elf.zig");
const pages = @import("pages.zig");
const memmap = @import("memmap.zig");
const board_ram = @import("board_ram.zig");
const periph = @import("../periph/registry.zig");
const disasm = @import("disasm.zig");
const cadence = @import("cadence.zig");
const clocks = @import("../periph/clocks.zig");
const nvic = @import("../periph/nvic.zig");
const bus_hook = @import("bus_hook.zig");
const mpu = @import("../periph/mpu.zig");
const mpu_hook = @import("mpu_hook.zig");
const mpu_guard = @import("mpu_guard.zig");
const lob = @import("lob.zig");
const lob_hook = @import("lob_hook.zig");
const csel = @import("csel.zig");
const csel_hook = @import("csel_hook.zig");
const break_hook = @import("break_hook.zig");
const watchpoint = @import("watchpoint.zig");
const watch_hook = @import("watch_hook.zig");
const undefined_hook = @import("undefined_hook.zig");
const undefined_ops_mod = @import("undefined_ops.zig");
const reboot = @import("reboot.zig");
const breakpoint = @import("breakpoint.zig");
const stop = @import("stop.zig");
const undefined_ops = @import("undefined_ops.zig");
const deadline = @import("deadline.zig");
const fault = @import("fault.zig");

pub const Error = error{
    OpenFailed,
    MapFailed,
    AttachFailed,
    WriteFailed,
    RegisterFailed,
    RunFailed,
};

/// Why a run stopped badly, and the latch the hook records it in. Both live
/// in fault.zig and are re-exported here so `engine.Fault` still resolves.
pub const Fault = fault.Fault;
pub const Watch = fault.Watch;

pub const Cortex = enum(c_int) {
    pc = c.uc.UC_ARM_REG_PC,
    sp = c.uc.UC_ARM_REG_SP,
    lr = c.uc.UC_ARM_REG_LR,
    r0 = c.uc.UC_ARM_REG_R0,
    r1 = c.uc.UC_ARM_REG_R1,
    r2 = c.uc.UC_ARM_REG_R2,
    // The rest of the caller-saved set, plus the two status registers:
    // exception entry stacks them and the controller reads them.
    r3 = c.uc.UC_ARM_REG_R3,
    r12 = c.uc.UC_ARM_REG_R12,
    xpsr = c.uc.UC_ARM_REG_XPSR,
    primask = c.uc.UC_ARM_REG_PRIMASK,
    // The Process stack pointer. A scheduler's handler reads it to find the
    // frame it has to save and writes it to name the thread it picked, so
    // exception entry and return both keep it current.
    psp = c.uc.UC_ARM_REG_PSP,
};

/// What a run is allowed to do, re-exported so `engine.Session` resolves.
pub const Session = @import("session.zig").Session;

/// The board's chunk-boundary hook, re-exported so `engine.Tick` resolves.
pub const Tick = @import("tick.zig").Tick;

pub const Engine = struct {
    handle: ?*c.uc.uc_engine,
    /// The host pages behind the board's aliased regions, so the Secure and
    /// Non-secure views of one region answer out of the same bytes. Owned
    /// here and released by `close`; empty until `mapBoardRam` runs. See
    /// src/core/board_ram.zig.
    ram: board_ram.Store = .{},

    pub fn open() Error!Engine {
        var handle: ?*c.uc.uc_engine = null;
        // Cortex-M85 is the RA8D2 core; Unicorn models it as an ARM MCLASS CPU.
        if (c.uc.uc_open(c.uc.UC_ARCH_ARM, c.uc.UC_MODE_THUMB | c.uc.UC_MODE_MCLASS, &handle) != c.uc.UC_ERR_OK) {
            return Error.OpenFailed;
        }
        return .{ .handle = handle };
    }

    pub fn close(self: *Engine) void {
        if (self.handle) |handle| _ = c.uc.uc_close(handle);
        self.handle = null;
        self.ram.deinit();
    }

    pub fn map(self: Engine, base: u32, size: u32) Error!void {
        return self.mapWithPerms(base, size, .{});
    }

    pub fn mapWithPerms(self: Engine, base: u32, size: u32, perms: memmap.Region.Perms) Error!void {
        if (c.uc.uc_mem_map(self.handle, base, size, board_ram.protOf(perms)) != c.uc.UC_ERR_OK) {
            return Error.MapFailed;
        }
    }

    pub fn write(self: Engine, address: u32, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        if (c.uc.uc_mem_write(self.handle, address, bytes.ptr, bytes.len) != c.uc.UC_ERR_OK) {
            return Error.WriteFailed;
        }
    }

    pub fn read(self: Engine, address: u32, into: []u8) Error!void {
        if (into.len == 0) return;
        if (c.uc.uc_mem_read(self.handle, address, into.ptr, into.len) != c.uc.UC_ERR_OK) {
            return Error.WriteFailed;
        }
    }

    pub fn readWord(self: Engine, address: u32) Error!u32 {
        var bytes: [4]u8 = undefined;
        try self.read(address, &bytes);
        return std.mem.readInt(u32, &bytes, .little);
    }

    pub fn writeWord(self: Engine, address: u32, value: u32) Error!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.write(address, &bytes);
    }

    pub fn setRegister(self: Engine, which: Cortex, value: u32) Error!void {
        var scratch = value;
        if (c.uc.uc_reg_write(self.handle, @intFromEnum(which), &scratch) != c.uc.UC_ERR_OK) {
            return Error.RegisterFailed;
        }
    }

    pub fn register(self: Engine, which: Cortex) Error!u32 {
        var value: u32 = 0;
        if (c.uc.uc_reg_read(self.handle, @intFromEnum(which), &value) != c.uc.UC_ERR_OK) {
            return Error.RegisterFailed;
        }
        return value;
    }

    /// Map the RAM regions the board has before any image lands in them.
    /// The aliased ones are backed by pages this engine owns, so both views
    /// of a region are the same bytes; src/core/board_ram.zig has the why.
    pub fn mapBoardRam(self: *Engine) Error!void {
        board_ram.mapBoard(self.handle, &self.ram) catch return Error.MapFailed;
    }

    /// Put this engine in front of the board RAM `owner` already allocated,
    /// which is how a second core joins a board rather than getting one of
    /// its own. Both engines then read and write the same bytes, so a store
    /// CPU1 makes in shared SRAM is there for CPU0 with nothing in between.
    ///
    /// The pages stay the owner's: this engine allocates none and frees
    /// none, so it must be closed before the owner is. Mapping a core onto
    /// an owner that has not mapped yet is a programming error rather than
    /// a silent empty board, and fails.
    pub fn shareBoardRamWith(self: *Engine, owner: *Engine) Error!void {
        if (!owner.ram.mapped()) return Error.MapFailed;
        board_ram.mapBoard(self.handle, &owner.ram) catch return Error.MapFailed;
    }

    /// Put the peripheral bus behind the peripheral window and its Non-secure
    /// alias. Until this runs, the first store a driver makes to a peripheral
    /// register is an unmapped write and the run ends there; after it, every
    /// access in the window reaches the bus and either a modelled block or the
    /// sparse register file answers it.
    pub fn attachPeriph(self: Engine, bus: *periph.Bus) Error!void {
        bus_hook.attachBus(self.handle, bus) catch return Error.AttachFailed;
    }

    /// Record the invalid accesses a run takes, so a fault can say which
    /// address the firmware reached for and how wide the access was.
    pub fn attachWatch(self: Engine, watch: *Watch) Error!void {
        bus_hook.attachWatch(self.handle, watch) catch return Error.AttachFailed;
    }

    /// Step the Armv8.1-M low-overhead loops the CPU model cannot decode.
    /// Without this a real Cortex-M85 image stops on the first counted loop
    /// its C startup runs, which is before main().
    pub fn attachLoops(self: Engine, loops: *lob.Loops) Error!void {
        lob_hook.attach(self.handle, loops) catch return Error.AttachFailed;
    }

    /// Bank the MPU region table through RNR. Without this every region a
    /// driver programs lands on top of the last one, and a configuration
    /// that clears its unused tail reads back as an empty table.
    pub fn attachRegions(self: Engine, unit: *mpu.Mpu, guard: *mpu_guard.Guard) Error!void {
        guard.unit = unit;
        mpu_hook.attach(self.handle, guard) catch return Error.AttachFailed;
    }

    /// Step the Armv8.1-M conditional selects the CPU model cannot decode.
    /// Its own hook rather than a branch inside the loop one: Unicorn walks
    /// every invalid-instruction hook until one claims the encoding, so the
    /// two decoders stay independent of each other.
    pub fn attachSelects(self: Engine, selects: *csel.Selects) Error!void {
        csel_hook.attach(self.handle, selects) catch return Error.AttachFailed;
    }

    /// Arm the break: one instruction is hooked, and reaching it the
    /// asked-for number of times stops the run where it stands.
    pub fn attachBreak(self: Engine, point: *breakpoint.Break) Error!void {
        break_hook.attach(self.handle, point) catch return Error.AttachFailed;
    }

    /// Watch one word: every store that lands in it is recorded with the
    /// program counter that made it. The run is not stopped, so a value
    /// written more than once tells its whole story in one run.
    pub fn attachWatchpoint(self: Engine, watched: *watchpoint.Watched) Error!void {
        watch_hook.attach(self.handle, watched) catch return Error.AttachFailed;
    }

    /// Count every arrival at an undefined site the sweep found, so the
    /// report can separate an encoding that merely sits in the image from
    /// one the firmware runs.
    pub fn attachUndefined(self: Engine, found: *undefined_ops_mod.Found) Error!void {
        undefined_hook.attach(self.handle, found) catch return Error.AttachFailed;
    }

    /// Stream every PT_LOAD segment to its load address, mapping the flash-like
    /// pages the image asks for that the board map does not already cover.
    ///
    /// The pages are merged before any of them is mapped: segments of one
    /// image share pages, and the CPU model refuses a page it already holds.
    pub fn loadImage(self: Engine, image: elf.Image) Error!u32 {
        const needed = pages.forImage(image) catch return Error.MapFailed;
        for (needed.items()) |range| {
            if (board_ram.covers(range.base, range.size())) continue;
            try self.map(range.base, range.size());
        }
        var written: u32 = 0;
        var index: u16 = 0;
        while (index < image.segmentCount()) : (index += 1) {
            const segment = image.loadSegment(index) orelse continue;
            try self.write(segment.paddr, segment.bytes);
            written += @intCast(segment.bytes.len);
        }
        if (written == 0) return Error.WriteFailed;
        return written;
    }

    /// Reset the core the way the silicon does: SP and PC out of the vector
    /// table, PC with the Thumb bit stripped.
    pub fn resetFromVectorTable(self: Engine, vector_base: u32) Error!void {
        const stack_pointer = try self.readWord(vector_base);
        const reset_vector = try self.readWord(vector_base + 4);
        try self.setRegister(.sp, stack_pointer);
        try self.setRegister(.pc, reset_vector & ~@as(u32, 1));
    }

    /// Run a bounded number of instructions. A fault is a result, not a
    /// crash: it comes back with the PC that took it.
    ///
    /// With a time base attached the run is cut into chunks and the clocks
    /// are charged one chunk of time per chunk of execution, which is what
    /// keeps a firmware that waits on DWT_CYCCNT or on SysTick from spinning
    /// out the whole budget in one loop. With a controller attached, each of
    /// those boundaries is also where a pending exception is taken, and a
    /// handler branching to its EXC_RETURN is unwound rather than reported:
    /// Unicorn cannot fetch from 0xFFFFFFxx and does not have to.
    pub fn run(self: Engine, start: u32, instructions: usize, session: Session) Error!?Fault {
        if (session.watch) |w| w.clear();
        if (session.timebase == null and session.interrupts == null) {
            return self.runChunk(start, instructions, session.watch);
        }
        const configured = cadence.Cadence{
            .per_boundary = if (session.timebase) |clock| clock.per_chunk else cadence.instructions,
        };
        var remaining = instructions;
        var pc = start;
        while (remaining > 0) {
            // Read the armed period every time round rather than once: the
            // firmware arms SysTick well after reset, and may re-arm it.
            const pace = if (session.timebase) |clock|
                configured.narrowedTo(clock.period(self))
            else
                configured;
            const chunk = pace.chunk(remaining);
            if (try self.runChunk(pc, chunk, session.watch)) |taken| {
                const controller = session.interrupts orelse return taken;
                if (!nvic.isExceptionReturn(taken.pc)) return taken;
                controller.exit(self, taken.pc) catch return Error.RunFailed;
                pc = try self.register(.pc);
                // The stretch that ended in the return cannot be measured, so
                // it is charged one instruction: enough to keep the budget
                // monotone and a bad frame from looping forever.
                remaining -= 1;
                continue;
            }
            // A store into a read-only region stopped the chunk early, so the
            // exception is taken here, at the boundary the trap made, before
            // the clocks are charged for a chunk that did not finish. The
            // stretch is charged one instruction for the same reason the
            // exception return above is: enough to keep the budget monotone.
            if (session.protection) |guard| if (guard.latch.take()) |hit| {
                guard.synthesise(self, session.interrupts, hit) catch return Error.RunFailed;
                remaining -= 1;
                pc = try self.register(.pc);
                continue;
            };
            // The break's hook stopped the chunk on the break's own
            // instruction, so the run ends here rather than at the next
            // boundary: this is where the program counter still points at
            // it, and where the register file is the function's caller's.
            if (session.brk) |point| if (point.reached) break;
            // The undefined hook stopped the chunk the same way, one
            // instruction before the encoding runs, and for the same
            // reason: here the program counter still points at it.
            if (session.undefined_sites) |f| if (f.stoppedAt() != null) break;
            remaining -= chunk;
            if (session.timebase) |clock| clock.advance(self, @intCast(chunk)) catch return Error.RunFailed;
            // The budget is spent: do not enter a handler there is no room
            // left to run, which would report a run that ended inside an
            // exception it never actually took.
            if (!pace.closes(remaining)) break;
            if (session.board) |tick| tick.run(self) catch return Error.RunFailed;
            // A part that just reset has nothing pending, so the controller
            // does not get to pick this boundary: carry straight on into the
            // reset vector.
            if (session.reboot) |pending| if (pending.requested) {
                pc = pending.perform(self, session.interrupts) catch return Error.RunFailed;
                continue;
            };
            if (session.interrupts) |controller| _ = controller.dispatch(self) catch return Error.RunFailed;
            // The counter is read here, after the boundary's blocks have
            // run, so a value a peripheral advanced this chunk is seen.
            if (session.stop) |watch| if (watch.met(self.readWord(watch.address) catch null)) break;
            // Modelled time is read from the same boundary, after the counter:
            // when both land on one boundary the counter is the verdict the
            // suite asked for and the deadline is only the window it allowed.
            if (session.deadline) |due| if (session.timebase) |clock| {
                if (due.met(clock.ticks)) break;
            };
            pc = try self.register(.pc);
        }
        return null;
    }

    /// One uninterrupted stretch of execution. The clocks stand still inside
    /// it: a chunk is the unit of modelled time.
    fn runChunk(self: Engine, start: u32, instructions: usize, watch: ?*Watch) Error!?Fault {
        const err = c.uc.uc_emu_start(
            self.handle,
            start | 1,
            breakpoint.limits.unreachable_address,
            0,
            instructions,
        );
        if (err == c.uc.UC_ERR_OK) return null;
        const pc = self.register(.pc) catch 0;
        var bytes: [4]u8 = undefined;
        return Fault{
            .pc = pc,
            .detail = std.mem.span(c.uc.uc_strerror(err)),
            .access = if (watch) |w| w.last else null,
            .instruction = blk: {
                self.read(pc, &bytes) catch break :blk null;
                break :blk disasm.one(pc, &bytes) catch null;
            },
        };
    }
};
