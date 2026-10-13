//! Reachable input-script ordering and arithmetic required by dispatch.
const std = @import("std");
const Script = @import("ra8_components").input_script.Script;
const frame_ns: u64 = 50_000_000;
pub fn valid(script: Script, board_ns: u64) bool {
    if (script.len > script.events.len or script.cursor > script.len or script.now_ns > board_ns) return false;
    var previous: u64 = 0;
    for (script.events[0..script.len], 0..) |timed, index| {
        if (index != 0 and timed.at_ns < previous) return false;
        if (index < script.cursor and timed.at_ns > script.now_ns) return false;
        previous = timed.at_ns;
        switch (timed.event) {
            .swipe => |s| if (!gesture(timed.at_ns, s.duration_ns, s.from, s.to)) return false,
            .longpress => |p| if (!timeFits(timed.at_ns, p.duration_ns)) return false,
            .button => |b| if (b.down and timed.at_ns > std.math.maxInt(u64) - 100_000_000) return false,
            .tap => {},
        }
    }
    if (script.previous_at != previous) return false;
    if (script.button_release) |release| if (release.at_ns < 100_000_000) return false;
    if (script.active) |active| switch (active) {
        .swipe => |s| {
            if (!gesture(s.start, s.duration, s.from, s.to) or !phase(s.start, s.next, script.now_ns)) return false;
        },
        .longpress => |p| {
            if (!timeFits(p.start, p.duration) or !phase(p.start, p.next, script.now_ns)) return false;
        },
    };
    return true;
}
fn timeFits(start: u64, duration: u64) bool {
    return start <= std.math.maxInt(u64) - frame_ns and duration <= std.math.maxInt(u64) - start - frame_ns;
}
fn phase(start: u64, next: u64, now: u64) bool {
    return start <= now and next >= start + frame_ns and (next - start) % frame_ns == 0 and next <= std.math.maxInt(u64) - frame_ns;
}
fn gesture(start: u64, duration: u64, from: anytype, to: anytype) bool {
    const dx = @abs(@as(i64, to.x) - from.x);
    const dy = @abs(@as(i64, to.y) - from.y);
    const factor = @max(1, @max(dx, dy));
    return timeFits(start, duration) and duration <= @as(u64, std.math.maxInt(i64)) / factor;
}
