//! The one place a debugging session decides whether to stop.
//!
//! Run, step one instruction, step over a call, step out of the current
//! function, continue, and halt on request are all the same question asked
//! before each instruction runs: does the session stop here. This file
//! answers it once, so the command layer, the GDB stub and the old one-off
//! flags all step the same way instead of each growing its own.
//!
//! It never touches the engine. Whatever drives the CPU (a Unicorn code
//! hook today, the Zig core's own loop later) hands it an `Event` before
//! each instruction and stops the CPU when it says so. Stopping before the
//! instruction leaves the program counter on it, which is what makes a
//! reported stop address the instruction that has not run yet.
//!
//! Resuming is where steppers usually go wrong. The first instruction after
//! a resume is the one the session stopped on, and it must run: a break on
//! it would stop again without moving, and a single step that counted it
//! would never leave. So the first event after every resume is let through,
//! and only then does the machine start asking.
const break_table = @import("break_table.zig");
const breakpoint = @import("breakpoint.zig");
const watch_table = @import("watch_table.zig");
const fpb = @import("fpb.zig");
const dwt = @import("dwt.zig");
const itm = @import("itm.zig");

/// What the CPU is about to execute, as the driver sees it.
pub const Event = struct {
    /// The instruction's own address.
    pc: u32,
    /// Its width in bytes, two or four on Thumb.
    size: u8,
    /// The stack pointer as it stands before the instruction runs.
    sp: u32,
    /// Whether the instruction is a call (BL, BLX). Decoding belongs to the
    /// driver, which already has the instruction in hand.
    call: bool = false,
};

/// How the session is moving, as the last command set it.
pub const Mode = enum { halted, running, step, step_over, step_out };

/// Why the session stopped. Everything above this file reports one of these.
pub const Stop = union(enum) {
    /// A single step, a step over or a step out finished.
    stepped,
    /// A break counted the arrival it was waiting for.
    breakpoint: break_table.Id,
    /// A watched range was read or written. The access has happened and
    /// the instruction that made it has retired, the way GDB reports one.
    watchpoint: watch_table.Hit,
    /// Someone asked the running session to halt.
    halt_requested,
    /// A comparator the firmware programmed into the core's own FPB
    /// matched, by index.
    unit_break: usize,
    /// A DWT comparator the firmware set to raise a debug event matched,
    /// by index. A data match is reported once its instruction retired.
    unit_watch: usize,
};

/// The point a step over or a step out is running to.
const Target = struct {
    pc: u32,
    /// The stack pointer the target must be reached at or above. A
    /// recursive call reaches the same return address on a deeper frame,
    /// with a lower stack pointer, and must not end the step.
    sp: u32,
};

pub const Machine = struct {
    breaks: break_table.Table = .{},
    watches: watch_table.Table = .{},
    /// The core's breakpoint unit, as the firmware programmed it.
    fpb: fpb.Fpb = .{},
    /// The core's DWT comparators, as the firmware programmed them.
    dwt: dwt.Dwt = .{},
    /// The core's ITM, and what the firmware printed through it.
    itm: itm.Itm = .{},
    unit_pending: ?usize = null,
    mode: Mode = .halted,
    /// Set by `resume`; cleared once the instruction resumed on has run.
    resumed: bool = false,
    halt_pending: bool = false,
    target: ?Target = null,
    /// A watch tripped during the instruction that just ran. It is reported
    /// before the next one, so the stop lands after the access, never
    /// halfway through the instruction that made it.
    watch_pending: ?watch_table.Hit = null,

    /// Run until a break or a halt request.
    pub fn proceed(self: *Machine) void {
        self.start(.running, null);
    }

    /// Run from a fresh start rather than a resume: the first instruction
    /// is checked like any other, so a break on it counts its arrival.
    pub fn begin(self: *Machine) void {
        self.start(.running, null);
        self.resumed = false;
    }

    /// Run exactly one instruction.
    pub fn step(self: *Machine) void {
        self.start(.step, null);
    }

    /// Run one instruction, or the whole call when it is one. Whether it is
    /// a call is only known from the first event, so the target is set there.
    pub fn stepOver(self: *Machine) void {
        self.start(.step_over, null);
    }

    /// Run until the current function returns to `return_address` (its lr
    /// on entry) on the frame whose stack pointer is `sp` or above.
    pub fn stepOut(self: *Machine, return_address: u32, sp: u32) void {
        self.start(.step_out, .{ .pc = clear(return_address), .sp = sp });
    }

    /// Ask a running session to stop before its next instruction.
    pub fn requestHalt(self: *Machine) void {
        if (self.mode != .halted) self.halt_pending = true;
    }

    /// Decide on the instruction about to run. A returned stop means the
    /// driver must stop the CPU now, before this instruction executes.
    pub fn onInstruction(self: *Machine, event: Event) ?Stop {
        if (self.mode == .halted) return null;
        if (self.resumed) {
            self.resumed = false;
            self.armFrom(event);
            return null;
        }
        if (self.watch_pending) |tripped| return self.halt(.{ .watchpoint = tripped });
        if (self.unit_pending) |index| return self.halt(.{ .unit_watch = index });
        if (self.halt_pending) return self.halt(.halt_requested);
        if (self.breaks.hit(event.pc)) |id| return self.halt(.{ .breakpoint = id });
        if (self.fpb.matches(event.pc)) |index| return self.halt(.{ .unit_break = index });
        if (self.dwt.matchesPc(event.pc)) |index| return self.halt(.{ .unit_watch = index });
        return switch (self.mode) {
            .halted, .running => null,
            .step => self.halt(.stepped),
            .step_over, .step_out => if (self.reached(event)) self.halt(.stepped) else null,
        };
    }

    /// Hand the machine a bus access made by the instruction now running.
    /// The stop it may cause is reported on the next `onInstruction`.
    pub fn onAccess(self: *Machine, address: u32, width: u8, access: watch_table.Access) void {
        if (self.mode == .halted) return;
        if (self.dwt.access(address, width, access)) |index| {
            if (self.unit_pending == null) self.unit_pending = index;
        }
        if (self.watch_pending != null) return;
        self.watch_pending = self.watches.hit(address, width, access);
    }

    fn start(self: *Machine, mode: Mode, target: ?Target) void {
        self.mode = mode;
        self.resumed = true;
        self.halt_pending = false;
        self.watch_pending = null;
        self.unit_pending = null;
        self.target = target;
    }

    /// A step over of a call runs to the instruction after it; a step over
    /// of anything else is a single step.
    fn armFrom(self: *Machine, event: Event) void {
        if (self.mode != .step_over) return;
        if (event.call) {
            self.target = .{ .pc = clear(event.pc) + event.size, .sp = event.sp };
        } else {
            self.mode = .step;
        }
    }

    fn reached(self: *const Machine, event: Event) bool {
        const target = self.target orelse return true;
        return clear(event.pc) == target.pc and event.sp >= target.sp;
    }

    fn halt(self: *Machine, why: Stop) Stop {
        self.mode = .halted;
        self.halt_pending = false;
        self.watch_pending = null;
        self.unit_pending = null;
        self.target = null;
        return why;
    }
};

fn clear(address: u32) u32 {
    return address & ~breakpoint.limits.thumb_bit;
}
