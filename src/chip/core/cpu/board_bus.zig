//! The Zig core's bus in a full run: the peripheral windows go to the
//! board's peripheral bus, and everything else goes to the core's own
//! store (src/chip/core/cpu/memory/guest/bus.zig).
//!
//! Both the Secure window and its Non-secure alias route to the one
//! peripheral bus, which folds the alias itself. A peripheral access is one
//! register access of 1, 2 or 4 bytes; any other width there is refused
//! rather than split, since splitting would change what the peripheral sees.
const bus = @import("bus.zig");
const scs_files = @import("scs_files.zig");

/// Public so a test can build the latch without a root export.
const std = @import("std");

const banked = @import("../banked.zig");
pub const fault_clear = @import("../../periph/fault/clear.zig");
const fp_scb = @import("fpu/scb.zig");
const fp_state = @import("fpu/state.zig");
const GuestBus = @import("memory/guest/bus.zig").GuestBus;
const memmap = @import("../memmap.zig");
const mpu = @import("../../periph/mpu/mpu.zig");
const mpu_ns = @import("../../periph/mpu/ns.zig");
const registry = @import("../../periph/registry.zig");
const sau = @import("../../periph/sau/sau.zig");

/// Public so its tests reach it without a root export.
const fault_status = @import("../../periph/fault/status.zig");
pub const scs_route = @import("scs_route.zig");

/// Public so its tests reach it without a root export.
const itm_port = @import("../../periph/itm.zig");
pub const mpu_check = @import("mpu_check.zig");
pub const nvic_registers = @import("nvic_registers.zig");
const systick_cut = @import("systick_cut.zig");

/// CFSR's banked bits, UFSR and MMFSR (src/chip/periph/scb/bank.zig).
const cfsr_banked: u32 = 0xFFFF_00FF;

pub const TouchedHook = struct {
    context: *anyopaque,
    touchFn: *const fn (context: *anyopaque, address: u32, is_write: bool) void,

    pub inline fn touch(self: TouchedHook, address: u32, is_write: bool) void {
        self.touchFn(self.context, address, is_write);
    }
};

