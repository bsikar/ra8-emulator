//! One example result and the evidence precedence used for its verdict.
const hil_conf = @import("hil_conf");
const probes = @import("probes.zig");
const std = @import("std");

pub const Verdict = enum { pass, fail, unknown };

pub const Row = struct {
    pub const max_leds = 8;
    /// On then off: the fewest edges that tell a blink from a stuck LED.
    pub const blink_edges = 2;

    console: ?[]const u8 = null,
    leds_on: [max_leds][]const u8 = undefined,
    led_count: usize = 0,
    unmodelled: ?u32 = null,
    stopped: ?[]const u8 = null,
    /// Some user LED toggled at least `blink_edges` times.
    blinking: bool = false,
    /// The memory-probe verdict for an image example_probes.zig lists, or
    /// whose hil.conf names a probe.
    probe: ?probes.Judgement = null,
    /// The verdict the example's own hil.conf gives, when it has one.
    hil: ?hil_conf.Judgement = null,

    pub fn leds(row: *const Row) []const []const u8 {
        return row.leds_on[0..row.led_count];
    }

    pub fn verdict(row: Row) Verdict {
        if (row.stopped != null) return .fail;
        if (row.probe) |judged| return switch (judged) {
            .pass => .pass,
            .fail => .fail,
            .unknown => .unknown,
        };
        if (row.hil) |judged| return switch (judged) {
            .pass => .pass,
            .fail => .fail,
        };
        const line = row.console orelse return if (row.blinking) .pass else .unknown;
        if (std.mem.indexOf(u8, line, "FAIL") != null) return .fail;
        if (std.mem.indexOf(u8, line, "OK") != null) return .pass;
        if (std.mem.indexOf(u8, line, "PASS") != null) return .pass;
        return .unknown;
    }
};
