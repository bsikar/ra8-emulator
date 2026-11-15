//! Ten 16-bit reloading AGT down-counters at 0x4022_1000 (ra8_agt_regs.h).
//!
//! AGT/+0x00 seeds the count and reload; AGTCMA/+0x02 and AGTCMB/+0x04
//! select compare values. AGTCR/+0x08 controls TSTART, TCSTF, TSTOP and
//! underflow/compare flags. TSTOP takes precedence over TSTART, clears TCSTF
//! and holds the count (HUM 24.2.6 p1175; ULPT 25.2.1 p1190).
//! Counter writes require a stopped channel; rejected writes are counted.
//! Uninterpreted registers retain narrow writes in each channel's shadow.
//!
//! compare.zig gates compare flags with AGTCMSR.TCMEA/TCMEB, including a
//! valid zero compare. clock.zig selects AGTMR1.TCK and divided/cascade clocks.
//! AGT1 cascade must start before AGT0; missed underflows are counted
//! (ra8_agt.h; HUM 24.2.4 p1167).
//!
//! AGTMR2.CKS, output-enable/polarity pins and separate compare interrupts
//! are not modelled. Only AGT0's combined underflow event is raised.
const bounded = @import("../../core/bounded.zig");

const clk = @import("clock.zig");
const periph = @import("../registry.zig");

pub const clock = clk;
const cmp = @import("compare.zig");

pub const compare = cmp;

/// AGT geometry (ra8_agt_regs.h).
pub const win_base: u32 = 0x4022_1000;
pub const stride: u32 = 0x100;
pub const channels: usize = 10;
pub const win_span: u32 = stride * @as(u32, channels);

pub const off = struct {
    pub const cnt: u32 = 0x00;
    pub const cma: u32 = 0x02;
    pub const cmb: u32 = 0x04;
    pub const cr: u32 = 0x08;
    pub const mr1: u32 = 0x09;
    pub const cmsr: u32 = cmp.off_cmsr;
};

/// AGTCR. TSTART is read/write, TCSTF read-only, TSTOP write-only, and the
/// three status flags are write-ZERO-to-clear.
pub const control = struct {
    pub const tstart: u8 = 0x01;
    pub const tcstf: u8 = 0x02;
    pub const tstop: u8 = 0x04;
    pub const tundf: u8 = 0x20;
    pub const tcmaf: u8 = 0x40;
    pub const tcmbf: u8 = 0x80;
    pub const flags: u8 = tundf | tcmaf | tcmbf;
};

/// The AGT0 combined interrupt (RA8D2 ELC signal table; FSP bsp_elc.h). The
/// other nine channels have no event this tree names, so they count silently.
pub const event = struct {
    pub const agt0: u16 = 0x0DF;
};

/// Counts one chunk boundary stands for at the undivided source, carried
/// from dev unchanged. AGTMR1's divider scales it down from here.
pub const step_per_tick: u16 = 0x0800;

/// At most one event per boundary, from channel 0.
pub const Due = bounded.Bounded(u16, 1);
pub const sched = @import("sched.zig");

