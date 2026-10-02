//! `--trace-rtos` on a Unicorn run (RA8EMU-221).
//!
//! src/debug/rtos_trace.zig turns stores to ThreadX's current-thread
//! pointer into switch events and knows nothing about Unicorn. This file is
//! the other half: it finds `_tx_thread_current_ptr` in the image, asks to
//! be called for writes to that word and nowhere else, stamps each one with
//! the run's own period counter, and prints the trace once the run is over.
//!
//! Only CPU0 on Unicorn is hooked here. CPU1 and the Zig core are their own
//! tickets under RA8EMU-211.
const std = @import("std");
const c = @import("../core/c.zig");
const elf = @import("../core/elf.zig");
const symbols = @import("symbols.zig");
const rtos_trace = @import("rtos_trace.zig");

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

    /// One store that touched the pointer's word. Only a full word written
    /// to the word itself names a thread; a narrower store is a partial
    /// update no scheduler makes, and is not taken for a switch.
    pub fn onStore(self: *Tracer, address: u32, width: u8, value: u32) void {
        if (address != self.address or width != 4) return;
        self.trace.store(self.core, if (self.now) |clock| clock.* else 0, value);
    }
};

/// Where the pointer is, when the flag asked for a trace. An image without
/// ThreadX is reported and traced as nothing.
pub fn resolve(image: elf.Image, wanted: bool) ?Tracer {
    if (!wanted) return null;
    const at = symbols.addressOf(image, symbol) orelse {
        std.debug.print("--trace-rtos: no symbol named {s}\n", .{symbol});
        return null;
    };
    return .{ .address = at };
}

/// Resolve and hook. The tracer has to outlive the engine, which keeps its
/// pointer for every later run, so it is allocated here and left for the
/// process to reclaim; a run attaches at most one.
pub fn arm(handle: ?*c.uc.uc_engine, image: elf.Image, wanted: bool, clock: *const u64) Error!?*Tracer {
    const found = resolve(image, wanted) orelse return null;
    const owned = std.heap.page_allocator.create(Tracer) catch return Error.AttachFailed;
    owned.* = found;
    owned.now = clock;
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
    return owned;
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

/// The switches the run made, oldest first. Nothing when no trace was asked
/// for; a header with a count of zero when ThreadX never switched, because
/// that is an answer too.
pub fn print(out: anytype, tracer: ?*const Tracer) !void {
    const one = tracer orelse return;
    const events = one.trace.list();
    try out.print(
        "  rtos trace    : {s} @0x{X:0>8}, {d} switch(es)\n",
        .{ symbol, one.address, events.len + one.trace.dropped },
    );
    for (events) |event| try line(out, event);
    if (one.trace.dropped > 0) {
        try out.print("                  and {d} more, not kept\n", .{one.trace.dropped});
    }
}

fn line(out: anytype, event: rtos_trace.Event) !void {
    try out.print("                  tick {d} cpu{d} ", .{ event.when, event.core });
    switch (event.kind) {
        .idle => try out.print("idle\n", .{}),
        .switch_to => try out.print("-> 0x{X:0>8}\n", .{event.thread}),
    }
}
