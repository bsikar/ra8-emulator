//! MPU enforcement: refuse a store into a read-only region and a fetch out of
//! an execute-never one, and take the MemManage the core would have taken.
//!
//! src/periph/mpu.zig captures what the firmware programmed and
//! src/periph/mpu_fault.zig holds what enforcement caught. This file is the
//! Unicorn half between them: while CTRL.ENABLE stands it keeps a write hook
//! over the span of every enabled read-only region and a code hook over every
//! execute-never one, and an access either catches stops the chunk so the run
//! loop can vector into the handler.
//!
//! THE TWO KINDS PART COMPANY AFTER THE STOP. A refused store has already
//! landed, so the run can carry on from it whether or not a handler took the
//! exception. A refused fetch has not happened yet and the PC has not moved,
//! so with no handler to go to there is nothing to carry on to: the same fetch
//! would be refused again at every boundary for the rest of the run. Silicon
//! escalates that to HardFault and locks up; this model escalates neither, so
//! it counts the violation, takes the traps off, and says so in the report.
//!
//! WHY A STOP AND NOT A REFUSAL. A memory hook cannot decline the access, so
//! the store lands in the RAM underneath either way: what is modelled is the
//! exception, not the protection. dev's emu_mpu.c stands in the same place,
//! and the contract the images rely on is the one it documents: PC goes back
//! to the faulting store so entry stacks THAT address, and a recovering
//! handler steps the stacked PC past exactly one store before it returns.
//!
//! THE TABLE POINTER LIVES HERE rather than in the window hook next door,
//! because the one hook over the MPU registers has to reach both halves: a
//! store to RNR rebanks the table, and a store to CTRL arms or disarms these
//! traps.
const c = @import("c.zig");
const memmap = @import("memmap.zig");
const nvic = @import("../periph/nvic.zig");
const mpu = @import("../periph/mpu.zig");
const mpu_fault = @import("../periph/mpu_fault.zig");

/// uc_ctl packs the direction into the control word's top two bits, and the
/// header only offers it as a macro (UC_CTL_WRITE), which does not survive
/// the C import.
const io_write: c_uint = 1;

