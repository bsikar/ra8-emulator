//! The Unicorn engine, wrapped once so nothing above it touches C.
//!
//! Unicorn stays a C library: this is the boundary, and with src/core/c.zig
//! it is the only place that handles uc_err, raw pointers or C integer types.
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
const sau = @import("../periph/sau.zig");
const tz = @import("tz.zig");
const symbols = @import("../debug/symbols.zig");
const mpu_guard = @import("mpu_guard.zig");
const lob = @import("lob.zig");
const csel = @import("csel.zig");
const break_hook = @import("../debug/break_hook.zig");
const hits_hook = @import("../debug/hits_hook.zig");
const watchpoint = @import("../debug/watchpoint.zig");
const pc_hits = @import("../debug/pc_hits.zig");
const watch_hook = @import("../debug/watch_hook.zig");
const pend_break = @import("pend_break.zig");
const cpu_reset = @import("cpu/reset.zig");
const reboot = @import("reboot.zig");
const breakpoint = @import("../debug/breakpoint.zig");
const stop = @import("stop.zig");
const undefined_ops = @import("undefined_ops.zig");
const deadline = @import("deadline.zig");
const fault = @import("fault.zig");
const run_loop = @import("run_loop.zig");
const idle = @import("idle.zig");

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

pub const Cortex = @import("cpu/cortex.zig").Cortex;

/// Unicorn's id for one register.
fn ucId(which: Cortex) c_int {
    return switch (which) {
        .pc => c.uc.UC_ARM_REG_PC,
        .sp => c.uc.UC_ARM_REG_SP,
        .lr => c.uc.UC_ARM_REG_LR,
        .r0 => c.uc.UC_ARM_REG_R0,
        .r1 => c.uc.UC_ARM_REG_R1,
        .r2 => c.uc.UC_ARM_REG_R2,
        .r3 => c.uc.UC_ARM_REG_R3,
        .r12 => c.uc.UC_ARM_REG_R12,
        .xpsr => c.uc.UC_ARM_REG_XPSR,
        .primask => c.uc.UC_ARM_REG_PRIMASK,
        .psp => c.uc.UC_ARM_REG_PSP,
        .r4 => c.uc.UC_ARM_REG_R4,
        .r5 => c.uc.UC_ARM_REG_R5,
        .r6 => c.uc.UC_ARM_REG_R6,
        .r7 => c.uc.UC_ARM_REG_R7,
        .r8 => c.uc.UC_ARM_REG_R8,
        .r9 => c.uc.UC_ARM_REG_R9,
        .r10 => c.uc.UC_ARM_REG_R10,
        .r11 => c.uc.UC_ARM_REG_R11,
        .msp => c.uc.UC_ARM_REG_MSP,
        .basepri => c.uc.UC_ARM_REG_BASEPRI,
        .faultmask => c.uc.UC_ARM_REG_FAULTMASK,
        .control => c.uc.UC_ARM_REG_CONTROL,
        .fpscr => c.uc.UC_ARM_REG_FPSCR,
    };
}

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
        if (c.uc.uc_reg_write(self.handle, ucId(which), &scratch) != c.uc.UC_ERR_OK) {
            return Error.RegisterFailed;
        }
    }

    pub fn register(self: Engine, which: Cortex) Error!u32 {
        var value: u32 = 0;
        if (c.uc.uc_reg_read(self.handle, ucId(which), &value) != c.uc.UC_ERR_OK) {
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

    /// Stream every PT_LOAD segment to its load address, mapping the flash-like
    /// pages the image asks for that the board map does not already cover.
    ///
    /// The pages are merged before any of them is mapped: segments of one
    /// image share pages, and the CPU model refuses a page it already holds.
    pub fn loadImage(self: Engine, image: elf.Image) Error!u32 {
        return guest_load.image(.{ .engine = self }, image);
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
