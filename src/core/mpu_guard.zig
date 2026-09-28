//! MPU enforcement: refuse a store into a read-only region, and take the
//! MemManage the core would have taken for it.
//!
//! src/periph/mpu.zig captures what the firmware programmed and
//! src/periph/mpu_fault.zig holds what enforcement caught. This file is the
//! Unicorn half between them: while CTRL.ENABLE stands it keeps a write hook
//! over the span of every enabled read-only region, and a store landing in
//! one stops the chunk so the run loop can vector into the handler.
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

/// The enforcement side of the MPU: the table it enforces, the traps it has
/// out, and what they caught.
pub const Guard = struct {
    /// The table, set when the window hook is attached. A guard nobody
    /// attached enforces nothing rather than guessing at a table.
    unit: ?*mpu.Mpu = null,
    latch: mpu_fault.Latch = .{},
    /// One trap per region, so the set can be rebuilt without disturbing
    /// anything else the engine has hooked.
    hooks: [mpu.geometry.regions]c.uc.uc_hook = [_]c.uc.uc_hook{0} ** mpu.geometry.regions,
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
        if (!enable) return;
        const unit = self.unit orelse return;
        for (unit.table) |region| {
            if (!region.read_only or region.bytes() == 0) continue;
            if (self.live == self.hooks.len) break;
            if (c.uc.uc_hook_add(
                handle,
                &self.hooks[self.live],
                c.uc.UC_HOOK_MEM_WRITE,
                @constCast(@as(*const anyopaque, @ptrCast(&onWrite))),
                &self.latch,
                region.base,
                region.limit,
            ) != c.uc.UC_ERR_OK) continue;
            self.live += 1;
        }
        self.latch.arms +%= 1;
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
        const status = (core.readWord(memmap.scb.cfsr) catch 0) |
            mpu_fault.mmfsr.daccviol | mpu_fault.mmfsr.mmarvalid;
        try core.writeWord(memmap.scb.cfsr, status);
        try core.writeWord(memmap.scb.mmfar, hit.address);
        const unit = controller orelse {
            self.latch.unhandled +%= 1;
            return;
        };
        const stopped_at = try core.register(.pc);
        try core.setRegister(.pc, hit.pc);
        unit.enter(core, .{
            .number = mpu_fault.exception,
            .priority = @truncate(core.readWord(memmap.scb.shpr1) catch 0),
        }) catch {
            try core.setRegister(.pc, stopped_at);
            self.latch.unhandled +%= 1;
            return;
        };
        self.latch.faults +%= 1;
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