/// One channel: the live count, the two compare values, the control byte,
/// and a shadow for every register this model does not interpret.
pub const Channel = struct {
    counter: u16 = 0,
    reload: u16 = 0,
    cmpa: u16 = 0,
    cmpb: u16 = 0,
    cr: u8 = 0,
    mr1: u8 = 0,
    cmsr: u8 = 0,
    shadow: [stride]u8 = @splat(0),
    underflows: u32 = 0,
    matches_a: u32 = 0,
    matches_b: u32 = 0,
    /// Compare values the count passed while AGTCMSR had that side
    /// disabled, so a flag nobody armed is reported rather than raised.
    masked: u32 = 0,
    /// Stops taken through TSTOP, the bit dev discards.
    forced_stops: u32 = 0,
    /// Counter and compare writes refused because the count was running.
    refused_running: u32 = 0,
    /// Boundaries this channel was stepped by the channel it cascades from.
    cascaded_steps: u32 = 0,
    /// Underflows handed to this channel while its own count was stopped.
    /// On the cascade pair that is the start-order bug: AGT0 running before
    /// AGT1 was armed, so the high half never saw those wraps.
    dropped_cascade: u32 = 0,

    pub fn running(self: Channel) bool {
        return self.cr & control.tstart != 0;
    }

    /// What AGTMR1 selects for this channel. The index matters: only
    /// channel 1 can take AGT0's underflow as its source.
    pub fn source(self: Channel, index: usize) clk.Source {
        return clk.sourceOf(self.mr1, index);
    }

    /// One chunk of counting at whatever source AGTMR1 selects. Returns true
    /// when the count underflowed, which is one interrupt request on silicon
    /// whatever TUNDF already reads.
    pub fn tick(self: *Channel, index: usize) bool {
        return self.advance(clk.step(step_per_tick, self.source(index)));
    }

    /// A cascaded channel counts the underflows handed to it, not a clock.
    /// Handed one while stopped, it loses it: the source wrapped and there
    /// was nothing counting, which is what the start-order rule is about.
    pub fn tickCascade(self: *Channel, underflows: u16) bool {
        if (underflows == 0) return false;
        if (!self.running()) {
            self.dropped_cascade +%= underflows;
            return false;
        }
        self.cascaded_steps +%= 1;
        return self.advance(underflows);
    }

    /// Step the count down by `step`, flagging whatever it passed.
    pub fn advance(self: *Channel, step: u16) bool {
        if (!self.running() or step == 0) return false;
        const before = self.counter;
        if (before >= step) {
            // Reaching exactly zero is not the underflow: the borrow happens
            // on the next decrement past it.
            self.counter = before - step;
            self.match(before, false);
            return false;
        }
        const span = @as(u32, self.reload) + 1;
        const deficit = @as(u32, step) - before;
        self.counter = self.reload - @as(u16, @intCast((deficit - 1) % span));
        self.cr |= control.tundf;
        self.underflows +%= 1;
        self.match(before, true);
        return true;
    }

    /// Flag the compare values this chunk counted past, on the sides
    /// AGTCMSR armed. A side the driver never enabled counts the crossing
    /// and raises nothing.
    fn match(self: *Channel, before: u16, wrapped: bool) void {
        if (crossed(before, self.counter, wrapped, self.reload, self.cmpa)) {
            self.side(.a, control.tcmaf, &self.matches_a);
        }
        if (crossed(before, self.counter, wrapped, self.reload, self.cmpb)) {
            self.side(.b, control.tcmbf, &self.matches_b);
        }
    }

    /// One crossing, on one side: the flag when the function is enabled,
    /// the masked count when it is not.
    fn side(self: *Channel, which: cmp.Side, flag: u8, count: *u32) void {
        if (!cmp.enabled(self.cmsr, which)) {
            self.masked +%= 1;
            return;
        }
        self.cr |= flag;
        count.* +%= 1;
    }

    /// Whether either compare side is armed, which is what makes a compare
    /// value worth printing at all.
    pub fn comparing(self: Channel) bool {
        return cmp.enabled(self.cmsr, .a) or cmp.enabled(self.cmsr, .b);
    }

    /// TSTOP beats TSTART in the same write, and a status flag only survives
    /// a write that carried its bit set.
    fn writeControl(self: *Channel, value: u8) void {
        const keep = self.cr & value & control.flags;
        if (value & control.tstop != 0) {
            if (self.running()) self.forced_stops +%= 1;
            self.cr = keep;
            return;
        }
        const start = value & control.tstart;
        self.cr = start | (if (start != 0) control.tcstf else 0) | keep;
    }

    fn readByte(self: *const Channel, local: u32) u8 {
        return switch (local) {
            off.cnt, off.cnt + 1 => lane(self.counter, local - off.cnt),
            off.cma, off.cma + 1 => lane(self.cmpa, local - off.cma),
            off.cmb, off.cmb + 1 => lane(self.cmpb, local - off.cmb),
            off.cr => self.cr,
            off.mr1 => self.mr1,
            off.cmsr => self.cmsr,
            else => self.shadow[local],
        };
    }

    fn writeByte(self: *Channel, local: u32, byte: u8) void {
        switch (local) {
            off.cnt, off.cnt + 1 => self.seed(local - off.cnt, byte),
            off.cma, off.cma + 1 => self.compare(&self.cmpa, local - off.cma, byte),
            off.cmb, off.cmb + 1 => self.compare(&self.cmpb, local - off.cmb, byte),
            off.cr => self.writeControl(byte),
            off.mr1 => self.mr1 = byte,
            off.cmsr => self.cmsr = byte,
            else => self.shadow[local] = byte,
        }
    }

    /// A counter write sets both the live count and the value it reloads
    /// from, and only with the count stopped.
    fn seed(self: *Channel, index: u32, byte: u8) void {
        if (self.running()) {
            self.refused_running +%= 1;
            return;
        }
        self.counter = merge(self.counter, index, byte);
        self.reload = self.counter;
    }

    fn compare(self: *Channel, target: *u16, index: u32, byte: u8) void {
        if (self.running()) {
            self.refused_running +%= 1;
            return;
        }
        target.* = merge(target.*, index, byte);
    }

    pub fn quiet(self: Channel) bool {
        return self.underflows == 0 and self.matches_a == 0 and self.matches_b == 0 and
            self.masked == 0 and self.forced_stops == 0 and self.refused_running == 0 and
            self.cascaded_steps == 0 and self.dropped_cascade == 0 and !self.running();
    }
};

