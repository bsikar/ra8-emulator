//! The Zig core's bus in a full run: peripheral windows route to the board's
//! peripheral bus and everything else routes to the core's store.
const banked = @import("../banked.zig");
const bus = @import("bus.zig");
pub const fault_clear = @import("../../periph/fault/clear.zig");
const fault_status = @import("../../periph/fault/status.zig");
const GuestBus = @import("memory/guest/bus.zig").GuestBus;
const memmap = @import("../memmap.zig");
const mpu = @import("../../periph/mpu/mpu.zig");
pub const mpu_check = @import("mpu_check.zig");
const mpu_ns = @import("../../periph/mpu/ns.zig");
pub const nvic_registers = @import("nvic_registers.zig");
const registry = @import("../../periph/registry.zig");
const scs_files = @import("scs_files.zig");
pub const scs_regs = @import("scs_regs.zig");
pub const scs_route = @import("scs_route.zig");
const std = @import("std");

pub const Scs = scs_files.Scs;

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
        if (try self.readIntercepted(given, into)) return;
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

    fn readIntercepted(self: *BoardBus, given: u32, into: []u8) bus.Error!bool {
        if (!self.scs.has_security and inNsAlias(given)) {
            @memset(into, 0);
            return true;
        }
        if (nvic_registers.covers(given)) {
            try self.requireAllowed(given, .load);
            try nvic_registers.readFor(self.memory.view(), given, self.isSecure(), self.scs.config.irq_lines, into);
            return true;
        }
        if (scs_route.wiredWith(self.security, given, self.scs.systicks, self.scs.has_security)) |halves| {
            try self.readSplit(halves, given, into);
            return true;
        }
        try self.requireAllowed(given, .load);
        if (try scs_regs.read(self.scs.policy(), self.memory.view(), given, self.isSecure(), into)) {
            if (self.touched) |t| t.touch(given, false);
            return true;
        }
        return false;
    }

    /// Only a peripheral register repeats, and only when its block says so.
    fn repeat(ctx: *anyopaque, given: u32, len: usize, times: u64) bool {
        const self: *BoardBus = @ptrCast(@alignCast(ctx));
        if (scs_route.wiredWith(self.security, given, self.scs.systicks, self.scs.has_security) != null) return false;
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
        if (scs_route.wiredWith(self.security, given, self.scs.systicks, self.scs.has_security) != null) return false;
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
        if (try self.writeIntercepted(given, bytes)) return;
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

    fn writeIntercepted(self: *BoardBus, given: u32, bytes: []const u8) bus.Error!bool {
        if (!self.scs.has_security and inNsAlias(given)) return true;
        if (nvic_registers.covers(given)) {
            try self.requireAllowed(given, .store);
            if (self.touched) |t| t.touch(given, true);
            try nvic_registers.writeFor(self.memory.view(), given, self.isSecure(), self.scs.config.irq_lines, bytes);
            return true;
        }
        if (scs_route.wiredWith(self.security, given, self.scs.systicks, self.scs.has_security)) |halves| {
            try self.writeSplit(halves, given, bytes);
            return true;
        }
        try self.requireAllowed(given, .store);
        if (try scs_regs.write(self.scs.policy(), self.memory.view(), given, self.isSecure(), bytes)) {
            if (self.touched) |t| t.touch(given, true);
            return true;
        }
        return false;
    }

    fn requireAllowed(self: *const BoardBus, given: u32, kind: mpu.fault.Kind) bus.Error!void {
        if (self.check) |c| if (!c.allows(given, kind)) return bus.Error.Unmapped;
    }

    /// Where an access lands, or null for RES0: the SCS bank the core's
    /// state names, and once a Non-secure MPU is wired, that MPU's own copy
    /// for the Non-secure view of an MPU register (RA8EMU-447).
    fn landing(self: *const BoardBus, given: u32) ?u32 {
        const secure = if (self.security) |s| s.current == .secure else true;
        if (self.scs.regions_ns != null) if (mpu_ns.copyOf(given, secure)) |at| return at;
        return switch (scs_route.landWith(self.security, given, self.scs.systicks, self.scs.has_security)) {
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
        const pol = self.scs.policy();
        try scs_files.putWord(memory, halves.non_secure, scs_regs.maskShprWord(pol, halves.shared, words.non_secure));
        std.mem.writeInt(u32, &word, scs_regs.maskShprWord(pol, halves.shared, words.shared), .little);
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
        if (scs_route.wiredWith(self.security, given, self.scs.systicks, self.scs.has_security)) |halves| {
            try self.raise(halves.non_secure, bits & halves.mask);
            return self.raise(halves.shared, bits & ~halves.mask);
        }
        const address = switch (scs_route.landWith(self.security, given, self.scs.systicks, self.scs.has_security)) {
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

fn inNsAlias(address: u32) bool {
    return address >= 0xE002_E000 and address <= 0xE002_EFFF;
}
