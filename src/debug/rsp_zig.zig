//! The remote protocol's run control and threads on the Zig core
//! (RA8EMU-118), the counterpart of rsp_run.zig for the Unicorn session.
//!
//! The Zig core debugs one core, so there is one thread. `c` runs budget
//! after budget, asking the poll between them whether gdb sent an
//! interrupt, and `s` runs one instruction. The stop replies are the same
//! as rsp_run.zig's: `T05` for a break or a step, `T05watch:` and friends
//! for a watch, `T02` for an interrupt and `T0b` when the core faulted.
const std = @import("std");
const debug_session = @import("session.zig");
const watch_table = @import("watch_table.zig");
const zig_drive = @import("zig_drive.zig");
const zig_session = @import("zig_session.zig");

pub const Error = error{NoSpace};

const request_error = "E00";
const vcont_actions = "vCont;c;C;s;S";
const sigint: u8 = 0x02;
const sigtrap: u8 = 0x05;
const sigsegv: u8 = 0x0b;

/// The Zig session gdb drives, with why it last stopped.
pub const Target = struct {
    session: *zig_session.ZigSession,
    /// Asked between budgets while a continue runs; null runs one budget.
    poll: ?debug_session.Poll = null,
    last: ?zig_drive.Ended = null,
};

/// The reply to a run-control or thread request (rsp_run.handles says which).
pub fn answer(target: *Target, request: []const u8, out: []u8) Error![]const u8 {
    if (std.mem.eql(u8, request, "vCont?")) return copy(out, vcont_actions);
    if (std.mem.startsWith(u8, request, "vCont;")) return vcont(target, request["vCont;".len..], out);
    if (std.mem.eql(u8, request, "qfThreadInfo")) return copy(out, "m1");
    if (std.mem.eql(u8, request, "qsThreadInfo")) return copy(out, "l");
    if (std.mem.eql(u8, request, "qC")) return copy(out, "QC1");
    return switch (request[0]) {
        'c' => resume_(target, .cont, out),
        's' => resume_(target, .step, out),
        '?' => stopReply(target, out),
        'H' => copy(out, if (request.len > 1 and alive(request[2..])) "OK" else request_error),
        'T' => copy(out, if (alive(request[1..])) "OK" else request_error),
        else => out[0..0],
    };
}

/// Only the first action matters: there is one thread.
fn vcont(target: *Target, actions: []const u8, out: []u8) Error![]const u8 {
    const first = actions[0 .. std.mem.indexOfScalar(u8, actions, ';') orelse actions.len];
    if (first.len == 0) return copy(out, request_error);
    if (std.mem.indexOfScalar(u8, first, ':')) |colon| {
        if (!alive(first[colon + 1 ..])) return copy(out, request_error);
    }
    return switch (first[0]) {
        'c', 'C' => resume_(target, .cont, out),
        's', 'S' => resume_(target, .step, out),
        else => copy(out, request_error),
    };
}

fn resume_(target: *Target, command: zig_session.Command, out: []u8) Error![]const u8 {
    var ended = target.session.go(command) catch return copy(out, request_error);
    while (command == .cont and ended == .count) {
        const poll = target.poll orelse break;
        if (poll.check(poll.context)) {
            ended = .{ .stop = target.session.machine.interrupt() };
            break;
        }
        ended = target.session.go(.cont) catch return copy(out, request_error);
    }
    target.last = ended;
    return stopReply(target, out);
}

/// Why the core last stopped, as gdb reads it.
fn stopReply(target: *Target, out: []u8) Error![]const u8 {
    const ended = target.last orelse return reply(out, sigtrap);
    return switch (ended) {
        .count => reply(out, sigtrap),
        .core => reply(out, sigsegv),
        .stop => |stop| switch (stop) {
            .watchpoint => |hit| print(out, "T{x:0>2}{s}:{x:0>8};thread:1;", .{
                sigtrap, watchName(target, hit), hit.address,
            }),
            .halt_requested => reply(out, sigint),
            else => reply(out, sigtrap),
        },
    };
}

/// gdb names a watch by what it was set to catch, so the kind comes from
/// the table when the watch is still there.
fn watchName(target: *Target, hit: watch_table.Hit) []const u8 {
    const kind = if (target.session.machine.watches.get(hit.id)) |watch| watch.kind else switch (hit.access) {
        .read => watch_table.Kind.read,
        .write => watch_table.Kind.write,
    };
    return switch (kind) {
        .write => "watch",
        .read => "rwatch",
        .access => "awatch",
    };
}

/// Thread `0` and `-1` mean any thread; the only thread is `1`.
fn alive(text: []const u8) bool {
    if (std.mem.eql(u8, text, "0") or std.mem.eql(u8, text, "-1")) return true;
    return (std.fmt.parseInt(u32, text, 16) catch return false) == 1;
}

fn reply(out: []u8, signal: u8) Error![]const u8 {
    return print(out, "T{x:0>2}thread:1;", .{signal});
}

fn print(out: []u8, comptime format: []const u8, args: anytype) Error![]const u8 {
    return std.fmt.bufPrint(out, format, args) catch Error.NoSpace;
}

fn copy(out: []u8, text: []const u8) Error![]const u8 {
    if (text.len > out.len) return Error.NoSpace;
    @memcpy(out[0..text.len], text);
    return out[0..text.len];
}
