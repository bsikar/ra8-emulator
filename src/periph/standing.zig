//! How long PendSV's pend bit stands before anything takes it.
//!
//! WHY THIS EXISTS. `held` (src/periph/held.zig) counts a pend the pick
//! OFFERED and the controller refused, and `passed` (src/periph/passed.zig)
//! counts a pend that lost the pick to something more urgent. Between them
//! they describe every boundary the controller reasoned about. What neither
//! can show is a bit that simply stands, boundary after boundary, while the
//! run goes on around it: nothing is refused, nothing loses, and the only
//! trace is an exception that never happens.
//!
//! Measured on `wdt_supervisor_demo` over 200 modelled ms, which is why this
//! exists. ThreadX suspends a thread 375 times and asks for a context switch
//! every time, but the report showed only 11 boundaries where the firmware
//! raised a fresh pend and 376 stores that landed on a bit already standing.
//! PendSV was entered 8 times. A scheduler that is owed 375 switches and
//! gets 8 does not run, and the supervisor thread carries on looping instead
//! of sleeping: hence `WDT0: one refresh every 0.7 SysTick period(s)` where
//! its own source asks for one every 50.
//!
//! The run of consecutive unserved boundaries is the number that settles it.
//! One or two is the architecture: a pend raised inside a masked region or
//! under a running handler waits, and that wait is correct. Thousands is a
//! bit nobody is looking at.
pub const Standing = struct {
    /// Boundaries reached with PendSV's pend bit already up.
    boundaries: u64 = 0,
    /// Of those, the ones that actually entered the handler.
    entries: u64 = 0,
    /// Consecutive boundaries the bit has stood for without being entered.
    run: u64 = 0,
    /// The longest such run in the whole session.
    worst: u64 = 0,

    /// One chunk boundary, told whether the bit is up as the boundary opens.
    pub fn boundary(self: *Standing, pending: bool) void {
        if (!pending) {
            self.run = 0;
            return;
        }
        self.boundaries +%= 1;
        self.run +%= 1;
        if (self.run > self.worst) self.worst = self.run;
    }

    /// The handler was entered, so the bit is spent and the run is over.
    pub fn entered(self: *Standing) void {
        self.entries +%= 1;
        self.run = 0;
    }

    /// Nothing to say: no boundary ever saw the bit up.
    pub fn quiet(self: Standing) bool {
        return self.boundaries == 0;
    }

    /// Boundaries the bit stood through without the handler being entered.
    pub fn unserved(self: Standing) u64 {
        return self.boundaries -| self.entries;
    }
};