/// Whether a count stepping from `before` down to `after` passed `target`.
/// A wrapped chunk runs down through zero and then back down from the
/// reload, so it covers both ends.
pub fn crossed(before: u16, after: u16, wrapped: bool, reload: u16, target: u16) bool {
    if (!wrapped) return target < before and target >= after;
    return target < before or (target >= after and target <= reload);
}

fn lane(value: u16, index: u32) u8 {
    return @truncate(value >> @intCast(index * 8));
}

fn merge(value: u16, index: u32, byte: u8) u16 {
    const shift: u4 = @intCast(index * 8);
    const mask = ~(@as(u16, 0xFF) << shift);
    return (value & mask) | (@as(u16, byte) << shift);
}

pub const Agt = struct {
    channels: [channels]Channel = @splat(.{}),
    /// Channel 0 underflows not yet handed to the event path.
    pending: u32 = 0,

    pub fn init() Agt {
        return .{};
    }

    /// One boundary. Channels count in index order, so AGT0's underflow is
    /// already known by the time the cascade pair's high half is reached.
    pub fn tick(self: *Agt) void {
        var carried: u16 = 0;
        for (&self.channels, 0..) |*channel, index| {
            const cascaded = channel.source(index).cascaded();
            const underflowed = if (cascaded)
                channel.tickCascade(carried)
            else
                channel.tick(index);
            if (index == clk.cascade.low and underflowed) carried += 1;
            if (index == 0 and underflowed) self.pending +%= 1;
        }
    }

    /// One event per boundary at most; a backlog drains on later boundaries.
    pub fn dueEvents(self: *Agt) Due {
        var due = Due{};
        if (self.pending == 0) return due;
        self.pending -= 1;
        due.appendAssumeCapacity(event.agt0);
        return due;
    }

    pub fn quiet(self: *const Agt) bool {
        for (self.channels) |channel| {
            if (!channel.quiet()) return false;
        }
        return true;
    }

    pub fn read(self: *Agt, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        if (offset >= win_span) return 0;
        const channel = &self.channels[offset / stride];
        const local = offset % stride;
        var value: u32 = 0;
        var index: u32 = 0;
        while (index < width and local + index < stride) : (index += 1) {
            const shift: u5 = @intCast(index * 8);
            value |= @as(u32, channel.readByte(local + index)) << shift;
        }
        return value;
    }

    pub fn write(self: *Agt, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        if (offset >= win_span) return;
        const channel = &self.channels[offset / stride];
        const local = offset % stride;
        var index: u32 = 0;
        while (index < width and local + index < stride) : (index += 1) {
            const shift: u5 = @intCast(index * 8);
            channel.writeByte(local + index, @truncate(value >> shift));
        }
    }

    pub fn block(self: *Agt) periph.Block {
        return .{
            .name = "AGT",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Agt = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Agt = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
