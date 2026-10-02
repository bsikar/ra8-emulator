//! The run commands on the Zig core (RA8EMU-105). src/debug/session.zig
//! drives the Unicorn engine and is full; this is the same run, cont,
//! step, next and finish, arming the shared stop machine the same way but
//! running the core through src/debug/zig_drive.zig. Its view() hands the
//! printers and the unwinder the Zig core, so `registers`, `x`, `print`
//! and `bt` read the same as on Unicorn.
const zig_core = @import("zig_core.zig");
const zig_drive = @import("zig_drive.zig");
const core_view = @import("core_view.zig");
const stop_machine = @import("stop_machine.zig");

pub const Error = error{AlreadyRunning};

/// The commands that run the core.
pub const Command = enum { run, cont, step, next, finish };

pub const ZigSession = struct {
    core: zig_core.ZigCore,
    machine: *stop_machine.Machine,
    /// Instructions one command may run before it gives up.
    budget: u64,
    started: bool = false,

    /// Arm the machine for `command` as the Unicorn session does, then run.
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
        return zig_drive.run(self.core, self.machine, self.budget);
    }

    /// The core as the printers and the unwinder read it.
    pub fn view(self: ZigSession) core_view.View {
        return .{ .zig = self.core };
    }
};
