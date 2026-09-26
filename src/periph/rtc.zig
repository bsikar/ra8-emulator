//! RTC: the calendar that keeps time, and an alarm that goes off once.
//!
//! The RTC sits at 0x4020_2000 in an 0x80 window (ra8_rtc_regs.h). Firmware
//! brings it up by clearing RCR2 and waiting for the mode bit to read back,
//! setting HR24 and waiting again, writing the counters, then setting
//! RCR2.START; from there the counters advance on their own and an armed
//! RxxAR raises the alarm event. Every readback in that sequence is a poll
//! loop, so a register that does not answer is an image that never leaves
//! init, which is why the block is a faithful shadow with a real time mirror
//! behind it rather than a handful of interpreted bits.
//!
//! Ported from board_periph_rtc.c on dev, with four things that model does
//! not do.
//!
//! A COUNTER IS NOT WRITABLE WHILE THE CLOCK RUNS. dev stores into the
//! calendar counters whenever firmware asks and reseeds the running mirror
//! from them, so an image that sets the time without first clearing
//! RCR2.START works there and loses the write on silicon, where the counters
//! are only writable with the count stopped. Here the store is refused and
//! counted, so the run says which writes went nowhere.
//!
//! THE ALARM IS AN EDGE. dev re-evaluates the match every modelled second
//! and raises the event again on each one, so an alarm armed on the hour
//! alone raises 3600 events and reports 3600 alarms for what firmware asked
//! to be told about once. The match here has to become true to raise
//! anything, and re-arms only once the time no longer matches.
//!
//! THE WHOLE ALARM IS HONOURED. dev compares the second, minute and hour
//! registers and ignores the day, month and year alarms entirely, so an
//! alarm armed for a date fires on the first matching time of any day. The
//! day and month fields take part here on the same enable-bit rule, and
//! RYRAREN arms the year.
//!
//! R64CNT IS READ-ONLY. dev writes any offset in the window into its
//! shadow, R64CNT included, so firmware can store a sub-second count and
//! read its own invention back out of a free-running counter. Refused and
//! counted here.
//!
//! NOT MODELLED, AND NOT GUESSED: RCR1.PES, so a periodic-enabled clock
//! offers one periodic event per modelled second whatever interval was
//! selected; the day-of-week counter and its alarm, which dev does not
//! maintain either; RCR2's reset, adjustment and sub-clock bits; and RCR4's
//! count source. No header for this part is in this tree, so those are
//! shadowed for readback and never interpreted.
const std = @import("std");

const periph = @import("registry.zig");
const clock = @import("rtc_clock.zig");

/// RTC geometry (ra8_rtc_regs.h). The bus folds the Non-secure alias onto
/// this base before it arrives.
pub const win_base: u32 = 0x4020_2000;
pub const win_span: u32 = 0x80;

/// The registers this model interprets. The gaps between them are the
/// 16-bit counter union the FSP type declares.
pub const off = struct {
    pub const r64cnt: u32 = 0x00;
    pub const seccnt: u32 = 0x02;
    pub const mincnt: u32 = 0x04;
    pub const hrcnt: u32 = 0x06;
    pub const wkcnt: u32 = 0x08;
    pub const daycnt: u32 = 0x0A;
    pub const moncnt: u32 = 0x0C;
    pub const yrcnt: u32 = 0x0E;
    pub const secar: u32 = 0x10;
    pub const minar: u32 = 0x12;
    pub const hrar: u32 = 0x14;
    pub const wkar: u32 = 0x16;
    pub const dayar: u32 = 0x18;
    pub const monar: u32 = 0x1A;
    pub const yrar: u32 = 0x1C;
    pub const yraren: u32 = 0x1E;
    pub const rcr1: u32 = 0x22;
    pub const rcr2: u32 = 0x24;
    pub const rcr4: u32 = 0x28;
};

/// RCR1 interrupt enables and the RCR2 run bit.
pub const control = struct {
    pub const aie: u8 = 0x01;
    pub const cie: u8 = 0x02;
    pub const pie: u8 = 0x04;
    pub const start: u8 = 0x01;
};

