//! The interrupt poll's shortcut (RA8EMU-318).
//!
//! `Cpu.run` asks its source what is pending before every instruction, and
//! on the board that answer costs a dozen reads of the NVIC and SCB through
//! the bus. Inside one stretch nothing can change it unless the core itself
//! touches peripheral or system space, takes an exception or returns from
//! one: the board's clocks and peripherals only move at a stretch boundary.
//! So once the source has answered "nothing pending", that answer stands
//! until one of those happens or the next stretch starts.
//!
//! Give the core `bus()` and `source()` in place of the board's own, and let
//! `Cpu.run` call `stir` as each stretch starts.
const bus_mod = @import("../bus.zig");
const Entry = @import("active.zig").Entry;
const Source = @import("source.zig").Source;

/// The first address of peripheral space. Everything below it is flash and
/// RAM, which never decides what is pending.
pub const peripheral_base: u32 = 0x4000_0000;

/// The first address of the PPB. Reading the SCB or NVIC never changes what
/// is pending, so a read from here on leaves the answer standing; the poll
/// itself reads AIRCR and SHCSR every instruction (RA8EMU-418).
pub const ppb_base: u32 = 0xE000_0000;

pub const QuietSource = struct {
    /// The source that actually knows: the NVIC model on the board.
    inner: Source,
    /// The run's own bus, which `bus()` watches.
    memory: bus_mod.Bus,
    /// The last answer was "nothing pending" and nothing has stirred since.
    settled: bool = false,

    pub fn source(self: *QuietSource) Source {
        return .{ .ctx = self, .vtable = &.{ .winner = winner, .taken = taken, .returned = returned } };
    }

    /// The run's bus, noticing every access that could pend or unpend.
    pub fn bus(self: *QuietSource) bus_mod.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write }, .direct = self.memory.direct };
    }

    /// Forget the last answer: the next poll asks the inner source again.
    pub fn stir(self: *QuietSource) void {
        self.settled = false;
    }

    fn winner(ctx: *anyopaque, through: bus_mod.Bus) bus_mod.Error!?Entry {
        const self: *QuietSource = @ptrCast(@alignCast(ctx));
        if (self.settled) return null;
        const found = try self.inner.winner(through);
        // The inner source's own reads went through `through` and stirred;
        // its answer is what settles.
        self.settled = found == null;
        return found;
    }

    fn taken(ctx: *anyopaque, through: bus_mod.Bus, number: u9) bus_mod.Error!void {
        const self: *QuietSource = @ptrCast(@alignCast(ctx));
        self.stir();
        return self.inner.taken(through, number);
    }

    fn returned(ctx: *anyopaque, through: bus_mod.Bus, number: u9) bus_mod.Error!void {
        const self: *QuietSource = @ptrCast(@alignCast(ctx));
        self.stir();
        return self.inner.returned(through, number);
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus_mod.Error!void {
        const self: *QuietSource = @ptrCast(@alignCast(ctx));
        if (address >= peripheral_base and address < ppb_base) self.stir();
        return self.memory.read(address, into);
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus_mod.Error!void {
        const self: *QuietSource = @ptrCast(@alignCast(ctx));
        if (address >= peripheral_base) self.stir();
        return self.memory.write(address, bytes);
    }
};
