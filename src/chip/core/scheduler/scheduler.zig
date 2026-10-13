//! Scalar scheduler state shared by the plain run and debugger adapters.
pub const position = @import("position.zig");
pub const stretch = @import("stretch.zig");
pub const Position = position.Position;
pub const Stretch = stretch.Stretch;
const Cpu = @import("../cpu/cpu.zig").Cpu;
const rate = @import("../rate.zig");
const Pending = @import("../cpu/systick_cut.zig").Pending;

// The divider can change during CPU1's turn. Validate against every rate
// openTurn could have latched, rather than recomputing from today's divider.
pub fn validTurnShare(carry: u32, share: u32) bool {
    for (0..256) |word| if (rate.turn(carry, @intCast(word)) == share) return true;
    return false;
}

pub fn pairEvents(a: *Cpu, b: *Cpu) void {
    a.event_sender = .{ .context = b, .sendFn = sendEvent };
    b.event_sender = .{ .context = a, .sendFn = sendEvent };
}

fn sendEvent(context: *anyopaque) void {
    const cpu: *Cpu = @ptrCast(@alignCast(context));
    cpu.event = true;
    if (cpu.quiet) |quiet| quiet.stirAll();
}

pub const State = struct {
    at: Position = .{},
    stretch: Stretch = .{},
    base: [2]u64 = .{ 0, 0 },
    lengths: [2]u32 = .{ 0, 0 },
    cut: bool = false,
    cut_pending: Pending = .{},

    pub fn open(self: *State, width: u32, slots: u64) void {
        if (self.stretch.full != 0) return;
        self.base[0] = slots;
        self.stretch.open(width);
    }

    pub fn advance(self: *State, elapsed: u32, slots: u32) void {
        self.stretch.carry += elapsed;
        self.lengths[0] += slots;
        self.at.o = self.lengths[0];
        self.at.gap = .retired;
    }

    pub fn endCpu0(self: *State, cut: bool, dual: bool) void {
        self.cut = cut;
        self.at.phase = if (dual and !cut) .cpu1 else .board;
        self.at.o = 0;
        self.at.gap = .retired;
    }

    pub fn next(self: *State) void {
        self.at.r += 1;
        self.at.phase = .cpu0;
        self.at.o = 0;
        self.at.gap = .retired;
        for (&self.base, self.lengths) |*base, length| base.* += length;
        self.lengths = .{ 0, 0 };
        self.stretch = .{};
        self.cut = false;
        self.cut_pending = .{};
    }

    /// Whether this is a state a round can stop in. CPU0's phase ends only on
    /// a cut or a spent interval, CPU1 runs only after an uncut one, and
    /// `next` must still have a round to count to.
    pub fn valid(self: State) bool {
        if (self.at.r == 0xffffffffffffffff) return false;
        for (self.base, self.lengths) |base, length| if (base > 0xffffffffffffffff - @as(u64, length)) return false;
        if (self.stretch.carry > self.stretch.full or self.lengths[0] > self.stretch.carry) return false;
        if (self.cut and (self.stretch.carry == 0 or self.lengths[1] != 0)) return false;
        if (!self.cut and (self.cut_pending.bank != .secure or self.cut_pending.old_reload != 0 or self.cut_pending.old_control != 0)) return false;
        if (!self.cut and (self.cut_pending.old_current != 0 or self.cut_pending.current_written)) return false;
        if (!self.cut_pending.valid()) return false;
        const spent = self.stretch.full != 0 and self.stretch.left() == 0;
        return switch (self.at.phase) {
            .cpu0 => self.at.o == self.lengths[0] and self.lengths[1] == 0,
            .cpu1 => spent and !self.cut and self.at.o == self.lengths[1],
            .board => (spent or self.cut) and self.at.o <= 1 and self.at.gap == .retired,
        };
    }
};
