//! Mirror SCS writes into the guest-visible register files.
const bus = @import("bus.zig");
const fault_clear = @import("../../periph/fault/clear.zig");
const fp_scb = @import("fpu/scb.zig");
const fp_state = @import("fpu/state.zig");
const GuestBus = @import("memory/guest/bus.zig").GuestBus;
const itm_port = @import("../../periph/itm.zig");
const memmap = @import("../memmap.zig");
const mpu = @import("../../periph/mpu/mpu.zig");
const mpu_ns = @import("../../periph/mpu/ns.zig");
const sau = @import("../../periph/sau/sau.zig");
const scs_mod = @import("../machine/scs.zig");
const scs_regs = @import("scs_regs.zig");
const std = @import("std");
const systick_cut = @import("systick_cut.zig");

/// The models inside a core that a plain store into its PPB RAM must reach,
/// the store side of the models src/board/wiring.zig wires.
/// Each is optional: a bus without one leaves that window as plain RAM.
pub const Scs = struct {
    /// SAU RBAR/RLAR bank through RNR.
    partitions: ?*sau.Sau = null,
    /// MPU pairs bank through RNR.
    regions: ?*mpu.Mpu = null,
    /// The Non-secure MPU, programmed through its own copy at +0x20000.
    regions_ns: ?*mpu.Mpu = null,
    /// CFSR, HFSR and SFSR are write-one-to-clear.
    clears: ?*fault_clear.Clears = null,
    /// FPCCR, FPCAR and FPDSCR, read and written in the core's FP state.
    fp: ?*fp_state.State = null,
    /// The SysTick timers a store can arm, and the stretch cut it latches.
    cut: ?*systick_cut.Cut = null,
    /// The ITM a plain run keeps port 0's text in.
    itm: ?*itm_port.Itm = null,
    /// Per-core SCS configuration and timer/security geometry.
    config: scs_mod.ScsConfig = .{},
    systicks: u2 = 2,
    has_security: bool = true,
    dwt_numcomp: ?u4 = null,
    fpb_wired: bool = false,

    pub fn policy(self: Scs) scs_regs.Policy {
        return .{
            .config = self.config,
            .systicks = self.systicks,
            .has_security = self.has_security,
            .dwt_numcomp = self.dwt_numcomp,
            .fpb_wired = self.fpb_wired,
        };
    }

    /// A word read of FPCCR, FPCAR or FPDSCR answered from the FP state;
    /// false leaves the read to RAM.
    pub fn load(self: Scs, address: u32, into: []u8) bool {
        const state = self.fp orelse return false;
        if (into.len != fp_scb.width) return false;
        const value = fp_scb.read(state, address) orelse return false;
        std.mem.writeInt(u32, into[0..4], value, .little);
        return true;
    }

    /// A store outside the peripheral windows: RAM, then whichever of the
    /// core's own SCS models the address belongs to.
    pub fn store(self: Scs, guest_memory: GuestBus, address: u32, bytes: []const u8) bus.Error!void {
        var reach = guest_memory;
        const memory = reach.view();
        var shpr_buf: [4]u8 = undefined;
        const effective = scs_regs.applyShprMask(self.policy(), address, bytes, &shpr_buf) orelse bytes;
        const owed = if (self.clears) |unit| (if (unit.slot(address) != null) unit else null) else null;
        const standing = if (owed != null) try memory.readWord(address & ~@as(u32, 3)) else 0;
        if (self.cut) |edge| try edge.see(memory, address, effective);
        try memory.write(address, effective);
        if (owed) |unit| {
            var padded = @as([4]u8, @splat(0));
            @memcpy(padded[0..@min(effective.len, 4)], effective[0..@min(effective.len, 4)]);
            unit.record(address, @intCast(effective.len), std.mem.readInt(u32, &padded, .little), standing);
            unit.apply(memory) catch return bus.Error.Unmapped;
        }
        if (self.partitions) |unit| try bankPartition(memory, unit, address, effective);
        if (self.regions) |unit| try bankRegion(memory, unit, address, effective, 0);
        if (self.regions_ns) |unit| if (mpu_ns.normalOf(address)) |normal| {
            try bankRegion(memory, unit, normal, effective, mpu_ns.offset);
        };
        if (self.fp) |state| try fileFp(memory, state, address, effective);
        if (self.itm) |port| try fileItm(memory, port, address, effective);
    }
};

