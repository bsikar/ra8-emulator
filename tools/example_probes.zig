//! Memory-probe verdicts for examples with no console (RA8EMU-37).
//!
//! The dual-core ping-pongs print nothing: on the bench, HIL reads a match
//! counter and a mismatch counter over J-Link (each example's hil.conf names
//! them as HIL_PROBE_SYMBOL and HIL_PROBE_FAILURE_SYMBOL). The table asks the
//! emulator for the same two words with --dump-sym and judges the row on them.
//!
//! The bench's HIL_PROBE_MIN_ADVANCE is a count over a five-second window at
//! full speed (500 for the IPC ping-pong). The emulator's default budget is a
//! few milliseconds of target time, so `min` here is a total: enough
//! round-trips that the loop is clearly running, not a rate.
const std = @import("std");

pub const Probe = struct {
    image: []const u8,
    symbol: []const u8,
    min: u32,
    /// Null when the bench checks only the match counter.
    failure: ?[]const u8 = null,
    max_failure: u32 = 0,
};

pub const probes = [_]Probe{
    .{ .image = "cpu1_pingpong.elf", .symbol = "g_cpu1_pingpong_match", .min = 5, .failure = "g_cpu1_pingpong_mismatch" },
    .{ .image = "cpu1_pingpong_ipc.elf", .symbol = "g_ns_pingpong_match", .min = 5, .failure = "g_ns_pingpong_mismatch" },
    // The README's bench verdict: the Non-Secure heartbeat advances and the
    // secure side never records a denied handover. The heartbeat lives in
    // the _ns image; --dump-sym looks there when the secure image lacks it.
    .{ .image = "secure_boot_ns_hil.elf", .symbol = "g_sbns_ns_alive", .min = 5, .failure = "g_sbns_denied" },
    // No console and no hil.conf: its NSC log veneer only copies into a
    // secure scratch buffer. The README's verdict is that the Non-Secure
    // ThreadX kernel runs and the secure fallback main is never reached, so
    // the tick count in the _ns image is the heartbeat (RA8EMU-287).
    // hil.conf's probe: the NS USB host's verified bulk-echo rounds, and the
    // NSC CGC veneers never returning non-OK (RA8EMU-289). Both words live
    // in the _ns image.
    .{ .image = "tz_nsc_cgc_usb.elf", .symbol = "g_tz_usb_host_rounds_ok", .min = 50, .failure = "g_tz_nsc_cgc_usb_mismatch" },
    .{ .image = "tz_threadx_demo.elf", .symbol = "_tx_timer_system_clock", .min = 5, .failure = "g_tz_threadx_demo_fallback_count" },
};

pub const Judgement = enum { pass, fail, unknown };

/// The probe hil.conf names for an image the list above leaves out: the
/// bench's HIL_PROBE_MIN_ADVANCE is taken as a total, like `min` above,
/// because the counters start at zero (RA8EMU-400).
pub fn fromConf(image: []const u8, symbol: ?[]const u8, min: ?u32, failure: ?[]const u8, max_failure: ?u32) ?Probe {
    return .{
        .image = image,
        .symbol = symbol orelse return null,
        .min = @max(min orelse 1, 1),
        .failure = failure,
        .max_failure = max_failure orelse 0,
    };
}

pub fn find(image: []const u8) ?Probe {
    for (probes) |entry| {
        if (std.mem.eql(u8, entry.image, image)) return entry;
    }
    return null;
}

/// The value the report printed for `name` on a "dump-sym" line, or null
/// when the line is missing, unresolved or unreadable.
pub fn dumped(report: []const u8, name: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, report, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimLeft(u8, raw, " ");
        if (!std.mem.startsWith(u8, line, "dump-sym")) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const rest = std.mem.trimLeft(u8, line[colon + 1 ..], " ");
        if (!std.mem.startsWith(u8, rest, name) or rest.len == name.len or rest[name.len] != ' ') continue;
        const equals = std.mem.indexOf(u8, rest, " = ") orelse return null;
        const digits = rest[equals + 3 ..];
        const end = std.mem.indexOfScalar(u8, digits, ' ') orelse digits.len;
        return std.fmt.parseInt(u32, digits[0..end], 10) catch null;
    }
    return null;
}

/// Pass when the match counter reached `min` and the failure counter stayed
/// at or under its ceiling; fail when either is out; unknown when the report
/// does not carry both words.
pub fn judge(probe: Probe, report: []const u8) Judgement {
    const matched = dumped(report, probe.symbol) orelse return .unknown;
    const failed = if (probe.failure) |name| dumped(report, name) orelse return .unknown else 0;
    if (failed > probe.max_failure) return .fail;
    return if (matched >= probe.min) .pass else .fail;
}