/// The enforcement side of the MPU: the table it enforces, the traps it has
/// out, and what they caught.
pub const Guard = struct {
    /// The table, set when the window hook is attached. A guard nobody
    /// attached enforces nothing rather than guessing at a table.
    unit: ?*mpu.Mpu = null,
    latch: mpu_fault.Latch = .{},
    /// Room for both traps of every region, so the set can be rebuilt without
    /// disturbing anything else the engine has hooked. A region can be both
    /// read-only and execute-never and then carries one of each.
    hooks: [2 * mpu.geometry.regions]c.uc.uc_hook = [_]c.uc.uc_hook{0} ** (2 * mpu.geometry.regions),
    live: usize = 0,

    pub fn init() Guard {
        return .{};
    }

    /// Follow a store to CTRL. The traps are rebuilt from the table every
    /// time rather than only on the enable edge: `ra8_mpu_configure`
    /// reprogrammes the table between a disable and an enable, but a
    /// firmware that re-enables an already-enabled MPU after moving a region
    /// would otherwise keep enforcing the span it moved away from.
    pub fn follow(self: *Guard, handle: ?*c.uc.uc_engine, enable: bool) void {
        self.disarm(handle);
        if (!enable) {
            flush(handle);
            return;
        }
        const unit = self.unit orelse return;
        self.latch.stood_down = false;
        for (unit.table) |region| {
            if (region.bytes() == 0) continue;
            if (region.read_only) self.trap(handle, region, .store);
            if (!region.executable) self.trap(handle, region, .fetch);
        }
        flush(handle);
        self.latch.arms +%= 1;
    }

    /// Throw away the translated code, because a fetch trap only covers a block
    /// Unicorn translates while the trap is up. A page the firmware has already
    /// run once is already translated, so arming enforcement over it would
    /// otherwise let the fetch through, and disarming would keep refusing it. This
    /// is the one place the model has to reach past the hook API into the engine's
    /// cache, and it is why a region protected after it has been executed is
    /// enforced from the next block rather than from the next instruction.
    fn flush(handle: ?*c.uc.uc_engine) void {
        const control: c_uint = @as(c_uint, @intCast(c.uc.UC_CTL_TB_FLUSH)) |
            (@as(c_uint, io_write) << 30);
        _ = c.uc.uc_ctl(handle, control);
    }

    /// Put one trap over one region's span. A hook Unicorn will not take
    /// leaves that span unenforced rather than failing the whole arm: the
    /// report counts what was refused, never what was watched.
    fn trap(self: *Guard, handle: ?*c.uc.uc_engine, region: mpu.Region, kind: mpu_fault.Kind) void {
        if (self.live == self.hooks.len) return;
        const event: c_int = switch (kind) {
            .store => c.uc.UC_HOOK_MEM_WRITE,
            .fetch => c.uc.UC_HOOK_CODE,
        };
        const callback: *const anyopaque = switch (kind) {
            .store => @ptrCast(&onWrite),
            .fetch => @ptrCast(&onFetch),
        };
        if (c.uc.uc_hook_add(
            handle,
            &self.hooks[self.live],
            event,
            @constCast(callback),
            &self.latch,
            region.base,
            region.limit,
        ) != c.uc.UC_ERR_OK) return;
        self.live += 1;
    }

    /// Take every trap off, which is what a cleared CTRL.ENABLE means: the
    /// protected spans go back to being ordinary writable memory.
    pub fn disarm(self: *Guard, handle: ?*c.uc.uc_engine) void {
        for (self.hooks[0..self.live]) |hook| _ = c.uc.uc_hook_del(handle, hook);
        self.live = 0;
    }

    /// Turn a trapped store into the exception the core would have taken:
    /// latch the architectural status, put PC back on the store so entry
    /// stacks it, and vector into the handler.
    ///
    /// With no handler to reach, the violation is counted and the run
    /// carries on from where the store left it: no escalation to HardFault
    /// is modelled. PC is rewound only once the entry has happened, because
    /// a rewind with nothing to vector into would re-run the store straight
    /// back into the trap that stopped it.
    pub fn synthesise(
        self: *Guard,
        core: anytype,
        controller: ?*nvic.Nvic,
        hit: mpu_fault.Violation,
    ) !void {
        const reason: u32 = switch (hit.kind) {
            .store => mpu_fault.mmfsr.daccviol | mpu_fault.mmfsr.mmarvalid,
            .fetch => mpu_fault.mmfsr.iaccviol,
        };
        try core.writeWord(memmap.scb.cfsr, (core.readWord(memmap.scb.cfsr) catch 0) | reason);
        // MMFAR belongs to the store case alone: a refused fetch leaves
        // MMARVALID clear, so whatever MMFAR held stays where it was.
        if (hit.kind == .store) try core.writeWord(memmap.scb.mmfar, hit.address);
        const unit = controller orelse {
            self.standDown(core, hit);
            return;
        };
        const stopped_at = try core.register(.pc);
        try core.setRegister(.pc, hit.pc);
        unit.enter(core, .{
            .number = mpu_fault.exception,
            .priority = @truncate(core.readWord(memmap.scb.shpr1) catch 0),
        }) catch {
            try core.setRegister(.pc, stopped_at);
            self.standDown(core, hit);
            return;
        };
        self.latch.faults +%= 1;
    }

    /// A violation with no handler to reach. The store case simply carries on
    /// from where the store left it, the way it always has. The fetch case
    /// cannot: the PC is still on the refused instruction, so the traps come
    /// off to let the run make progress instead of refusing it forever.
    fn standDown(self: *Guard, core: anytype, hit: mpu_fault.Violation) void {
        self.latch.unhandled +%= 1;
        if (hit.kind != .fetch) return;
        self.disarm(core.handle);
        flush(core.handle);
        self.latch.stood_down = true;
    }
};

/// A store into a protected span. Unicorn cannot be told to decline it, so
/// the run is stopped instead and the PC of the store kept: the loop takes
/// the exception at the boundary this makes.
fn onWrite(
    uc: ?*c.uc.uc_engine,
    kind: c_int,
    address: u64,
    size: c_int,
    value: i64,
    user: ?*anyopaque,
) callconv(.C) void {
    _ = kind;
    _ = size;
    _ = value;
    const handle = uc orelse return;
    const latch: *mpu_fault.Latch = @ptrCast(@alignCast(user.?));
    var pc: u32 = 0;
    _ = c.uc.uc_reg_read(handle, c.uc.UC_ARM_REG_PC, &pc);
    if (!latch.record(.{ .pc = pc, .address = @truncate(address) })) return;
    _ = c.uc.uc_emu_stop(handle);
}

/// A fetch out of an execute-never span. A code hook runs BEFORE the
/// instruction it names, so stopping here is a genuine refusal rather than the
/// after-the-fact stop a store gets, and the hook's own address is both the PC
/// entry has to stack and the address that took the fault.
fn onFetch(
    uc: ?*c.uc.uc_engine,
    address: u64,
    size: u32,
    user: ?*anyopaque,
) callconv(.C) void {
    _ = size;
    const handle = uc orelse return;
    const latch: *mpu_fault.Latch = @ptrCast(@alignCast(user.?));
    const at: u32 = @truncate(address);
    if (!latch.record(.{ .pc = at, .address = at, .kind = .fetch })) return;
    _ = c.uc.uc_emu_stop(handle);
}