/// File a word store into the SAU window and, when it moved RNR, put the
/// selected region's pair back in RAM so the next RBAR/RLAR read gives the
/// region RNR names rather than the last one programmed.
pub fn bankPartition(memory: bus.Bus, unit: *sau.Sau, address: u32, bytes: []const u8) bus.Error!void {
    if (bytes.len != 4 or address < memmap.sau.ctrl or address > memmap.sau.rlar) return;
    const word = std.mem.readInt(u32, bytes[0..4], .little);
    if (unit.observe(address, word) == .none) return;
    const pair = unit.bankedPair();
    try putWord(memory, memmap.sau.rbar, pair.rbar);
    try putWord(memory, memmap.sau.rlar, pair.rlar);
}

/// File a word store into the MPU window and, when it moved RNR, put the
/// four pairs RNR now selects back in RAM. A CTRL store is taken into the
/// table by `observe`.
/// `shift` is where the bank's copy sits above the normal window.
pub fn bankRegion(memory: bus.Bus, unit: *mpu.Mpu, address: u32, bytes: []const u8, shift: u32) bus.Error!void {
    if (bytes.len != 4 or address < memmap.mpu.type_ or address > memmap.mpu.mair1) return;
    const word = std.mem.readInt(u32, bytes[0..4], .little);
    if (unit.observe(address, word) != .rebank) return;
    const pairs = [_][2]u32{
        .{ memmap.mpu.rbar, memmap.mpu.rlar },
        .{ memmap.mpu.rbar_a1, memmap.mpu.rlar_a1 },
        .{ memmap.mpu.rbar_a2, memmap.mpu.rlar_a2 },
        .{ memmap.mpu.rbar_a3, memmap.mpu.rlar_a3 },
    };
    for (pairs, 0..) |where, offset| {
        const words = unit.pairFor(@intCast(offset));
        try putWord(memory, where[0] + shift, words[0]);
        try putWord(memory, where[1] + shift, words[1]);
    }
}

/// File a word store to FPCCR, FPCAR or FPDSCR in the FP state and put the
/// masked value back in RAM, so a plain RAM read agrees with the model.
pub fn fileFp(memory: bus.Bus, state: *fp_state.State, address: u32, bytes: []const u8) bus.Error!void {
    if (bytes.len != fp_scb.width) return;
    if (!fp_scb.write(state, address, std.mem.readInt(u32, bytes[0..4], .little))) return;
    try putWord(memory, address, fp_scb.read(state, address).?);
}

/// File a store into the ITM's registers and put back what a read of the
/// register sees, so a stimulus port polled after a character still reads
/// FIFOREADY rather than the character (RA8EMU-629).
pub fn fileItm(memory: bus.Bus, port: *itm_port.Itm, address: u32, bytes: []const u8) bus.Error!void {
    if (address < itm_port.base or address - itm_port.base >= itm_port.limits.span) return;
    const offset = address - itm_port.base;
    const width = @min(bytes.len, 4);
    var padded = @as([4]u8, @splat(0));
    @memcpy(padded[0..width], bytes[0..width]);
    if (!port.write(offset, std.mem.readInt(u32, &padded, .little), @intCast(width))) return;
    if (port.peek(offset)) |word| try putWord(memory, address, word);
}

pub fn putWord(memory: bus.Bus, address: u32, value: u32) bus.Error!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try memory.write(address, &bytes);
}
