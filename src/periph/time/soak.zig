//! What ends a soak run before its duration (RA8EMU-186, slice 2).
//!
//! `--run-for` arms it. A watchdog reset while armed is the soak's first
//! event: the run ends at the boundary that asked for it, before the reboot,
//! so the report says when the firmware stopped feeding the dog rather than
//! carrying on into a second boot. The first event is the one kept; whatever
//! follows from it is not news. Faults join in a later slice.
const std = @import("std");
const timebase = @import("timebase.zig");

pub const Kind = enum {
    watchdog_reset,
    iwdt_reset,

    pub fn text(self: Kind) []const u8 {
        return switch (self) {
            .watchdog_reset => "watchdog reset (WDT)",
            .iwdt_reset => "watchdog reset (IWDT)",
        };
    }
};

pub const Event = struct {
    kind: Kind,
    /// Virtual nanoseconds since reset when it happened.
    at_ns: u64,
};

pub const Soak = struct {
    armed: bool = false,
    event: ?Event = null,

    /// Keep the first event of an armed run; anything else is ignored.
    pub fn note(self: *Soak, kind: Kind, at_ns: u64) void {
        if (!self.armed or self.event != null) return;
        self.event = .{ .kind = kind, .at_ns = at_ns };
    }

    /// Has an event ended the run?
    pub fn ended(self: *const Soak) bool {
        return self.event != null;
    }

    /// The soak line: nothing for a run without --run-for.
    pub fn line(self: *const Soak, out: anytype) !void {
        if (!self.armed) return;
        const event = self.event orelse return out.print("soak: no events\n", .{});
        const s = event.at_ns / timebase.ns_per_s;
        const ns = event.at_ns % timebase.ns_per_s;
        try out.print("soak: stopped on {s} at {d}.{d:0>9} s virtual\n", .{ event.kind.text(), s, ns });
    }
};
