//! The run commands on the Zig core (RA8EMU-105). This is run, cont,
//! step, next and finish, arming the shared stop machine but
//! running the core through src/debug/zig_drive.zig. Its view() hands the
//! printers and the unwinder the Zig core, so `registers`, `x`, `print`
//! and `bt` read the core.
//!
//! With CPU1 attached (RA8EMU-337) the other core is parked in `other`,
//! and switchTo swaps it in. As in session.zig, only the selected core
//! runs; the other holds where it stopped: gdb's all-stop with the
//! scheduler locked.
const zig_core = @import("zig_core.zig");
const zig_cycles = @import("zig_cycles.zig");
const zig_drive = @import("zig_drive.zig");
const core_view = @import("core_view.zig");
const stop_machine = @import("stop_machine.zig");
const watch_bus = @import("watch_bus.zig");

pub const Error = error{ AlreadyRunning, CoreNotAttached };

/// The commands that run the core.
pub const Command = enum { run, cont, step, next, finish };

/// One core's half of the session, held while the other core has it.
pub const Slot = struct {
    core: zig_core.ZigCore,
    machine: *stop_machine.Machine,
    started: bool = false,
    watch: ?*watch_bus.WatchBus = null,
    clock: zig_cycles.Clock = .{},
    index: u8 = 1,
    budget: u64 = 1_000_000,
};

pub const ZigSession = struct {
    core: zig_core.ZigCore,
    machine: *stop_machine.Machine,
    /// Instructions one command may run before it gives up.
    budget: u64,
    started: bool = false,
    /// The core's bus with the debugger listening, so watches and DWT data
    /// matches see its accesses. Null runs without them.
    watch: ?*watch_bus.WatchBus = null,
    /// DWT_CYCCNT and DFSR as the debugger reads them.
    clock: zig_cycles.Clock = .{},
    /// Which CPU the fields above describe.
    index: u8 = 0,
    /// The other CPU, parked while this one has the session. Null on a
    /// single-core session.
    other: ?Slot = null,

    /// Give the session to CPU `index`. The core left behind holds where
    /// it stopped, with its own breaks, watches and clock.
    pub fn switchTo(self: *ZigSession, index: u8) Error!void {
        if (index == self.index) return;
        const parked = self.other orelse return Error.CoreNotAttached;
        self.other = .{ .core = self.core, .machine = self.machine, .started = self.started, .watch = self.watch, .clock = self.clock, .index = self.index, .budget = self.budget };
        self.core = parked.core;
        self.machine = parked.machine;
        self.started = parked.started;
        self.watch = parked.watch;
        self.clock = parked.clock;
        self.index = parked.index;
        self.budget = parked.budget;
    }

    /// Arm the machine for `command`, then run.
    pub fn go(self: *ZigSession, command: Command) Error!zig_drive.Ended {
        switch (command) {
            .run => {
                if (self.started) return Error.AlreadyRunning;
                self.machine.begin();
            },
            .cont => if (self.started) self.machine.proceed() else self.machine.begin(),
            .step => self.machine.step(),
            .next => self.machine.stepOver(),
            .finish => self.machine.stepOut(self.core.register(.lr), self.core.register(.sp)),
        }
        self.started = true;
        return zig_drive.runClocked(self.core, self.machine, self.budget, self.watch, &self.clock);
    }

    /// The core as the printers and the unwinder read it.
    pub fn view(self: ZigSession) core_view.View {
        return .{ .zig = self.core };
    }
};
