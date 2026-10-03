//! The Zig core's bus in a full run: the peripheral windows go to the
//! board's peripheral bus, the same handlers Unicorn's MMIO hooks call, and
//! everything else goes to memory through the engine.
//!
//! Both the Secure window and its Non-secure alias route to the one
//! peripheral bus, which folds the alias itself. A peripheral access is one
//! register access of 1, 2 or 4 bytes; any other width there is refused
//! rather than split, since splitting would change what the peripheral sees.
const std = @import("std");
const bus = @import("bus.zig");
const EngineBus = @import("engine_bus.zig").EngineBus;
const registry = @import("../../periph/registry.zig");
const memmap = @import("../memmap.zig");
const sau = @import("../../periph/sau.zig");
const mpu = @import("../../periph/mpu/mpu.zig");
/// Public so a test can build the latch without a root export.
pub const fault_clear = @import("../../periph/fault_clear.zig");
const fp_state = @import("fpu/state.zig");
const fp_scb = @import("fpu/scb.zig");
const banked = @import("../banked.zig");
/// Public so its tests reach it without a root export.
pub const scs_route = @import("scs_route.zig");
const fault_status = @import("../../periph/fault_status.zig");
/// Public so its tests reach it without a root export.
pub const mpu_check = @import("mpu_check.zig");

pub const BoardBus = struct {
    memory: EngineBus,
    periph: *registry.Bus,
    /// The core this bus view belongs to, stamped on every peripheral access.
    issuer: registry.Issuer = .cpu0,
    /// The core's own SCS models its stores reach.
    scs: Scs = .{},
    /// The core's Security state, which picks the bank an SCS access lands
    /// on (scs_route.zig). Null is a core that only runs Secure.
    security: ?*const banked.Banked = null,
    /// The core's MPU check, asked about every access while it is armed.
    check: ?*mpu_check.Check = null,

    pub fn view(self: *BoardBus) bus.Bus {
        const memory = self.memory.view();
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write, .latch = latch }, .direct = memory.direct };
    }

    /// Whether the whole access sits in either peripheral window.
    pub fn inWindow(address: u32, len: usize) bool {
        const end = @as(u64, address) + len;
        for ([_]u32{ registry.base, registry.ns_base }) |window| {
            if (address >= window and end <= @as(u64, window) + registry.size) return true;
        }
        return false;
    }

    fn width(len: usize) bus.Error!u3 {
        return switch (len) {
            1, 2, 4 => @intCast(len),
            else => bus.Error.Unmapped,
        };
    }

    fn read(ctx: *anyopaque, given: u32, into: []u8) bus.Error!void {
        const self: *BoardBus = @ptrCast(@alignCast(ctx));
        if (scs_route.wired(self.security, given)) |halves| return self.readSplit(halves, given, into);
        const address = switch (scs_route.land(self.security, given)) {
            .at => |at| at,
            .res0 => return @memset(into, 0),
        };
        if (self.check) |c| if (!c.allows(given, .load)) return bus.Error.Unmapped;
        if (!inWindow(address, into.len)) {
            if (self.scs.load(address, into)) return;
            return self.memory.view().read(address, into);
        }
        self.periph.issuer = self.issuer;
        const value = self.periph.read(address, try width(into.len));
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        @memcpy(into, bytes[0..into.len]);
    }

    fn write(ctx: *anyopaque, given: u32, bytes: []const u8) bus.Error!void {
        const self: *BoardBus = @ptrCast(@alignCast(ctx));
        if (scs_route.wired(self.security, given)) |halves| return self.writeSplit(halves, given, bytes);
        const address = switch (scs_route.land(self.security, given)) {
            .at => |at| at,
            .res0 => return,
        };
        if (self.check) |c| if (!c.allows(given, .store)) return bus.Error.Unmapped;
        if (!inWindow(address, bytes.len)) return self.scs.store(self.memory, address, bytes);
        var padded = [_]u8{0} ** 4;
        const w = try width(bytes.len);
        @memcpy(padded[0..bytes.len], bytes);
        self.periph.issuer = self.issuer;
        self.periph.write(address, w, std.mem.readInt(u32, &padded, .little));
    }

    /// A bit-by-bit SCB register read from its Non-secure view: the shared
    /// bits from the normal word, the banked ones from the Non-secure copy.
    fn readSplit(self: *BoardBus, halves: scs_route.Split, given: u32, into: []u8) bus.Error!void {
        const within = given & 3;
        if (within + into.len > 4) return bus.Error.Unmapped;
        const memory = self.memory.view();
        const merged = halves.read(try memory.readWord(halves.shared), try memory.readWord(halves.non_secure));
        var word: [4]u8 = undefined;
        std.mem.writeInt(u32, &word, merged, .little);
        @memcpy(into, word[within..][0..into.len]);
    }

    /// The write twin of readSplit: the bytes land on the merged word, the
    /// shared bits go back through Scs.store and the banked ones to the copy.
    fn writeSplit(self: *BoardBus, halves: scs_route.Split, given: u32, bytes: []const u8) bus.Error!void {
        const within = given & 3;
        if (within + bytes.len > 4) return bus.Error.Unmapped;
        const memory = self.memory.view();
        const shared = try memory.readWord(halves.shared);
        const copy = try memory.readWord(halves.non_secure);
        var word: [4]u8 = undefined;
        std.mem.writeInt(u32, &word, halves.read(shared, copy), .little);
        @memcpy(word[within..][0..bytes.len], bytes);
        const words = halves.write(shared, copy, std.mem.readInt(u32, &word, .little));
        try putWord(memory, halves.non_secure, words.non_secure);
        std.mem.writeInt(u32, &word, words.shared, .little);
        try self.scs.store(self.memory, halves.shared, &word);
    }

    /// CFSR, HFSR and SFSR as the Secure bank holds them, read past the
    /// write-one-to-clear model for the run report (RA8EMU-394).
    pub fn faults(self: *BoardBus) fault_status.Words {
        return .{ .cfsr = self.peek(memmap.scb.cfsr), .hfsr = self.peek(memmap.scb.hfsr), .sfsr = self.peek(0xE000_EDE4) };
    }

    fn peek(self: *BoardBus, given: u32) u32 {
        const address = switch (scs_route.land(null, given)) {
            .at => |at| at,
            .res0 => return 0,
        };
        return self.memory.view().readWord(address) catch 0;
    }

    /// The core raising a fault: set `bits` in the banked word straight in
    /// RAM. Going through `write` would reach Scs.store, whose
    /// write-one-to-clear takes every one written as an acknowledge and
    /// clears the bit it was asked to raise (RA8EMU-394).
    fn latch(ctx: *anyopaque, given: u32, bits: u32) bus.Error!void {
        const self: *BoardBus = @ptrCast(@alignCast(ctx));
        const address = switch (scs_route.land(self.security, given)) {
            .at => |at| at,
            .res0 => return,
        };
        const memory = self.memory.view();
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, try memory.readWord(address) | bits, .little);
        try memory.write(address, &bytes);
    }
};

