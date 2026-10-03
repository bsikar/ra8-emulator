//! `--trace-rtos` on a Unicorn run (RA8EMU-221).
//!
//! src/debug/rtos_trace.zig turns stores to ThreadX's current-thread
//! pointer into switch events and knows nothing about Unicorn. This file is
//! the other half: it finds `_tx_thread_current_ptr` in the image, asks to
//! be called for writes to that word and nowhere else, stamps each one with
//! the run's own period counter, and prints the trace once the run is over.
//!
//! Each switch is printed with the thread's name, read from its TX_THREAD
//! once the run is over (src/debug/rtos_names.zig, RA8EMU-223).
//!
//! Exception entry and return are traced with them (src/debug/rtos_isr.zig,
//! RA8EMU-224): before each instruction the NVIC model's counters are read.
//! That costs a call per instruction, so it is only hooked with the flag.
//!
//! A `--cpu zig` run is traced through src/debug/rtos_zig.zig instead, and
//! CPU1 through src/debug/rtos_second.zig.
//! Only CPU0 on Unicorn is hooked here. CPU1 and the Zig core are their own
//! tickets under RA8EMU-211.
const std = @import("std");
const c = @import("../core/c.zig");
const elf = @import("../core/elf.zig");
const symbols = @import("symbols.zig");
const rtos_trace = @import("rtos_trace.zig");
const clocks = @import("../periph/clocks.zig");
pub const names = @import("rtos_names.zig");
pub const isr = @import("rtos_isr.zig");
pub const zig = @import("rtos_zig.zig");
pub const second = @import("rtos_second.zig");
pub const load = @import("rtos_load.zig");
pub const report = @import("rtos_report.zig");
/// `--trace-rtos-out FILE`: the trace as a file, and its reader (RA8EMU-345).
pub const file = @import("rtos_file.zig");

/// The word ThreadX keeps the running thread's control block in.
pub const symbol = "_tx_thread_current_ptr";

pub const Error = error{AttachFailed};

/// The pointer's address, the trace it feeds, and the clock it stamps from.
pub const Tracer = struct {
    address: u32,
    trace: rtos_trace.Trace = .{},
    /// The run's period counter, borrowed so a stamp is read as the store
    /// lands. Null stamps zero, which is every unit test.
    now: ?*const u64 = null,
    core: u1 = 0,
    /// Exception entry and return, when a controller was handed over.
    exceptions: ?isr.Watcher = null,
    /// Instructions seen by the per-instruction hook: the load clock on an
    /// engine that has one (Unicorn), lent to the trace by `attach`.
    steps: u64 = 0,
    /// The run's virtual-instruction count, which also moves through
    /// stretches the idle skip charges without executing (src/core/idle.zig).
    /// Null keeps the load clock on `steps`.
    elapsed: ?*const u64 = null,
    /// `elapsed` when the current chunk began, and instructions hooked since.
    base: u64 = 0,
    offset: u64 = 0,
    /// The load clock lent to the trace: virtual time, per instruction.
    clock: u64 = 0,

    /// One store that touched the pointer's word. Only a full word written
    /// to the word itself names a thread; a narrower store is a partial
    /// update no scheduler makes, and is not taken for a switch.
    pub fn onStore(self: *Tracer, address: u32, width: u8, value: u32) void {
        if (address != self.address or width != 4) return;
        self.trace.store(self.core, self.stamp(), value);
    }

    /// Before each instruction: anything entered or returned from since.
    pub fn onInstruction(self: *Tracer) void {
        self.steps += 1;
        self.advanceClock();
        if (self.exceptions) |*watcher| watcher.observe(&self.trace, self.core, self.stamp());
    }

    /// A new chunk shows as `elapsed` moving: what it charged, executed or
    /// skipped, is already in it, so the clock restarts from there.
    fn advanceClock(self: *Tracer) void {
        const now = self.elapsed orelse {
            self.clock = self.steps;
            return;
        };
        if (now.* != self.base) {
            self.base = now.*;
            self.offset = 0;
        }
        self.offset += 1;
        self.clock = @max(self.clock, self.base + self.offset);
    }

    /// The load clock as the run ends: a last stretch the idle skip charged
    /// has no instruction after it to move the clock.
    pub fn loadClock(self: *const Tracer) u64 {
        const fine = self.trace.loadNow(self.stamp());
        const now = self.elapsed orelse return fine;
        return @max(fine, now.*);
    }

    /// The run's clock now, or zero with none borrowed.
    pub fn stamp(self: *const Tracer) u64 {
        return if (self.now) |clock| clock.* else 0;
    }
};

/// Where the pointer is, when the flag asked for a trace. An image without
/// ThreadX is reported and traced as nothing.
pub fn resolve(image: elf.Image, wanted: ?load.Window) ?Tracer {
    return resolveOn(image, wanted, 0);
}

/// As `resolve`, for the image one core runs; CPU1's miss says whose it is.
/// `wanted` is the load window, null when no flag asked for a trace.
pub fn resolveOn(image: elf.Image, wanted: ?load.Window, core: u1) ?Tracer {
    const window = wanted orelse return null;
    const at = symbols.addressOf(image, symbol) orelse {
        const whose = if (core == 1) "cpu1 image has " else "";
        std.debug.print("--trace-rtos: {s}no symbol named {s}\n", .{ whose, symbol });
        return null;
    };
    var found: Tracer = .{ .address = at, .core = core };
    found.trace.load.from = window.from;
    found.trace.load.to = window.to;
    return found;
}