/// R64CNT counts 0..63.
pub const r64_mask: u8 = 0x3F;

/// The RTC's two ELC events (RA8D2 ELC signal table; FSP bsp_elc.h).
pub const event = struct {
    pub const alarm: u16 = 0x0BB;
    pub const periodic: u16 = 0x0BC;
};

/// Modelled seconds per chunk boundary. dev uses eight boundaries to the
/// second, which is right for a run loop that ticks thousands of times; this
/// board's chunk is half a million instructions, so a default run reaches
/// the boundary about four times and a clock geared like dev's would never
/// reach its first second. One second per boundary is what makes a
/// multi-second alarm reachable inside the instruction budget.
pub const seconds_per_tick: u8 = 1;

/// Both events can come due in the same boundary.
pub const Due = std.BoundedArray(u16, 2);

/// The modelled RTC: the register shadow firmware reads, the binary time
/// behind it, and what the run should be told happened.
pub const Rtc = struct {
    reg: [win_span]u8 = .{0} ** win_span,
    now: clock.Calendar = .{},
    /// The sub-second counter. No real 64 Hz time base here, so it is a
    /// count that moves rather than one that measures.
    r64: u8 = 0,
    /// The alarm edge: whether the time matched at the last evaluation.
    matched: bool = false,
    /// Modelled seconds the clock has counted.
    seconds: u32 = 0,
    /// Times the armed alarm came round.
    matches: u32 = 0,
    /// Alarm events actually raised, which needs RCR1.AIE.
    alarms: u32 = 0,
    /// Periodic events raised, which needs RCR1.PIE.
    periodics: u32 = 0,
    /// Counter writes refused because the count was running.
    refused_running: u32 = 0,
    /// Stores into R64CNT, which is read-only.
    refused_read_only: u32 = 0,
    due_alarm: bool = false,
    due_periodic: bool = false,

    pub fn init() Rtc {
        var self = Rtc{};
        self.publish();
        return self;
    }

    pub fn quiet(self: *const Rtc) bool {
        return self.seconds == 0 and self.matches == 0 and self.periodics == 0 and
            self.refused_running == 0 and self.refused_read_only == 0;
    }

    pub fn running(self: *const Rtc) bool {
        return self.reg[off.rcr2] & control.start != 0;
    }

    /// One chunk boundary. A stopped clock holds its time, which is what
    /// lets firmware write the counters at all.
    pub fn tick(self: *Rtc) void {
        if (!self.running()) return;
        self.r64 = (self.r64 +% 1) & r64_mask;
        var elapsed: u8 = 0;
        while (elapsed < seconds_per_tick) : (elapsed += 1) {
            self.now.advance();
            self.seconds +%= 1;
        }
        self.publish();
        self.checkAlarm();
        if (self.reg[off.rcr1] & control.pie != 0) {
            self.periodics +%= 1;
            self.due_periodic = true;
        }
    }

    /// The events this boundary earned, offered once.
    pub fn dueEvents(self: *Rtc) Due {
        var due = Due{};
        if (self.due_alarm) {
            self.due_alarm = false;
            due.appendAssumeCapacity(event.alarm);
        }
        if (self.due_periodic) {
            self.due_periodic = false;
            due.appendAssumeCapacity(event.periodic);
        }
        return due;
    }

    pub fn read(self: *Rtc, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        if (offset >= win_span) return 0;
        var value: u32 = 0;
        var index: u32 = 0;
        while (index < width and offset + index < win_span) : (index += 1) {
            const shift: u5 = @intCast(index * 8);
            value |= @as(u32, self.reg[offset + index]) << shift;
        }
        return value;
    }

    pub fn write(self: *Rtc, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        if (offset >= win_span) return;
        var reseed = false;
        var index: u32 = 0;
        while (index < width and offset + index < win_span) : (index += 1) {
            const shift: u5 = @intCast(index * 8);
            const byte: u8 = @truncate(value >> shift);
            if (self.store(offset + index, byte)) reseed = true;
        }
        // A counter write is how firmware sets the time, so the binary
        // mirror is reloaded from what was just written, once per store
        // rather than once per byte.
        if (reseed) self.latch();
    }

    /// One byte of a store. Returns whether it landed on a calendar counter.
    fn store(self: *Rtc, offset: u32, byte: u8) bool {
        if (offset == off.r64cnt) {
            self.refused_read_only +%= 1;
            return false;
        }
        if (!isCalendar(offset)) {
            self.reg[offset] = byte;
            return false;
        }
        if (self.running()) {
            self.refused_running +%= 1;
            return false;
        }
        self.reg[offset] = byte;
        return true;
    }

    /// Publish the binary time into the BCD counters firmware reads.
    fn publish(self: *Rtc) void {
        self.reg[off.r64cnt] = self.r64 & r64_mask;
        self.reg[off.seccnt] = clock.bcd.fromBinary(self.now.second);
        self.reg[off.mincnt] = clock.bcd.fromBinary(self.now.minute);
        self.reg[off.hrcnt] = clock.bcd.fromBinary(self.now.hour);
        self.reg[off.daycnt] = clock.bcd.fromBinary(self.now.day);
        self.reg[off.moncnt] = clock.bcd.fromBinary(self.now.month);
        self.reg[off.yrcnt] = clock.bcd.fromBinary(self.now.year);
    }

    /// Reload the binary time from counters firmware has just written. The
    /// edge state is taken from the new time without raising: setting the
    /// clock onto the alarm value is not the counter reaching it.
    fn latch(self: *Rtc) void {
        self.now = .{
            .second = clock.bcd.toBinary(self.reg[off.seccnt]),
            .minute = clock.bcd.toBinary(self.reg[off.mincnt]),
            .hour = clock.bcd.toBinary(self.reg[off.hrcnt]),
            .day = clock.bcd.toBinary(self.reg[off.daycnt]),
            .month = clock.bcd.toBinary(self.reg[off.moncnt]),
            .year = clock.bcd.toBinary(self.reg[off.yrcnt]),
        };
        self.matched = self.alarmMatches();
    }

    /// Raise on the rising edge of the match, and only with AIE set.
    fn checkAlarm(self: *Rtc) void {
        const matches_now = self.alarmMatches();
        defer self.matched = matches_now;
        if (!matches_now or self.matched) return;
        self.matches +%= 1;
        if (self.reg[off.rcr1] & control.aie == 0) return;
        self.alarms +%= 1;
        self.due_alarm = true;
    }

    /// Every armed field has to agree, and at least one has to be armed:
    /// an alarm nobody armed is not a match against a zeroed register file.
    pub fn alarmMatches(self: *const Rtc) bool {
        if (!self.armed()) return false;
        return clock.alarm.agrees(self.reg[off.secar], self.now.second) and
            clock.alarm.agrees(self.reg[off.minar], self.now.minute) and
            clock.alarm.agrees(self.reg[off.hrar], self.now.hour) and
            clock.alarm.agrees(self.reg[off.dayar], self.now.day) and
            clock.alarm.agrees(self.reg[off.monar], self.now.month) and
            self.yearAgrees();
    }

    pub fn armed(self: *const Rtc) bool {
        const fields = [_]u8{
            self.reg[off.secar], self.reg[off.minar], self.reg[off.hrar],
            self.reg[off.dayar], self.reg[off.monar], self.reg[off.yraren],
        };
        for (fields) |field| {
            if (clock.alarm.armed(field)) return true;
        }
        return false;
    }

    /// The year alarm keeps its value in RYRAR and its enable next door in
    /// RYRAREN, the one field whose two halves live in different registers.
    fn yearAgrees(self: *const Rtc) bool {
        if (!clock.alarm.armed(self.reg[off.yraren])) return true;
        return clock.bcd.toBinary(self.reg[off.yrar]) == self.now.year;
    }

    pub fn block(self: *Rtc) periph.Block {
        return .{
            .name = "RTC",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// The counter registers, the ones a running clock owns.
fn isCalendar(offset: u32) bool {
    return switch (offset) {
        off.seccnt, off.mincnt, off.hrcnt, off.daycnt, off.moncnt, off.yrcnt => true,
        else => false,
    };
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Rtc = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Rtc = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