pub const BoardBus = struct {
    memory: GuestBus,
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
    /// Touched section hook for reverse window tracking. Null when disarmed (zero cost).
    touched: ?TouchedHook = null,

    /// Ask `check` about every access, the direct MRAM/SRAM path included:
    /// a store that path took would land past an MPU refusal (RA8EMU-710).
    pub fn armCheck(self: *BoardBus, check: *mpu_check.Check) void {
        self.check = check;
        switch (self.memory) {
            .store => |*memory| memory.direct.checking = &check.armed,
        }
    }

    pub fn view(self: *BoardBus) bus.Bus {
        const memory = self.memory.view();
        return .{
            .ctx = self,
            .vtable = &.{
                .read = read,
                .write = write,
                .latch = latch,
                .repeat = repeat,
                .peek = peekRegister,
                .allowsExec = allowsExec,
                .touchesPeriph = touchesPeriph,
            },
            .direct = memory.direct,
            .lines = memory.lines,
            .register_state = .{ .ctx = self, .vtable = &.{ .read = readState, .write = writeState } },
        };
    }

    fn readState(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *BoardBus = @ptrCast(@alignCast(ctx));
        return self.memory.view().read(address, into);
    }

    fn writeState(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *BoardBus = @ptrCast(@alignCast(ctx));
        if (self.touched) |t| t.touch(address, true);
        return self.memory.view().write(address, bytes);
    }

    fn isSecure(self: *const BoardBus) bool {
        return if (self.security) |state| state.current == .secure else true;
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
        if (nvic_registers.covers(given)) {
            if (self.check) |c| if (!c.allows(given, .load)) return bus.Error.Unmapped;
            return nvic_registers.read(self.memory.view(), given, self.isSecure(), into);
        }
        if (scs_route.wired(self.security, given)) |halves| return self.readSplit(halves, given, into);
        const address = self.landing(given) orelse return @memset(into, 0);
        if (self.check) |c| if (!c.allows(given, .load)) return bus.Error.Unmapped;
        if (!self.periph.inWindow(address, into.len)) return self.readNonPeriph(address, into);
        return self.readPeriph(address, into);
    }

    fn readNonPeriph(self: *BoardBus, address: u32, into: []u8) bus.Error!void {
        if (self.scs.load(address, into)) {
            if (self.touched) |t| t.touch(address, false);
            return;
        }
        return self.memory.view().read(address, into);
    }

    fn readPeriph(self: *BoardBus, address: u32, into: []u8) bus.Error!void {
        const w = try width(into.len);
        self.periph.issuer = self.issuer;
        const value = self.periph.tryRead(address, w) orelse return bus.Error.Unmapped;
        if (self.touched) |t| t.touch(address, false);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        @memcpy(into, bytes[0..into.len]);
    }

    /// Only a peripheral register repeats, and only when its block says so.
    fn repeat(ctx: *anyopaque, given: u32, len: usize, times: u64) bool {
        const self: *BoardBus = @ptrCast(@alignCast(ctx));
        if (scs_route.wired(self.security, given) != null) return false;
        const address = self.landing(given) orelse return false;
        if (!self.periph.inWindow(address, len)) return false;
        if (self.check) |c| if (!c.allows(given, .load)) return false;
        const w = width(len) catch return false;
        self.periph.issuer = self.issuer;
        const done = self.periph.repeat(address, w, times);
        if (done) if (self.touched) |t| t.touch(address, false);
        return done;
    }

    /// Only a peripheral register peeks, and only when its block keeps one.
    fn peekRegister(ctx: *anyopaque, given: u32, into: []u8) bool {
        const self: *BoardBus = @ptrCast(@alignCast(ctx));
        if (scs_route.wired(self.security, given) != null) return false;
        const address = self.landing(given) orelse return false;
        if (!self.periph.inWindow(address, into.len)) return false;
        if (self.check) |c| if (!c.allows(given, .load)) return false;
        const w = width(into.len) catch return false;
        self.periph.issuer = self.issuer;
        const value = self.periph.peek(address, w) orelse return false;
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        @memcpy(into, bytes[0..into.len]);
        return true;
    }

    fn allowsExec(ctx: *anyopaque, address: u32, len: usize) bool {
        const self: *BoardBus = @ptrCast(@alignCast(ctx));
        if (self.periph.touchesWindow(address, len)) return false;
        return self.memory.view().allowsExec(address, len);
    }

    fn touchesPeriph(ctx: *anyopaque, address: u32, len: usize) ?bool {
        const self: *BoardBus = @ptrCast(@alignCast(ctx));
        return self.periph.touchesWindow(address, len);
    }

    fn write(ctx: *anyopaque, given: u32, bytes: []const u8) bus.Error!void {
        const self: *BoardBus = @ptrCast(@alignCast(ctx));
        if (nvic_registers.covers(given)) {
            if (self.check) |c| if (!c.allows(given, .store)) return bus.Error.Unmapped;
            if (self.touched) |t| t.touch(given, true);
            return nvic_registers.write(self.memory.view(), given, self.isSecure(), bytes);
        }
        if (scs_route.wired(self.security, given)) |halves| return self.writeSplit(halves, given, bytes);
        const address = self.landing(given) orelse return;
        if (self.check) |c| if (!c.allows(given, .store)) return bus.Error.Unmapped;
        if (!self.periph.inWindow(address, bytes.len)) return self.writeNonPeriph(address, bytes);
        return self.writePeriph(address, bytes);
    }

    fn writeNonPeriph(self: *BoardBus, address: u32, bytes: []const u8) bus.Error!void {
        if (address >= memmap.ppb_base and address < memmap.ppb_base + 0x0010_0000) {
            if (self.touched) |t| t.touch(address, true);
        }
        return self.scs.store(self.memory, address, bytes);
    }

    fn writePeriph(self: *BoardBus, address: u32, bytes: []const u8) bus.Error!void {
        var padded = @as([4]u8, @splat(0));
        const w = try width(bytes.len);
        @memcpy(padded[0..bytes.len], bytes);
        self.periph.issuer = self.issuer;
        if (!self.periph.tryWrite(address, w, std.mem.readInt(u32, &padded, .little))) {
            return bus.Error.Unmapped;
        }
        if (self.touched) |t| t.touch(address, true);
    }

    /// Where an access lands, or null for RES0: the SCS bank the core's
    /// state names, and once a Non-secure MPU is wired, that MPU's own copy
    /// for the Non-secure view of an MPU register (RA8EMU-447).
    fn landing(self: *const BoardBus, given: u32) ?u32 {
        const secure = if (self.security) |s| s.current == .secure else true;
        if (self.scs.regions_ns != null) if (mpu_ns.copyOf(given, secure)) |at| return at;
        return switch (scs_route.land(self.security, given)) {
            .at => |at| at,
            .res0 => null,
        };
    }

    /// A bit-by-bit SCB register read from its Non-secure view: the shared
    /// bits from the normal word, the banked ones from the Non-secure copy.
    fn readSplit(self: *BoardBus, halves: scs_route.Split, given: u32, into: []u8) bus.Error!void {
        if (self.touched) |t| t.touch(given, false);
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
        if (self.touched) |t| t.touch(given, true);
        const within = given & 3;
        if (within + bytes.len > 4) return bus.Error.Unmapped;
        const memory = self.memory.view();
        const shared = try memory.readWord(halves.shared);
        const copy = try memory.readWord(halves.non_secure);
        // A write-one-to-clear lane left unwritten clears nothing.
        var word: [4]u8 = undefined;
        std.mem.writeInt(u32, &word, if (halves.clears) 0 else halves.read(shared, copy), .little);
        @memcpy(word[within..][0..bytes.len], bytes);
        const words = halves.write(shared, copy, std.mem.readInt(u32, &word, .little));
        try scs_files.putWord(memory, halves.non_secure, words.non_secure);
        std.mem.writeInt(u32, &word, words.shared, .little);
        try self.scs.store(self.memory, halves.shared, &word);
    }

    /// CFSR, HFSR and SFSR as the Secure bank holds them, read past the
    /// write-one-to-clear model for the run report (RA8EMU-394).
    pub fn faults(self: *BoardBus) fault_status.Words {
        // A Non-secure fault's UFSR and MMFSR bits sit in the Non-secure
        // copy; folded in, the report shows one word (RA8EMU-444).
        const ns_bits = self.peek(memmap.scb.cfsr + 0x2_0000) & cfsr_banked;
        return .{
            .cfsr = self.peek(memmap.scb.cfsr) | ns_bits,
            .hfsr = self.peek(memmap.scb.hfsr),
            .sfsr = self.peek(0xE000_EDE4),
        };
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
        if (self.touched) |t| t.touch(given, true);
        if (scs_route.wired(self.security, given)) |halves| {
            try self.raise(halves.non_secure, bits & halves.mask);
            return self.raise(halves.shared, bits & ~halves.mask);
        }
        const address = switch (scs_route.land(self.security, given)) {
            .at => |at| at,
            .res0 => return,
        };
        return self.raise(address, bits);
    }

    fn raise(self: *BoardBus, address: u32, bits: u32) bus.Error!void {
        if (bits == 0) return;
        const memory = self.memory.view();
        try scs_files.putWord(memory, address, try memory.readWord(address) | bits);
    }
};

