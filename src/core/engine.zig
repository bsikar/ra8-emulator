//! The Unicorn engine, wrapped once so nothing above it touches C.
//!
//! Unicorn stays a C library: this is the boundary, and with src/core/c.zig
//! and src/core/lob_hook.zig it is the only place that handles uc_err, raw
//! pointers or C integer types.
//! Callers get Zig errors, slices and named registers.
const std = @import("std");
const c = @import("c.zig");
const elf = @import("elf.zig");
const guest_load = @import("cpu/memory/load.zig");
const memmap = @import("memmap.zig");
const code_lines = @import("cpu/code_lines.zig");
const board_ram = @import("board_ram.zig");
const periph = @import("../periph/registry.zig");
const disasm = @import("../debug/disasm.zig");
const cadence = @import("cadence.zig");
const clocks = @import("../periph/clocks.zig");
const nvic = @import("../periph/nvic.zig");
const bus_hook = @import("bus_hook.zig");
const mpu = @import("../periph/mpu/mpu.zig");
const mpu_hook = @import("mpu_hook.zig");
const sau = @import("../periph/sau.zig");
const sau_hook = @import("sau_hook.zig");
const tz = @import("tz.zig");
const tz_hook = @import("tz_hook.zig");
const symbols = @import("../debug/symbols.zig");
const mpu_guard = @import("mpu_guard.zig");
const lob = @import("lob.zig");
const lob_hook = @import("lob_hook.zig");
const csel = @import("csel.zig");
const csel_hook = @import("csel_hook.zig");
const systick_hook = @import("systick_hook.zig");
const break_hook = @import("../debug/break_hook.zig");
const hits_hook = @import("../debug/hits_hook.zig");
const watchpoint = @import("../debug/watchpoint.zig");
const pc_hits = @import("../debug/pc_hits.zig");
const watch_hook = @import("../debug/watch_hook.zig");
const pend_hook = @import("pend_hook.zig");
const fault_hook = @import("fault_hook.zig");
const fault_clear = @import("../periph/fault_clear.zig");
const pend_break = @import("pend_break.zig");
const cpu_reset = @import("cpu/reset.zig");
const undefined_hook = @import("undefined_hook.zig");
pub const long_shift_hook = @import("long_shift_hook.zig");
const undefined_ops_mod = @import("undefined_ops.zig");
const reboot = @import("reboot.zig");
const breakpoint = @import("../debug/breakpoint.zig");
const stop = @import("stop.zig");
const undefined_ops = @import("undefined_ops.zig");
const deadline = @import("deadline.zig");
const fault = @import("fault.zig");
const run_loop = @import("run_loop.zig");
const idle = @import("idle.zig");
const idle_hook = @import("idle_hook.zig");

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
    // The callee-saved half of the file, the Main stack pointer and the
    // three remaining words that mask or select interrupts. None of them is
    // an argument at a call boundary, which is why the dump above leaves
    // them out; src/core/idle.zig needs the WHOLE architectural state,
    // because a loop that walks any one of these is making progress.
    r4 = c.uc.UC_ARM_REG_R4,
    r5 = c.uc.UC_ARM_REG_R5,
    r6 = c.uc.UC_ARM_REG_R6,
    r7 = c.uc.UC_ARM_REG_R7,
    r8 = c.uc.UC_ARM_REG_R8,
    r9 = c.uc.UC_ARM_REG_R9,
    r10 = c.uc.UC_ARM_REG_R10,
    r11 = c.uc.UC_ARM_REG_R11,
    msp = c.uc.UC_ARM_REG_MSP,
    basepri = c.uc.UC_ARM_REG_BASEPRI,
    faultmask = c.uc.UC_ARM_REG_FAULTMASK,
    control = c.uc.UC_ARM_REG_CONTROL,
    fpscr = c.uc.UC_ARM_REG_FPSCR,
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
        code_lines.notify(address, bytes.len);
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
        board_ram.mapBoard(self.handle, &self.ram, null) catch return Error.MapFailed;
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
        board_ram.mapBoard(self.handle, &self.ram, &owner.ram) catch return Error.MapFailed;
    }

    /// Put the peripheral bus behind the peripheral window and its Non-secure
    /// alias. Until this runs, the first store a driver makes to a peripheral
    /// register is an unmapped write and the run ends there; after it, every
    /// access in the window reaches the bus and either a modelled block or the
    /// sparse register file answers it.
    pub fn attachPeriph(self: Engine, bus: *periph.Bus) Error!void {
        return self.attachPeriphAs(bus, .cpu0);
    }

    /// The same, for the core named `issuer`, so the bus can tell whose
    /// access it is serving.
    pub fn attachPeriphAs(self: Engine, bus: *periph.Bus, issuer: periph.Issuer) Error!void {
        bus_hook.attachBus(self.handle, bus.port(issuer)) catch return Error.AttachFailed;
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

    /// Bank the SAU's RBAR/RLAR through RNR. No guard beside it, unlike the
    /// MPU: this model keeps the map the firmware programmed but does not
    /// enforce attribution by it, so there is nothing to arm.
    pub fn attachPartitions(self: Engine, unit: *sau.Sau) Error!void {
        sau_hook.attach(self.handle, unit) catch return Error.AttachFailed;
    }

    /// End the stretch of execution in which the firmware arms SysTick, so
    /// the boundary after it is cut from the period just asked for rather
    /// than from the nothing that was armed when the stretch began.
    /// src/core/systick_hook.zig says what is swallowed without this.
    pub fn attachTimebase(self: Engine, clock: *clocks.Clocks) Error!void {
        systick_hook.attach(self.handle, clock) catch return Error.AttachFailed;
    }

    /// Perform the secure boot's one BLXNS by hand, so the Non-Secure world
    /// runs; src/core/tz.zig says why the CPU model cannot be left to. An
    /// image whose secure boot is not linked in, or whose jump routine holds
    /// no BLXNS, keeps the all-Secure path it already had. The instruction
    /// is found in the image as loaded, so the bytes scanned are the bytes
    /// that will execute.
    pub fn attachWorlds(self: Engine, image: elf.Image, worlds: *tz.Worlds) Error!void {
        const found = symbols.extentOf(image, tz.jump_routine) orelse return;
        if (found.size > tz.limits.routine_bytes) return;
        var body: [tz.limits.routine_bytes]u8 = undefined;
        const code = body[0..found.size];
        self.read(found.address, code) catch return;
        const offset = tz.findBlxns(code) orelse return;
        tz_hook.attach(self.handle, worlds, found.address +% offset) catch return Error.AttachFailed;
    }

    /// Watch every store a closure probe makes, so a loop that stores can
    /// still be proved harmless. src/core/idle.zig says what is proved and
    /// what a store outside ordinary RAM costs.
    pub fn attachIdle(self: Engine, seam: *idle.Seam) Error!void {
        idle_hook.attach(self.handle, seam) catch return Error.AttachFailed;
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

    /// Count the executions of each instruction the run asked about. The
    /// run is never stopped here, so the count cannot be a number about
    /// its own hook.
    pub fn attachHits(self: Engine, hits: *pc_hits.Hits) Error!void {
        hits_hook.attach(self.handle, hits) catch return Error.AttachFailed;
    }

    /// Watch one word: every store that lands in it is recorded with the
    /// program counter that made it. The run is not stopped, so a value
    /// written more than once tells its whole story in one run.
    pub fn attachWatchpoint(self: Engine, watched: *watchpoint.Watched) Error!void {
        watch_hook.attach(self.handle, watched) catch return Error.AttachFailed;
    }

    /// Stop the stretch on a store that pends an exception by hand, so
    /// the controller can take it where the architecture would rather
    /// than at the next boundary. src/core/pend_break.zig carries why.
    pub fn attachPend(self: Engine, pending: *pend_break.Pend) Error!void {
        pend_hook.attach(self.handle, pending) catch return Error.AttachFailed;
    }

    /// Latch every store to CFSR or HFSR so the boundary can clear the
    /// bits it wrote ones to. src/periph/fault_clear.zig says why.
    pub fn attachFaultClears(self: Engine, clears: *fault_clear.Clears) Error!void {
        fault_hook.attach(self.handle, clears) catch return Error.AttachFailed;
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
        const written = try guest_load.image(.{ .engine = self }, image);
        _ = long_shift_hook.attach(self.handle, image) catch return Error.AttachFailed;
        return written;
    }

    /// Reset the core the way the silicon does: SP and PC out of the vector
    /// table, PC with the Thumb bit stripped, LR all ones as TakeReset sets it.
    pub fn resetFromVectorTable(self: Engine, vector_base: u32) Error!void {
        const stack_pointer = try self.readWord(vector_base);
        const reset_vector = try self.readWord(vector_base + 4);
        try self.setRegister(.sp, stack_pointer);
        try self.setRegister(.lr, cpu_reset.lr_at_reset);
        try self.setRegister(.pc, reset_vector & ~@as(u32, 1));
    }

    /// One uninterrupted stretch of execution. The clocks stand still inside
    /// it: a chunk is the unit of modelled time.
    /// Run a bounded number of instructions. A fault is a result, not a
    /// crash: it comes back with the PC that took it. The policy over the
    /// stretches this is cut into lives in src/core/run_loop.zig; the engine
    /// keeps only the bounded stretch it is built out of.
    pub fn run(self: Engine, start: u32, instructions: usize, session: Session) Error!?Fault {
        return run_loop.run(self, start, instructions, session);
    }

    /// One bounded stretch of execution, with no boundary at either end.
    /// Public because the run loop is what puts the boundaries in.
    pub fn runChunk(self: Engine, start: u32, instructions: usize, watch: ?*Watch) Error!?Fault {
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
