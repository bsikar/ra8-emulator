//! A debugger session: commands applied to one core, answered in text.
//!
//! src/debug/commands.zig turns a line into a `Command`. This file carries
//! it out against an engine whose step hook feeds a stop machine, and
//! writes what happened as plain text a test can diff. The words follow
//! gdb's, but the output is this emulator's own: one line per stop, every
//! address as eight hex digits, a symbol beside it when the image has one.
//!
//! A command that cannot be carried out (a place that does not resolve, a
//! break id that does not exist) prints `error: <why>` and the session
//! carries on, so one bad line in a script does not end it.
//!
//! The session drives whatever engine it is handed through the engine
//! interface, so it runs on Unicorn now and on the Zig core once that core
//! feeds the same stop machine. The caller attaches the step hook first,
//! with memory watching on if the script sets watches.
//!
//! On a dual-core run the second CPU is parked in `other`, and `core N`
//! swaps it in. Only the selected core runs; the other holds where it
//! stopped, which is gdb's all-stop with the scheduler locked.
//!
//! The front end gives each core a run-loop session, so while debugging
//! the board still ticks and interrupts are still taken.
const std = @import("std");
const break_table = @import("break_table.zig");
const commands = @import("commands.zig");
const elf = @import("../core/elf.zig");
const engine = @import("../core/engine.zig");
const place = @import("place.zig");
const session_view = @import("session_view.zig");
const session_source = @import("session_source.zig");
const dwarf_line = @import("dwarf_line.zig");
const unwind = @import("unwind.zig");
const step_hook = @import("step_hook.zig");
const breakpoint = @import("breakpoint.zig");
const symbols = @import("symbols.zig");
const watch_table = @import("watch_table.zig");

pub const Error = error{ AlreadyRunning, NoSymbols, Unresolved, CoreNotAttached };

pub const limits = struct {
    /// Instructions one run may take before it gives up and reports where
    /// it got to. A stop that never comes must not hang a script.
    pub const default_budget: usize = 1_000_000;
    /// Bytes a watch covers: one word, the width of the variables worth
    /// watching in this firmware.
    pub const watch_bytes: u32 = 4;
};

/// Whether the session wants more commands.
pub const Outcome = enum { more, quit };

const Temporary = std.BoundedArray(break_table.Id, break_table.limits.capacity);

/// One CPU as a session drives it: its engine, the stop machine its hook
/// feeds, and where its run stands. Each core has its own breaks and
/// watches, because each has its own machine.
pub const Slot = struct {
    core: *const engine.Engine,
    driver: *step_hook.Driver,
    entry: u32,
    image: ?elf.Image = null,
    started: bool = false,
    temporary: Temporary = .{},
    loop: ?engine.Session = null,
};

/// Asked between run chunks whether the run should stop: gdb's interrupt.
pub const Poll = struct {
    context: *anyopaque,
    check: *const fn (*anyopaque) bool,
};

