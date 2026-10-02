//! MPU enforcement: refuse an access a region does not allow, and take the
//! MemManage the core would have taken. Three rules are enforced: a store into
//! a read-only region, a fetch out of an execute-never one, and any access at
//! all from unprivileged code into a region that allows none, loads included.
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
const mpu = @import("../periph/mpu/mpu.zig");
const mpu_fault = @import("../periph/mpu/mpu_fault.zig");
const fault_route = @import("../periph/fault_route.zig");
const status = @import("../periph/fault_status.zig");
const background = @import("../periph/mpu/mpu_background.zig");

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
    /// Room for all three traps of every region, so the set can be rebuilt
    /// without disturbing anything else the engine has hooked. A
    /// privileged-only region carries one of each; a read-only one that
    /// unprivileged code may read carries only the store trap.
    hooks: [3 * (mpu.geometry.regions + background.limits.spans)]c.uc.uc_hook =
        [_]c.uc.uc_hook{0} ** (3 * (mpu.geometry.regions + background.limits.spans)),
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
            if (region.bytes() == 0 or !region.guarded()) continue;
            // Privilege refuses a store and a fetch alike, so a
            // privileged-only region needs both traps even when its own
            // permissions would have allowed the access.
            if (region.read_only or !region.unprivileged) self.trap(handle, spanOf(region), .store);
            if (!region.executable or !region.unprivileged) self.trap(handle, spanOf(region), .fetch);
            // A load is refused on privilege alone, so an open region and a
            // read-only one both go untrapped on this side.
            if (!region.unprivileged) self.trap(handle, spanOf(region), .load);
        }
        // Everything the table does not cover is the background, and an
        // enabled MPU refuses that too unless CTRL.PRIVDEFENA hands the
        // default map to privileged code. Which of the two it is cannot be
        // known at arm time, because it turns on the privilege of the access
        // rather than on anything programmed, so the gaps are trapped either
        // way and verdict() decides when one is reached.
        var spans: [background.limits.spans]background.Span = undefined;
        for (background.gaps(unit, &spans)) |span| {
            self.trap(handle, span, .store);
            self.trap(handle, span, .fetch);
            self.trap(handle, span, .load);
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

    /// The span a region occupies, which is what enforcement traps.
    fn spanOf(region: mpu.Region) background.Span {
        return .{ .base = region.base, .limit = region.limit };
    }

    /// Put one trap over one span. A hook Unicorn will not take
    /// leaves that span unenforced rather than failing the whole arm: the
    /// report counts what was refused, never what was watched.
    fn trap(self: *Guard, handle: ?*c.uc.uc_engine, span: background.Span, kind: mpu_fault.Kind) void {
        if (self.live == self.hooks.len) return;
        const event: c_int = switch (kind) {
            .store => c.uc.UC_HOOK_MEM_WRITE,
            .fetch => c.uc.UC_HOOK_CODE,
            .load => c.uc.UC_HOOK_MEM_READ,
        };
        const callback: *const anyopaque = switch (kind) {
            .store => @ptrCast(&onWrite),
            .fetch => @ptrCast(&onFetch),
            .load => @ptrCast(&onRead),
        };
        if (c.uc.uc_hook_add(
            handle,
            &self.hooks[self.live],
            event,
            @constCast(callback),
            self,
            span.base,
            span.limit,
        ) != c.uc.UC_ERR_OK) return;
        self.live += 1;
    }

    /// Why the region covering this address refuses the access, or null when
    /// it allows it. A trap covers a whole region, so a span guarded for one
    /// rule sees accesses the other rules are fine with: a privileged-only
    /// region traps every store, and a privileged one is allowed through here.
    fn verdict(
        self: *Guard,
        handle: ?*c.uc.uc_engine,
        at: u32,
        kind: mpu_fault.Kind,
    ) ?mpu_fault.Reason {
        const unit = self.unit orelse return null;
        const allowed = privileged(handle);
        const region = unit.regionFor(at) orelse {
            return if (background.refuses(unit, allowed)) .background else null;
        };
        return switch (region.refuses(kind, allowed)) {
            .allowed => null,
            .permission => .permission,
            .privilege => .privilege,
        };
    }

    /// Take every trap off, which is what a cleared CTRL.ENABLE means: the
    /// protected spans go back to being ordinary writable memory.
    pub fn disarm(self: *Guard, handle: ?*c.uc.uc_engine) void {
        for (self.hooks[0..self.live]) |hook| _ = c.uc.uc_hook_del(handle, hook);
        self.live = 0;
    }

    /// Turn a trapped access into the exception the core would have taken:
    /// latch the architectural status, put PC back on the instruction so
    /// entry stacks it, and vector into the handler.
    ///
    /// WHICH handler is SHCSR's to say, not the vector table's. MemManage is
    /// a configurable fault and runs only while SHCSR.MEMFAULTENA stands;
    /// with it clear the fault is disabled and escalates to HardFault with
    /// HFSR.FORCED set, whatever the table holds at the MemManage slot. See
    /// src/periph/fault_route.zig.
    ///
    /// With neither handler to reach, the violation is counted and the run
    /// carries on from where the store left it. PC is rewound only once the
    /// entry has happened, because a rewind with nothing to vector into
    /// would re-run the store straight back into the trap that stopped it.
    pub fn synthesise(
        self: *Guard,
        core: anytype,
        controller: ?*nvic.Nvic,
        hit: mpu_fault.Violation,
    ) !void {
        const reason: u32 = switch (hit.kind) {
            // A load and a store are both data accesses, so both latch
            // DACCVIOL and hand MMFAR the address they went for.
            .store, .load => mpu_fault.mmfsr.daccviol | mpu_fault.mmfsr.mmarvalid,
            .fetch => mpu_fault.mmfsr.iaccviol,
        };
        try core.writeWord(memmap.scb.cfsr, (core.readWord(memmap.scb.cfsr) catch 0) | reason);
        // MMFAR belongs to the data cases: a refused fetch leaves MMARVALID
        // clear, so whatever MMFAR held stays where it was.
        if (hit.kind != .fetch) try core.writeWord(memmap.scb.mmfar, hit.address);
        const unit = controller orelse {
            self.standDown(core, hit);
            return;
        };
        const route = fault_route.route(
            .mem_manage,
            core.readWord(memmap.scb.shcsr) catch 0,
            core.readWord(memmap.scb.shpr1) catch 0,
            unit.running(),
        );
        const taken: nvic.Candidate = .{ .number = route.number, .priority = route.priority };
        if (route.escalated) {
            const hfsr = core.readWord(memmap.scb.hfsr) catch 0;
            try core.writeWord(memmap.scb.hfsr, hfsr | status.Hard.forced.bit());
        }
        const stopped_at = try core.register(.pc);
        try core.setRegister(.pc, hit.pc);
        unit.enter(core, taken) catch {
            try core.setRegister(.pc, stopped_at);
            self.standDown(core, hit);
            return;
        };
        self.latch.faults +%= 1;
        if (route.escalated) self.latch.escalated +%= 1;
    }

    /// A violation with no handler to reach. A STORE carries on from where it
    /// left the run: it has already landed, and the PC is past it.
    ///
    /// A fetch and a load both cannot. The PC is still on the refused
    /// instruction, so resuming re-runs it, it is refused again, and the run
    /// spends its whole budget on the same access: 2,949,999 refused loads
    /// out of a 3,000,000-instruction run in fw/probe/mpuregions.elf, which
    /// is what uncovered this. For those two the traps come off so the run
    /// can make progress instead of refusing it forever.
    fn standDown(self: *Guard, core: anytype, hit: mpu_fault.Violation) void {
        self.latch.unhandled +%= 1;
        if (hit.kind == .store) return;
        self.disarm(core.handle);
        flush(core.handle);
        self.latch.stood_down = true;
    }
};

