//! The RIIC target (peripheral) role: the emulator is the external controller.
//!
//! Once firmware programmes an own address (SARLy) and enables its slot
//! (ICSER.SARyE), the part answers as a target and something else on the bus
//! drives the clock. Headless there is nothing else, so this model IS that
//! controller: it writes a known payload at the firmware's own address, reads
//! it back, and checks the firmware echoed what it was sent.
const std = @import("std");
const flag = @import("riic_flags.zig");
const bus = @import("riic_bus.zig");

/// The script the synthetic controller drives.
pub const script = struct {
    pub const payload = [_]u8{ 0xDE, 0xAD };
    pub const cycles: u32 = 4;
    /// Echo capture bound. Two bytes go out per cycle; anything past this is
    /// a firmware fault, not a transfer.
    pub const capture: usize = 8;
};

pub const Phase = enum {
    /// No own address armed: the target model is inert.
    idle,
    /// The controller is writing the payload (RDRF then STOP).
    writing,
    /// The controller is reading the echo back (TDRE and TEND).
    reading,
    /// Script complete: the bus is quiet and no address matches.
    done,
};

pub const Target = struct {
    phase: Phase = .idle,
    armed: bool = false,
    own_address: u7 = 0,
    /// The target-role ICSR2 the firmware polls.
    status: u8 = 0,
    /// ICDRR serves consumed this write; 0 is the matched address byte.
    served: usize = 0,
    /// Echo bytes the firmware transmitted this read.
    echoed: usize = 0,
    captured: [script.capture]u8 = .{0} ** script.capture,
    cycles: u32 = 0,
    mismatched: bool = false,
    /// ICSER writes that named a slot whose own-address register was still
    /// zero. dev latched it and answered at address 0x00, which is the
    /// general call and never a target's own address, so the firmware looked
    /// like it was being addressed by a controller that could not exist.
    unaddressed: u32 = 0,

    pub fn quiet(self: *const Target) bool {
        return self.cycles == 0 and self.unaddressed == 0 and !self.armed;
    }

    /// ICSER decides whether the responder is armed. The enabled slot's own
    /// address has to be a real one before anything answers.
    pub fn open(self: *Target, icser: u8, own: [3]u8) void {
        if (icser & flag.icser.slots == 0) {
            self.armed = false;
            self.phase = .idle;
            return;
        }
        const slot: usize = if (icser & flag.icser.sar1e != 0)
            1
        else if (icser & flag.icser.sar2e != 0)
            2
        else
            0;
        const address: u7 = @truncate(own[slot] >> bus.wire.addr_shift);
        if (bus.reserved.holds(address)) {
            self.unaddressed += 1;
            self.armed = false;
            self.phase = .idle;
            return;
        }
        self.own_address = address;
        self.armed = true;
        self.beginWrite();
    }

    fn beginWrite(self: *Target) void {
        self.phase = .writing;
        self.served = 0;
        self.status = flag.icsr2.rdrf;
    }

    fn beginRead(self: *Target) void {
        self.phase = .reading;
        self.echoed = 0;
        self.status = flag.icsr2.tdre | flag.icsr2.tend;
    }

    /// ICSR1: the own-address match, asserted while a phase is in flight.
    pub fn matched(self: *const Target) u8 {
        return switch (self.phase) {
            .writing, .reading => flag.icsr1.aas0,
            else => 0,
        };
    }

    /// ICCR2 in target mode: TRS only while the controller is reading.
    pub fn direction(self: *const Target, shadow: u8) u8 {
        const base = shadow & ~flag.iccr2.trs;
        return if (self.phase == .reading) base | flag.iccr2.trs else base;
    }

    /// ICDRR: the matched address byte first, the way the driver's dummy read
    /// expects, then the payload.
    pub fn receive(self: *Target) u8 {
        if (self.phase != .writing) return 0;
        const byte: u8 = if (self.served == 0)
            bus.wire.byte(self.own_address, false)
        else if (self.served <= script.payload.len)
            script.payload[self.served - 1]
        else
            0;
        self.served += 1;
        self.status = if (self.served > script.payload.len) flag.icsr2.stop else flag.icsr2.rdrf;
        return byte;
    }

    /// ICDRT: capture what the firmware echoes back.
    pub fn transmit(self: *Target, byte: u8) void {
        if (self.phase != .reading) return;
        if (self.echoed < script.capture) self.captured[self.echoed] = byte;
        self.echoed += 1;
    }

    /// ICSR2 is write-0-to-clear, and clearing the condition flag is what
    /// moves the script on: the receive path clears STOP, the transmit path
    /// clears its own.
    pub fn acknowledge(self: *Target, value: u8) void {
        self.status &= value;
        switch (self.phase) {
            .writing => self.beginRead(),
            .reading => self.completeRead(),
            else => {},
        }
    }

    fn completeRead(self: *Target) void {
        if (self.echoed != script.payload.len or
            !std.mem.eql(u8, self.captured[0..self.echoed], &script.payload))
        {
            self.mismatched = true;
        }
        self.cycles += 1;
        if (self.cycles < script.cycles) {
            self.beginWrite();
        } else {
            self.phase = .done;
            self.status = 0;
        }
    }
};
