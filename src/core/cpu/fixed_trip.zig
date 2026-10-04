//! A loop whose trip changes nothing retires at once (RA8EMU-463).
//!
//! RA8EMU-450 skips NOP/B park loops. Idle loops that poll memory, such as
//! ThreadX's __tx_ts_wait (cpsid i; ldr; str; cbnz; cpsie i; b), touch RAM
//! and PRIMASK, so that test refuses them. Here the core watches one trip
//! from a calm loop head (park.calmHead): every instruction still steps and
//! polls as usual, but the data bus goes through a recorder. Back at the head,
//! if the registers, FP state, banked registers, exclusive monitor, event
//! register and active exceptions all equal their values when the trip
//! started, and every store wrote the bytes already there, the next trip
//! starts from the same state and memory, so every one after it is the same.
//! `run` then retires the whole trips that fit, as 450 does.
//!
//! Any access outside flash or RAM (a peripheral could answer differently
//! next time), a trip longer than `max_trip`, or a head that stops being calm
//! ends the watch with no skip. A loop that fails waits `backoff` arrivals
//! before it is watched again, so a counting loop costs one slow trip in
//! that many.
const std = @import("std");
const bus = @import("bus.zig");
const memmap = @import("../memmap.zig");
/// Public so park_test reaches park.zig without a root export.
pub const park = @import("park.zig");
const Cpu = @import("cpu.zig").Cpu;
const Regs = @import("regs.zig").Regs;
const FpState = @import("fpu/state.zig").State;
const Banked = @import("../banked.zig").Banked;
const Active = @import("exception/all.zig").active.Active;

pub const max_trip: u32 = 64;
pub const backoff: u16 = 256;

/// What one trip may not change.
const Snapshot = struct {
    regs: Regs,
    fp: FpState,
    banked: Banked,
    active: Active,
    exclusive: ?u32,
    event: bool,

    fn take(cpu: *const Cpu) Snapshot {
        return .{ .regs = cpu.regs, .fp = cpu.fp, .banked = cpu.banked, .active = cpu.active, .exclusive = cpu.exclusive, .event = cpu.event };
    }

    /// Field by field: the padding between fields holds no value.
    fn same(self: *const Snapshot, cpu: *const Cpu) bool {
        return bytesEqual(&self.regs, &cpu.regs) and bytesEqual(&self.fp, &cpu.fp) and
            bytesEqual(&self.banked, &cpu.banked) and bytesEqual(&self.active, &cpu.active) and
            self.exclusive == cpu.exclusive and self.event == cpu.event;
    }
};

pub const Watch = struct {
    on: bool = false,
    head: u32 = 0,
    steps: u32 = 0,
    /// A store changed a byte, or an access left flash and RAM.
    spoiled: bool = false,
    inner: bus.Bus = undefined,
    before: Snapshot = undefined,
    miss_pc: u32 = 0,
    miss_wait: u16 = 0,

    /// Called before each instruction `run` executes: instructions to retire
    /// at once from the PC, or 0 to step as usual.
    pub fn observe(self: *Watch, cpu: *Cpu, left: u64) u64 {
        const pc = cpu.regs.pc;
        if (!self.on) {
            self.begin(cpu);
            return 0;
        }
        if (pc != self.head) {
            self.steps += 1;
            if (self.steps > max_trip or self.spoiled) self.miss(cpu);
            return 0;
        }
        const trip: u64 = self.steps;
        const fixed = !self.spoiled and trip != 0 and self.before.same(cpu) and park.calmHead(cpu) != null;
        if (!fixed) {
            self.miss(cpu);
            return 0;
        }
        self.drop(cpu);
        if (left < trip) return 0;
        return left - left % trip;
    }

    fn begin(self: *Watch, cpu: *Cpu) void {
        const found = park.calmHead(cpu) orelse return;
        if (park.tripLength(found) != null) return; // 450's cheaper path
        if (found.start == self.miss_pc and self.miss_wait != 0) {
            self.miss_wait -= 1;
            return;
        }
        // The head instruction is the trip's first.
        self.* = .{ .on = true, .head = found.start, .steps = 1, .inner = cpu.bus, .before = Snapshot.take(cpu), .miss_pc = self.miss_pc };
        cpu.bus = .{ .ctx = self, .vtable = &vtable, .gate = self.inner.gate };
    }

    fn miss(self: *Watch, cpu: *Cpu) void {
        const head = self.head;
        self.drop(cpu);
        self.miss_pc = head;
        self.miss_wait = backoff;
    }

    /// Put the real bus back. `run` calls this on every way out.
    pub fn drop(self: *Watch, cpu: *Cpu) void {
        if (!self.on) return;
        cpu.bus = self.inner;
        self.on = false;
    }

    const vtable = bus.Bus.VTable{ .read = read, .write = write };

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Watch = @ptrCast(@alignCast(ctx));
        if (!readable(address, into.len)) self.spoiled = true;
        return self.inner.read(address, into);
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *Watch = @ptrCast(@alignCast(ctx));
        var old: [16]u8 = undefined;
        if (!writable(address, bytes.len) or bytes.len > old.len) {
            self.spoiled = true;
        } else {
            try self.inner.read(address, old[0..bytes.len]);
            if (!std.mem.eql(u8, old[0..bytes.len], bytes)) self.spoiled = true;
        }
        return self.inner.write(address, bytes);
    }
};

fn bytesEqual(a: anytype, b: @TypeOf(a)) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

fn within(address: u32, len: usize, base: u32, end: u32) bool {
    return address >= base and address < end and len <= end - address;
}

/// RAM: what only the core and stretch-boundary agents change.
pub fn writable(address: u32, len: usize) bool {
    const ns = memmap.ns_offset;
    return within(address, len, memmap.dtcm_base, memmap.dtcm_end) or
        within(address, len, memmap.dtcm_base + ns, memmap.dtcm_end + ns) or
        within(address, len, memmap.sram_base, memmap.sram_end) or
        within(address, len, memmap.ns_sram_base, memmap.ns_sram_end);
}

/// RAM, code flash and the ITCM: what a trip may read and see the same next time.
pub fn readable(address: u32, len: usize) bool {
    return writable(address, len) or
        within(address, len, memmap.itcm_base, memmap.itcm_end) or
        within(address, len, memmap.mram_base, memmap.mram_end) or
        within(address, len, memmap.ns_mram_base, memmap.ns_mram_end);
}
