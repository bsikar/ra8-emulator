//! The controller receive path: what the addressed device staged for this
//! read, and the reads that take it back out one byte at a time.
//!
//! The flow does one dummy ICDRR read to start the data clock before the
//! first real byte (HUM Ch 39.3.4 "Controller Receive Operation", p 2400 and
//! Ch 39.2.18 "ICDRR", p 2393), so the first access after the address phase
//! carries nothing. RDRF stands while a byte is waiting and goes away with
//! the last one.
const flag = @import("riic_flags.zig");

/// How much of a device's answer one transfer can hold.
pub const stage_bytes = 64;

pub const Rx = struct {
    /// What the addressed device staged for this read.
    staged: [stage_bytes]u8 = .{0} ** stage_bytes,
    staged_len: usize = 0,
    served: usize = 0,
    /// The dummy read that starts the clock has not happened yet.
    primed: bool = false,

    /// Reads past what the device had to say. dev served zeros, so a driver
    /// reading too far got data that looked real.
    overread: u32 = 0,

    /// A STOP request terminates the receive frame after its in-flight byte.
    /// Devices may expose more data than the controller asked to clock; those
    /// bytes are not pending bus traffic once the controller requests STOP.
    pub fn stopAfterNext(self: *Rx) void {
        self.staged_len = @min(self.staged_len, self.served + 1);
    }

    /// Start a frame empty: nothing staged, nothing served, clock not yet
    /// running.
    pub fn open(self: *Rx) void {
        self.staged_len = 0;
        self.served = 0;
        self.primed = false;
    }

    /// Take what the device has to say for this frame.
    pub fn stage(self: *Rx, len: usize) void {
        self.staged_len = len;
        self.served = 0;
        self.primed = false;
    }

    /// A byte is still waiting to be handed over.
    pub fn holding(self: *const Rx) bool {
        return self.served < self.staged_len;
    }

    /// The next ICDRR access. `status` is the channel's ICSR2, since RDRF
    /// moves with the data. Answers null when the access was the dummy read
    /// that only starts the clock.
    pub fn take(self: *Rx, status: *u8) ?u8 {
        if (!self.primed) {
            self.primed = true;
            return null;
        }
        if (!self.holding()) {
            // Nothing left on the line. RDRF goes away with the data.
            self.overread += 1;
            status.* &= ~flag.icsr2.rdrf;
            return null;
        }
        const byte = self.staged[self.served];
        self.served += 1;
        if (self.holding()) {
            status.* |= flag.icsr2.rdrf;
        } else {
            status.* &= ~flag.icsr2.rdrf;
        }
        return byte;
    }

    pub fn quiet(self: *const Rx) bool {
        return self.overread == 0;
    }
};