/// The models inside a core that a plain store into its PPB RAM must reach,
/// the store side of the models src/board/wiring.zig wires.
/// Each is optional: a bus without one leaves that window as plain RAM.
pub const Scs = struct {
    /// SAU RBAR/RLAR bank through RNR.
    partitions: ?*sau.Sau = null,
    /// MPU pairs bank through RNR.
    /// Enforcement is not armed from here.
    regions: ?*mpu.Mpu = null,
    /// The Non-secure MPU, programmed through its own copy at +0x20000
    /// (src/chip/periph/mpu/ns.zig). Null keeps every MPU access on `regions`.
    regions_ns: ?*mpu.Mpu = null,
    /// CFSR, HFSR and SFSR are write-one-to-clear. The store is settled
    /// as it lands, so no read in between sees the raw word.
    clears: ?*fault_clear.Clears = null,
    /// FPCCR, FPCAR and FPDSCR, read and written in the core's FP state.
    fp: ?*fp_state.State = null,
    /// The SysTick timers a store can arm, and the stretch cut it latches
    /// (RA8EMU-464). Null leaves every SysTick store to RAM alone.
    cut: ?*systick_cut.Cut = null,
    /// The ITM a plain run keeps port 0's text in (RA8EMU-629). Null
    /// leaves the ITM window as plain RAM.
    itm: ?*itm_port.Itm = null,

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
        const owed = if (self.clears) |unit| (if (unit.slot(address) != null) unit else null) else null;
        const standing = if (owed != null) try memory.readWord(address & ~@as(u32, 3)) else 0;
        if (self.cut) |edge| try edge.see(memory, address, bytes);
        try memory.write(address, bytes);
        if (owed) |unit| {
            var padded = @as([4]u8, @splat(0));
            @memcpy(padded[0..@min(bytes.len, 4)], bytes[0..@min(bytes.len, 4)]);
            unit.record(address, @intCast(bytes.len), std.mem.readInt(u32, &padded, .little), standing);
            unit.apply(memory) catch return bus.Error.Unmapped;
        }
        if (self.partitions) |unit| try scs_files.bankPartition(memory, unit, address, bytes);
        if (self.regions) |unit| try scs_files.bankRegion(memory, unit, address, bytes, 0);
        if (self.regions_ns) |unit| if (mpu_ns.normalOf(address)) |normal| {
            try scs_files.bankRegion(memory, unit, normal, bytes, mpu_ns.offset);
        };
        if (self.fp) |state| try scs_files.fileFp(memory, state, address, bytes);
        if (self.itm) |port| try scs_files.fileItm(memory, port, address, bytes);
    }
};
