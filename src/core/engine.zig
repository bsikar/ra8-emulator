//! The Unicorn engine, wrapped once so nothing above it touches C.
//!
//! Unicorn stays a C library: this is the boundary, and with src/core/c.zig
//! and src/core/lob_hook.zig it is the only place that handles uc_err, raw
//! pointers or C integer types.
//! Callers get Zig errors, slices and named registers.
const std = @import("std");
const c = @import("c.zig");
const elf = @import("elf.zig");
const memmap = @import("memmap.zig");
const periph = @import("../periph/registry.zig");
const disasm = @import("disasm.zig");
const clocks = @import("../periph/clocks.zig");
const nvic = @import("../periph/nvic.zig");
const lob = @import("lob.zig");
const lob_hook = @import("lob_hook.zig");
const reboot = @import("reboot.zig");

pub const Error = error{
    OpenFailed,
    MapFailed,
    AttachFailed,
    WriteFailed,
    RegisterFailed,
    RunFailed,
};

pub const Fault = struct {
    pc: u32,
    detail: []const u8,
    /// The access that took the fault, when Unicorn reported one.
    access: ?Access = null,
    /// The instruction at the PC, when it decoded.
    instruction: ?disasm.Text = null,

    pub const Access = struct {
        kind: enum { read, write, fetch },
        address: u64,
        size: u8,
        value: u64,
    };
};

/// Catches the invalid access behind a fault. Unicorn reports the address and
/// width in a hook and only the error code afterwards, so the hook writes here
/// and `run` reads it back once the run has stopped.
pub const Watch = struct {
    last: ?Fault.Access = null,

    pub fn clear(self: *Watch) void {
        self.last = null;
    }
};

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
};

/// What runs alongside the core for the length of a run. Everything here is
/// optional and off by default: a bare `.{}` is one uninterrupted stretch of
/// execution with no modelled time and no exceptions, which is what the
/// loader and the smaller tests want.
pub const Session = struct {
    /// Records the invalid access behind a fault.
    watch: ?*Watch = null,
    /// Charged one chunk of time per chunk of execution.
    timebase: ?*clocks.Clocks = null,
    /// Consulted at each chunk boundary for an exception to take.
    interrupts: ?*nvic.Nvic = null,
    /// Run at each chunk boundary, before the controller picks: the
    /// peripheral side of a tick, where a block that has something to raise
    /// raises it. The board hands one in; the engine only calls it.
    board: ?Tick = null,
    /// Where a reset request the board took at the boundary is left for the
    /// engine to perform. A reset resets the core, and the core is the
    /// engine's, so the board asks and this loop does it.
    reboot: ?*reboot.Reboot = null,
};

/// Something to run at the chunk boundary. A thin vtable rather than a
/// concrete type, for the same reason the peripheral bus takes one: the
/// engine has no business knowing what a board is made of.
pub const Tick = struct {
    context: *anyopaque,
    tickFn: *const fn (context: *anyopaque, core: Engine) anyerror!void,

    pub fn run(self: Tick, core: Engine) !void {
        return self.tickFn(self.context, core);
    }
};