/// Resolve and hook. The tracer has to outlive the engine, which keeps its
/// pointer for every later run, so it is allocated here and left for the
/// process to reclaim; a run attaches at most one.
pub fn arm(
    handle: ?*c.uc.uc_engine,
    image: elf.Image,
    wanted: ?load.Window,
    timebase: *const clocks.Clocks,
    controller: *const isr.Nvic,
) Error!?*Tracer {
    const found = resolve(image, wanted) orelse return null;
    const owned = try attach(handle, found, &timebase.ticks, controller);
    owned.elapsed = &timebase.elapsed;
    return owned;
}

/// Hook a resolved tracer onto one core's engine, stamped from that core's
/// clock and watching that core's NVIC.
pub fn attach(
    handle: ?*c.uc.uc_engine,
    found: Tracer,
    clock: *const u64,
    controller: *const isr.Nvic,
) Error!*Tracer {
    const owned = std.heap.page_allocator.create(Tracer) catch return Error.AttachFailed;
    owned.* = found;
    owned.trace.fine = &owned.clock;
    owned.now = clock;
    owned.exceptions = isr.Watcher.start(controller);
    var hook: c.uc.uc_hook = 0;
    if (c.uc.uc_hook_add(
        handle,
        &hook,
        c.uc.UC_HOOK_MEM_WRITE,
        @constCast(@as(*const anyopaque, @ptrCast(&onWrite))),
        owned,
        found.address,
        found.address + 3,
    ) != c.uc.UC_ERR_OK) {
        std.heap.page_allocator.destroy(owned);
        return Error.AttachFailed;
    }
    var every: c.uc.uc_hook = 0;
    const code = @constCast(@as(*const anyopaque, @ptrCast(&onCode)));
    if (c.uc.uc_hook_add(handle, &every, c.uc.UC_HOOK_CODE, code, owned, 1, 0) != c.uc.UC_ERR_OK) {
        return Error.AttachFailed;
    }
    return owned;
}

fn onCode(uc: ?*c.uc.uc_engine, address: u64, size: u32, user: ?*anyopaque) callconv(.C) void {
    _ = uc;
    _ = address;
    _ = size;
    const owned: *Tracer = @ptrCast(@alignCast(user orelse return));
    owned.onInstruction();
}

fn onWrite(
    uc: ?*c.uc.uc_engine,
    kind: c_int,
    address: u64,
    size: c_int,
    value: i64,
    user: ?*anyopaque,
) callconv(.C) void {
    _ = uc;
    _ = kind;
    const owned: *Tracer = @ptrCast(@alignCast(user orelse return));
    owned.onStore(@truncate(address), @intCast(size), @truncate(@as(u64, @bitCast(value))));
}

/// Target memory read through a Unicorn engine, for the thread names.
pub const Memory = struct {
    handle: ?*c.uc.uc_engine,

    pub fn read(self: Memory, address: u32, into: []u8) bool {
        return c.uc.uc_mem_read(self.handle, address, into.ptr, into.len) == c.uc.UC_ERR_OK;
    }
};

/// The switches the run made, oldest first, each thread named through
/// `memory` where its control block says. Nothing when no trace was asked
/// for; a header with a count of zero when ThreadX never switched, because
/// that is an answer too.
pub fn print(out: anytype, tracer: ?*const Tracer, memory: anytype) !void {
    const one = tracer orelse return;
    const events = one.trace.list();
    try out.print(
        "  {s}: {s} @0x{X:0>8}, {d} event(s)\n",
        .{ if (one.core == 1) "rtos cpu1     " else "rtos trace    ", symbol, one.address, events.len + one.trace.dropped },
    );
    for (events) |event| try line(out, event, memory);
    if (one.trace.dropped > 0) {
        try out.print("                  and {d} more, not kept\n", .{one.trace.dropped});
    }
}

fn line(out: anytype, event: rtos_trace.Event, memory: anytype) !void {
    try out.print("                  tick {d} cpu{d} ", .{ event.when, event.core });
    switch (event.kind) {
        .idle => try out.print("idle\n", .{}),
        .enter, .leave => try exceptionLine(out, event),
        .switch_to => {
            try out.print("-> 0x{X:0>8}", .{event.thread});
            var buffer: [names.longest]u8 = undefined;
            if (names.name(memory, event.thread, &buffer)) |text| try out.print(" {s}", .{text});
            try out.print("\n", .{});
        },
    }
}

fn exceptionLine(out: anytype, event: rtos_trace.Event) !void {
    const verb = if (event.kind == .enter) "enter" else "leave";
    if (isr.label(event.exception)) |text| return out.print("{s} {s}\n", .{ verb, text });
    if (event.exception >= 16) return out.print("{s} IRQ{d}\n", .{ verb, event.exception - 16 });
    try out.print("{s} exception {d}\n", .{ verb, event.exception });
}