pub const Session = struct {
    core: *const engine.Engine,
    driver: *step_hook.Driver,
    /// Where `run` starts: the reset handler's address.
    entry: u32,
    /// The image the places' symbols come from, when there is one.
    image: ?elf.Image = null,
    budget: usize = limits.default_budget,
    started: bool = false,
    /// Whether the last run ended on a CPU fault rather than a stop.
    faulted: bool = false,
    /// Breaks set with `tbreak`, deleted when they stop the run.
    temporary: Temporary = .{},
    /// When set, runs go through the run loop with this session, so the
    /// board ticks and the NVIC dispatches at each boundary the way an
    /// ordinary run does. Null runs the bare engine.
    loop: ?engine.Session = null,
    /// Which CPU the fields above describe.
    index: u8 = 0,
    /// The other CPU, parked while this one has the session. Null on a
    /// single-core run.
    other: ?Slot = null,
    /// With a poll, a run that spends its budget keeps going, one budget
    /// at a time, until it stops, faults, or the poll says to halt. That is
    /// how gdb's `continue` runs. Without one, a spent budget ends the run.
    poll: ?Poll = null,

    /// Carry out one command and write what happened.
    pub fn apply(self: *Session, command: commands.Command, out: anytype) !Outcome {
        if (command == .quit) {
            try self.driver.machine.itm.flush(out, true);
            return .quit;
        }
        self.dispatch(command, out) catch |err| {
            try out.print("error: {s}\n", .{@errorName(err)});
        };
        return .more;
    }

    fn dispatch(self: *Session, command: commands.Command, out: anytype) !void {
        const machine = self.driver.machine;
        switch (command) {
            .brk => |at| try self.setBreak(at, false, out),
            .tbreak => |at| try self.setBreak(at, true, out),
            .delete => |id| try self.deleteBreak(id, out),
            .watch => |watch| try self.setWatch(watch, out),
            .run => {
                if (self.started) return Error.AlreadyRunning;
                machine.begin();
                try self.go(out);
            },
            .cont => {
                if (self.started) machine.proceed() else machine.begin();
                try self.go(out);
            },
            .step => {
                machine.step();
                try self.go(out);
            },
            .next => {
                machine.stepOver();
                try self.go(out);
            },
            .finish => {
                machine.stepOut(try self.core.register(.lr), try self.core.register(.sp));
                try self.go(out);
            },
            .registers => try session_view.registers(out, self.core.*),
            .line => |text| try session_source.line(out, session_source.of(self.image), try self.resolve(text)),
            .examine => |want| try session_view.words(out, self.core.*, try self.resolve(want.place), want.words),
            .print => |text| try session_view.word(out, self.core.*, text, try self.resolve(text)),
            .disassemble => |want| try self.disassemble(want, out),
            .backtrace => try self.backtrace(out),
            .list => |want| {
                const from = if (want) |text| try self.resolve(text) else if (self.started) try self.core.register(.pc) else self.entry;
                try session_source.list(out, session_source.of(self.image), std.fs.cwd(), from);
            },
            .core => |index| try self.switchTo(index, out),
            .halting => |on| try self.setHalting(on, out),
            .quit => {},
        }
    }

    /// Turn halting debug on or off for the selected core. The firmware
    /// sees it as DHCSR.C_DEBUGEN from its next instruction.
    fn setHalting(self: *Session, on: bool, out: anytype) !void {
        const machine = self.driver.machine;
        machine.halting = on;
        machine.dcb.debugen = on;
        machine.dcb.changed = true;
        if (on) return out.print("Halting debug on: debug events halt core {d}.\n", .{self.index});
        try out.print("Halting debug off: debug events on core {d} take DebugMonitor when DEMCR.MON_EN is set.\n", .{self.index});
    }

    /// Give the session to another CPU. Only the selected core runs; the
    /// other holds where it stopped until it is selected again.
    fn switchTo(self: *Session, index: u8, out: anytype) !void {
        if (index != self.index) {
            const parked = self.other orelse return Error.CoreNotAttached;
            self.other = self.park();
            self.take(parked);
            self.index = index;
        }
        try out.print("Core {d}, ", .{self.index});
        const pc = if (self.started) try self.core.register(.pc) else self.entry;
        try self.line(pc, out);
    }

    fn park(self: *const Session) Slot {
        return .{
            .core = self.core,
            .driver = self.driver,
            .entry = self.entry,
            .image = self.image,
            .started = self.started,
            .temporary = self.temporary,
            .loop = self.loop,
        };
    }

    fn take(self: *Session, slot: Slot) void {
        self.core = slot.core;
        self.driver = slot.driver;
        self.entry = slot.entry;
        self.image = slot.image;
        self.started = slot.started;
        self.temporary = slot.temporary;
        self.loop = slot.loop;
    }

    fn setBreak(self: *Session, at: commands.At, temporary: bool, out: anytype) !void {
        const address = try self.resolve(at.place) & ~@as(u32, 1);
        const id = try self.driver.machine.breaks.add(.{ .address = address, .arrival = at.arrival });
        if (temporary) try self.temporary.append(id);
        const kind = if (temporary) "Temporary breakpoint" else "Breakpoint";
        try out.print("{s} {d} at ", .{ kind, id });
        try self.where(address, out);
        if (at.arrival > 1) try out.print(", arrival {d}", .{at.arrival});
        try out.print("\n", .{});
    }

    fn deleteBreak(self: *Session, id: break_table.Id, out: anytype) !void {
        try self.driver.machine.breaks.remove(id);
        self.forgetTemporary(id);
        try out.print("Deleted breakpoint {d}\n", .{id});
    }

    fn forgetTemporary(self: *Session, id: break_table.Id) void {
        for (self.temporary.slice(), 0..) |held, index| {
            if (held != id) continue;
            _ = self.temporary.swapRemove(index);
            return;
        }
    }

    fn setWatch(self: *Session, want: commands.Watch, out: anytype) !void {
        const address = try self.resolve(want.place);
        const span = try watch_table.Watch.span(address, limits.watch_bytes, want.kind);
        const id = try self.driver.machine.watches.add(span);
        try out.print("Watchpoint {d} ({s}) at 0x{X:0>8}\n", .{ id, @tagName(want.kind), address });
    }

    /// One run under the run loop. The loop only ends early on a break it
    /// can see, so the step hook latches one when the stop machine stops.
    fn looped(self: *Session, from: u32, loop: engine.Session) !?engine.Fault {
        var latch = breakpoint.Break{ .address = 0 };
        self.driver.latch = &latch;
        defer self.driver.latch = null;
        var bounded = loop;
        bounded.brk = &latch;
        return self.core.run(from, self.budget, bounded);
    }

    /// Run from `from` for one budget, or, with a poll, budget after budget
    /// until something stops the core.
    fn runFor(self: *Session, from: u32) !?engine.Fault {
        var at = from;
        while (true) {
            const fault = if (self.loop) |loop| try self.looped(at, loop) else try self.core.runChunk(at, self.budget, null);
            if (fault != null or self.driver.last != null) return fault;
            const poll = self.poll orelse return null;
            if (poll.check(poll.context)) {
                self.driver.last = self.driver.machine.interrupt();
                return null;
            }
            at = try self.core.register(.pc);
        }
    }

    /// Run from where the session stands until the machine stops it, a
    /// fault ends it, or the budget runs out, and say which.
    fn go(self: *Session, out: anytype) !void {
        const from = if (self.started) try self.core.register(.pc) else self.entry;
        self.started = true;
        self.driver.arm();
        const fault = try self.runFor(from);
        self.faulted = fault != null;
        const pc = try self.core.register(.pc);
        try self.driver.machine.itm.flush(out, false);
        if (fault) |caught| {
            try out.print("Fault: {s} at ", .{caught.detail});
            try self.where(caught.pc, out);
            return out.print("\n", .{});
        }
        const stop = self.driver.last orelse {
            try out.print("Budget of {d} instructions spent at ", .{self.budget});
            try self.where(pc, out);
            return out.print("\n", .{});
        };
        switch (stop) {
            .stepped => {},
            .breakpoint => |id| {
                const temporary = self.isTemporary(id);
                try out.print("{s} {d}, ", .{ if (temporary) "Temporary breakpoint" else "Breakpoint", id });
                if (temporary) {
                    try self.driver.machine.breaks.remove(id);
                    self.forgetTemporary(id);
                }
            },
            .watchpoint => |hit| try out.print("Watchpoint {d}: {s} of {d} at 0x{X:0>8}, ", .{
                hit.id, @tagName(hit.access), hit.width, hit.address,
            }),
            .halt_requested => try out.print("Halted, ", .{}),
            .unit_break => |index| try out.print("Hardware breakpoint FP_COMP{d}, ", .{index}),
            .unit_watch => |index| try out.print("Hardware watchpoint DWT_COMP{d}, ", .{index}),
        }
        try self.line(pc, out);
    }

    fn isTemporary(self: *const Session, id: break_table.Id) bool {
        return std.mem.indexOfScalar(break_table.Id, self.temporary.constSlice(), id) != null;
    }

    /// An address, its symbol, and the instruction there.
    fn line(self: *Session, address: u32, out: anytype) !void {
        try self.where(address, out);
        try out.print(": ", .{});
        _ = try session_view.instruction(out, self.core.*, address);
        try out.print("\n", .{});
    }

    fn disassemble(self: *Session, want: commands.Disassemble, out: anytype) !void {
        var address = if (want.place) |text| try self.resolve(text) else try self.core.register(.pc);
        address &= ~@as(u32, 1);
        for (0..want.count) |_| {
            try self.where(address, out);
            try out.print(": ", .{});
            const width = try session_view.instruction(out, self.core.*, address);
            try out.print("\n", .{});
            address +%= width;
        }
    }

    /// The frame the program counter is in and the one the link register
    /// returns to. Walking further needs the unwind tables (RA8EMU-48).
    /// The call chain, walked with the image's .debug_frame. Without CFI
    /// for the stop it is the pc and lr, as it always was.
    fn backtrace(self: *Session, out: anytype) !void {
        var pcs: [unwind.limits.frames]u32 = undefined;
        const frame = if (self.image) |image| dwarf_line.section(image, ".debug_frame") else &.{};
        const psp = try self.core.register(.psp);
        var count = unwind.walk(frame, try unwind.registersOf(self.core.*), psp, self.core.*, &pcs);
        if (count < 2) {
            pcs[1] = try self.core.register(.lr) & ~@as(u32, 1);
            count = 2;
        }
        for (pcs[0..count], 0..) |pc, index| {
            try out.print("#{d} ", .{index});
            try self.where(pc, out);
            try out.print("\n", .{});
        }
    }

    /// An address as eight hex digits, with `<symbol+offset>` when the
    /// image has a function covering it.
    fn where(self: *const Session, address: u32, out: anytype) !void {
        try out.print("0x{X:0>8}", .{address});
        const image = self.image orelse return;
        const found = symbols.inside(image, address) orelse return;
        if (found.offset == 0) return out.print(" <{s}>", .{found.name});
        try out.print(" <{s}+{d}>", .{ found.name, found.offset });
    }

    /// The address a place names: a FILE:LINE from the line table, or its
    /// symbol or literal, one optional dereference, then its offset.
    fn resolve(self: *const Session, text: []const u8) !u32 {
        if (session_source.fileLine(text)) |at| {
            return session_source.breakAt(session_source.of(self.image), at) orelse Error.Unresolved;
        }
        const want = try place.parse(text);
        var base = want.address;
        if (want.name) |name| {
            const image = self.image orelse return Error.NoSymbols;
            base = symbols.addressOf(image, name) orelse return Error.Unresolved;
        }
        if (want.deref) base = try self.core.readWord(base);
        return want.apply(base);
    }
};