pub const Engine = struct {
    handle: ?*c.uc.uc_engine,

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
    }

    pub fn map(self: Engine, base: u32, size: u32) Error!void {
        return self.mapWithPerms(base, size, .{});
    }

    pub fn mapWithPerms(self: Engine, base: u32, size: u32, perms: memmap.Region.Perms) Error!void {
        var prot: c_uint = 0;
        if (perms.read) prot |= c.uc.UC_PROT_READ;
        if (perms.write) prot |= c.uc.UC_PROT_WRITE;
        if (perms.exec) prot |= c.uc.UC_PROT_EXEC;
        if (c.uc.uc_mem_map(self.handle, base, size, prot) != c.uc.UC_ERR_OK) {
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
    pub fn mapBoardRam(self: Engine) Error!void {
        for (memmap.ram) |region| try self.mapWithPerms(region.base, region.size, region.perms);
    }

    /// Put the peripheral bus behind the peripheral window and its Non-secure
    /// alias. Until this runs, the first store a driver makes to a peripheral
    /// register is an unmapped write and the run ends there; after it, every
    /// access in the window reaches the bus and either a modelled block or the
    /// sparse register file answers it.
    pub fn attachPeriph(self: Engine, bus: *periph.Bus) Error!void {
        for ([_]u32{ periph.base, periph.ns_base }) |window| {
            if (c.uc.uc_mmio_map(
                self.handle,
                window,
                periph.size,
                onRead,
                bus,
                onWrite,
                bus,
            ) != c.uc.UC_ERR_OK) {
                return Error.AttachFailed;
            }
        }
    }

    /// Record the invalid accesses a run takes. Without this a fault is just
    /// an error code and a PC; with it the report can say which address the
    /// firmware reached for and how wide the access was.
    pub fn attachWatch(self: Engine, watch: *Watch) Error!void {
        var hook: c.uc.uc_hook = 0;
        if (c.uc.uc_hook_add(
            self.handle,
            &hook,
            c.uc.UC_HOOK_MEM_INVALID,
            @constCast(@as(*const anyopaque, @ptrCast(&onInvalid))),
            watch,
            1,
            0,
        ) != c.uc.UC_ERR_OK) {
            return Error.AttachFailed;
        }
    }

    /// Step the Armv8.1-M low-overhead loops the CPU model cannot decode.
    /// Without this a real Cortex-M85 image stops on the first counted loop
    /// its C startup runs, which is before main().
    pub fn attachLoops(self: Engine, loops: *lob.Loops) Error!void {
        lob_hook.attach(self.handle, loops) catch return Error.AttachFailed;
    }

    /// Stream every PT_LOAD segment to its load address, mapping the flash-like
    /// pages the image asks for that the board map does not already cover.
    pub fn loadImage(self: Engine, image: elf.Image) Error!u32 {
        var mapped_low: u64 = 0;
        var mapped_high: u64 = 0;
        var written: u32 = 0;
        var index: u16 = 0;
        while (index < image.segmentCount()) : (index += 1) {
            const segment = image.loadSegment(index) orelse continue;
            const page_base = segment.paddr & ~@as(u32, 0xFFF);
            const span = (@as(u64, segment.paddr) + @max(segment.memsz, @as(u32, @intCast(segment.bytes.len)))) - page_base;
            const page_size: u32 = @intCast((span + 0xFFF) & ~@as(u64, 0xFFF));
            if (!coveredByBoard(page_base, page_size) and
                !(page_base >= mapped_low and @as(u64, page_base) + page_size <= mapped_high))
            {
                try self.map(page_base, page_size);
                mapped_low = page_base;
                mapped_high = @as(u64, page_base) + page_size;
            }
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
        const per_chunk = if (session.timebase) |clock| clock.per_chunk else clocks.chunk_instructions;
        var remaining = instructions;
        var pc = start;
        while (remaining > 0) {
            const chunk = @min(remaining, @as(usize, per_chunk));
            if (try self.runChunk(pc, chunk, session.watch)) |taken| {
                const controller = session.interrupts orelse return taken;
                if (!nvic.isExceptionReturn(taken.pc)) return taken;
                controller.exit(self) catch return Error.RunFailed;
                pc = try self.register(.pc);
                // The stretch that ended in the return cannot be measured, so
                // it is charged one instruction: enough to keep the budget
                // monotone and a bad frame from looping forever.
                remaining -= 1;
                continue;
            }
            remaining -= chunk;
            if (session.timebase) |clock| clock.advance(self, @intCast(chunk)) catch return Error.RunFailed;
            // The budget is spent: do not enter a handler there is no room
            // left to run, which would report a run that ended inside an
            // exception it never actually took.
            if (remaining == 0) break;
            if (session.board) |tick| tick.run(self) catch return Error.RunFailed;
            // A part that just reset has nothing pending, so the controller
            // does not get to pick this boundary: carry straight on into the
            // reset vector.
            if (session.reboot) |pending| if (pending.requested) {
                pc = pending.perform(self, session.interrupts) catch return Error.RunFailed;
                continue;
            };
            if (session.interrupts) |controller| _ = controller.dispatch(self) catch return Error.RunFailed;
            pc = try self.register(.pc);
        }
        return null;
    }

    /// One uninterrupted stretch of execution. The clocks stand still inside
    /// it: a chunk is the unit of modelled time.
    fn runChunk(self: Engine, start: u32, instructions: usize, watch: ?*Watch) Error!?Fault {
        const err = c.uc.uc_emu_start(self.handle, start | 1, 0xFFFF_FFFF, 0, instructions);
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

/// Unicorn hands an offset inside the mapped window, so the window base is
/// added back before the bus sees it. These two functions and src/c.zig are
/// the only places with a C calling convention in the emulator.
fn onRead(uc: ?*c.uc.uc_engine, offset: u64, size: c_uint, user: ?*anyopaque) callconv(.C) u64 {
    _ = uc;
    const bus: *periph.Bus = @ptrCast(@alignCast(user.?));
    return bus.read(periph.base + @as(u32, @truncate(offset)), widthOf(size));
}

fn onWrite(uc: ?*c.uc.uc_engine, offset: u64, size: c_uint, value: u64, user: ?*anyopaque) callconv(.C) void {
    _ = uc;
    const bus: *periph.Bus = @ptrCast(@alignCast(user.?));
    bus.write(periph.base + @as(u32, @truncate(offset)), widthOf(size), @truncate(value));
}

fn onInvalid(
    uc: ?*c.uc.uc_engine,
    kind: c_int,
    address: u64,
    size: c_int,
    value: i64,
    user: ?*anyopaque,
) callconv(.C) bool {
    _ = uc;
    const watch: *Watch = @ptrCast(@alignCast(user.?));
    watch.last = .{
        .kind = switch (kind) {
            c.uc.UC_MEM_WRITE_UNMAPPED, c.uc.UC_MEM_WRITE_PROT => .write,
            c.uc.UC_MEM_FETCH_UNMAPPED, c.uc.UC_MEM_FETCH_PROT => .fetch,
            else => .read,
        },
        .address = address,
        .size = @intCast(size),
        .value = @bitCast(value),
    };
    // false: do not pretend the access succeeded, let the run stop.
    return false;
}

fn widthOf(size: c_uint) u3 {
    return switch (size) {
        1 => 1,
        2 => 2,
        else => 4,
    };
}

fn coveredByBoard(base: u32, size: u32) bool {
    for (memmap.ram) |region| {
        if (base >= region.base and @as(u64, base) + size <= region.end()) return true;
    }
    return false;
}