/// The models inside a core that a plain store into its PPB RAM must reach,
/// the Zig twin of the Unicorn store hooks src/board/wiring.zig attaches.
/// Each is optional: a bus without one leaves that window as plain RAM.
pub const Scs = struct {
    /// SAU RBAR/RLAR bank through RNR, as src/core/sau_hook.zig does.
    partitions: ?*sau.Sau = null,
    /// MPU pairs bank through RNR, as src/core/mpu_hook.zig does.
    /// Enforcement is not armed from here.
    regions: ?*mpu.Mpu = null,
    /// CFSR, HFSR and SFSR are write-one-to-clear. Unicorn latches the clear
    /// in a hook and settles it at the boundary; here the store is settled
    /// as it lands, so no read in between sees the raw word.
    clears: ?*fault_clear.Clears = null,
    /// FPCCR, FPCAR and FPDSCR, read and written in the core's FP state.
    fp: ?*fp_state.State = null,

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
    pub fn store(self: Scs, engine_memory: EngineBus, address: u32, bytes: []const u8) bus.Error!void {
        var reach = engine_memory;
        const memory = reach.view();
        const owed = if (self.clears) |unit| (if (unit.slot(address) != null) unit else null) else null;
        const standing = if (owed != null) try memory.readWord(address & ~@as(u32, 3)) else 0;
        try memory.write(address, bytes);
        if (owed) |unit| {
            var padded = [_]u8{0} ** 4;
            @memcpy(padded[0..@min(bytes.len, 4)], bytes[0..@min(bytes.len, 4)]);
            unit.record(address, @intCast(bytes.len), std.mem.readInt(u32, &padded, .little), standing);
            unit.apply(engine_memory.core.*) catch return bus.Error.Unmapped;
        }
        if (self.partitions) |unit| try bankPartition(memory, unit, address, bytes);
        if (self.regions) |unit| try bankRegion(memory, unit, address, bytes);
        if (self.fp) |state| try fileFp(memory, state, address, bytes);
    }
};

/// File a word store into the SAU window and, when it moved RNR, put the
/// selected region's pair back in RAM so the next RBAR/RLAR read gives the
/// region RNR names rather than the last one programmed.
fn bankPartition(memory: bus.Bus, unit: *sau.Sau, address: u32, bytes: []const u8) bus.Error!void {
    if (bytes.len != 4 or address < memmap.sau.ctrl or address > memmap.sau.rlar) return;
    const word = std.mem.readInt(u32, bytes[0..4], .little);
    if (unit.observe(address, word) == .none) return;
    const pair = unit.bankedPair();
    try putWord(memory, memmap.sau.rbar, pair.rbar);
    try putWord(memory, memmap.sau.rlar, pair.rlar);
}

/// File a word store into the MPU window and, when it moved RNR, put the
/// four pairs RNR now selects back in RAM. A CTRL store is taken into the
/// table by `observe`; the Unicorn-only traps it rearms have no Zig twin.
fn bankRegion(memory: bus.Bus, unit: *mpu.Mpu, address: u32, bytes: []const u8) bus.Error!void {
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
        try putWord(memory, where[0], words[0]);
        try putWord(memory, where[1], words[1]);
    }
}

/// File a word store to FPCCR, FPCAR or FPDSCR in the FP state and put the
/// masked value back in RAM, so a plain RAM read agrees with the model.
fn fileFp(memory: bus.Bus, state: *fp_state.State, address: u32, bytes: []const u8) bus.Error!void {
    if (bytes.len != fp_scb.width) return;
    if (!fp_scb.write(state, address, std.mem.readInt(u32, bytes[0..4], .little))) return;
    try putWord(memory, address, fp_scb.read(state, address).?);
}

fn putWord(memory: bus.Bus, address: u32, value: u32) bus.Error!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try memory.write(address, &bytes);
}