/// A store into a guarded span. Unicorn cannot be told to decline it, so the
/// run is stopped instead and the PC of the store kept: the loop takes the
/// exception at the boundary this makes. A trap is over the whole region, so
/// the rule that refuses this particular access is worked out here.
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
    const guard: *Guard = @ptrCast(@alignCast(user.?));
    const at: u32 = @truncate(address);
    const why = guard.verdict(handle, at, .store) orelse return;
    var pc: u32 = 0;
    _ = c.uc.uc_reg_read(handle, c.uc.UC_ARM_REG_PC, &pc);
    if (!guard.latch.record(.{ .pc = pc, .address = at, .reason = why })) return;
    _ = c.uc.uc_emu_stop(handle);
}

/// A load out of a span kept to privileged code. Unicorn has already served
/// the value by the time the hook runs, the same way a store has already
/// landed, so the refusal is the exception rather than a withheld value: the
/// run stops, the handler runs, and the return re-runs the load.
fn onRead(
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
    const guard: *Guard = @ptrCast(@alignCast(user.?));
    const at: u32 = @truncate(address);
    const why = guard.verdict(handle, at, .load) orelse return;
    var pc: u32 = 0;
    _ = c.uc.uc_reg_read(handle, c.uc.UC_ARM_REG_PC, &pc);
    if (!guard.latch.record(.{ .pc = pc, .address = at, .kind = .load, .reason = why })) return;
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
    const guard: *Guard = @ptrCast(@alignCast(user.?));
    const at: u32 = @truncate(address);
    const why = guard.verdict(handle, at, .fetch) orelse return;
    if (!guard.latch.record(.{ .pc = at, .address = at, .kind = .fetch, .reason = why })) return;
    _ = c.uc.uc_emu_stop(handle);
}

/// Whether the core is privileged right now. Handler mode always is, whatever
/// CONTROL says; thread mode is privileged only while CONTROL.nPRIV is clear
/// (DDI0553 B3.5). Unicorn is asked rather than the model, because this is the
/// core's own state and nothing on the peripheral bus mirrors it.
fn privileged(handle: ?*c.uc.uc_engine) bool {
    var ipsr: u32 = 0;
    _ = c.uc.uc_reg_read(handle, c.uc.UC_ARM_REG_IPSR, &ipsr);
    if (ipsr != 0) return true;
    var control: u32 = 0;
    _ = c.uc.uc_reg_read(handle, c.uc.UC_ARM_REG_CONTROL, &control);
    return control & control_npriv == 0;
}

/// CONTROL[0] nPRIV: set means thread mode runs unprivileged.
const control_npriv: u32 = 1 << 0;
