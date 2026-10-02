//! The remote protocol's run control and threads, answered against the
//! debugger session so gdb resumes exactly the way a script does.
//!
//! `c`, `s` and `vCont` resume the selected core and answer with a stop
//! reply: `T05` for a break or a finished step, `T05watch:`, `rwatch:` or
//! `awatch:` with the address for a watch, `T0b` (SIGSEGV) for a fault.
//! Each core is a thread, numbered from one; `Hg`/`Hc` and a thread in a
//! `vCont` action select it.
const std = @import("std");
const debug_session = @import("session.zig");
const watch_table = @import("watch_table.zig");

pub const Error = error{NoSpace};

const request_error = "E00";
const vcont_actions = "vCont;c;C;s;S";
const sigtrap: u8 = 0x05;
const sigsegv: u8 = 0x0b;

/// Whether `request` is one this file answers.
pub fn handles(request: []const u8) bool {
    if (request.len == 0) return false;
    if (std.mem.startsWith(u8, request, "vCont")) return true;
    if (std.mem.eql(u8, request, "qfThreadInfo") or std.mem.eql(u8, request, "qsThreadInfo")) return true;
    if (std.mem.eql(u8, request, "qC")) return true;
    return switch (request[0]) {
        'c', 's', '?', 'H', 'T' => true,
        else => false,
    };
}

/// The reply to a run-control or thread request.
pub fn answer(session: *debug_session.Session, request: []const u8, out: []u8) Error![]const u8 {
    if (std.mem.eql(u8, request, "vCont?")) return copy(out, vcont_actions);
    if (std.mem.startsWith(u8, request, "vCont;")) return vcont(session, request["vCont;".len..], out);
    if (std.mem.eql(u8, request, "qfThreadInfo")) return copy(out, if (session.other == null) "m1" else "m1,2");
    if (std.mem.eql(u8, request, "qsThreadInfo")) return copy(out, "l");
    if (std.mem.eql(u8, request, "qC")) return print(out, "QC{x}", .{thread(session)});
    return switch (request[0]) {
        'c' => resume_(session, .cont, out),
        's' => resume_(session, .step, out),
        '?' => stopReply(session, out),
        'H' => if (request.len > 1 and select(session, request[2..])) copy(out, "OK") else copy(out, request_error),
        'T' => copy(out, if (alive(session, request[1..])) "OK" else request_error),
        else => out[0..0],
    };
}

/// The first action applies to the thread it names, or the selected one.
/// Both cores never run at once under the debugger, so later actions
/// (gdb's "and everyone else continue") have nothing more to do.
fn vcont(session: *debug_session.Session, actions: []const u8, out: []u8) Error![]const u8 {
    const first = actions[0 .. std.mem.indexOfScalar(u8, actions, ';') orelse actions.len];
    if (first.len == 0) return copy(out, request_error);
    if (std.mem.indexOfScalar(u8, first, ':')) |colon| {
        if (!select(session, first[colon + 1 ..])) return copy(out, request_error);
    }
    return switch (first[0]) {
        'c', 'C' => resume_(session, .cont, out),
        's', 'S' => resume_(session, .step, out),
        else => copy(out, request_error),
    };
}

fn resume_(session: *debug_session.Session, command: @import("commands.zig").Command, out: []u8) Error![]const u8 {
    _ = session.apply(command, std.io.null_writer) catch return copy(out, request_error);
    return stopReply(session, out);
}

/// Why the selected core last stopped, as gdb reads it.
fn stopReply(session: *debug_session.Session, out: []u8) Error![]const u8 {
    if (session.faulted) return print(out, "T{x:0>2}thread:{x};", .{ sigsegv, thread(session) });
    const stop = session.driver.last orelse return print(out, "T{x:0>2}thread:{x};", .{ sigtrap, thread(session) });
    return switch (stop) {
        .watchpoint => |hit| print(out, "T{x:0>2}{s}:{x:0>8};thread:{x};", .{
            sigtrap, watchName(session, hit), hit.address, thread(session),
        }),
        else => print(out, "T{x:0>2}thread:{x};", .{ sigtrap, thread(session) }),
    };
}

/// gdb names a watch by what it was set to catch, not by what the access
/// happened to be, so the kind comes from the table.
fn watchName(session: *debug_session.Session, hit: watch_table.Hit) []const u8 {
    const kind = if (session.driver.machine.watches.get(hit.id)) |watch| watch.kind else switch (hit.access) {
        .read => watch_table.Kind.read,
        .write => watch_table.Kind.write,
    };
    return switch (kind) {
        .write => "watch",
        .read => "rwatch",
        .access => "awatch",
    };
}

fn thread(session: *const debug_session.Session) u32 {
    return @as(u32, session.index) + 1;
}

/// Thread `0` and `-1` mean any thread, which is the selected one.
fn select(session: *debug_session.Session, text: []const u8) bool {
    if (std.mem.eql(u8, text, "0") or std.mem.eql(u8, text, "-1")) return true;
    if (!alive(session, text)) return false;
    const index: u8 = @intCast((std.fmt.parseInt(u32, text, 16) catch return false) - 1);
    if (index == session.index) return true;
    _ = session.apply(.{ .core = index }, std.io.null_writer) catch return false;
    return session.index == index;
}

fn alive(session: *const debug_session.Session, text: []const u8) bool {
    const id = std.fmt.parseInt(u32, text, 16) catch return false;
    const threads: u32 = if (session.other == null) 1 else 2;
    return id >= 1 and id <= threads;
}

fn print(out: []u8, comptime format: []const u8, args: anytype) Error![]const u8 {
    return std.fmt.bufPrint(out, format, args) catch Error.NoSpace;
}

fn copy(out: []u8, text: []const u8) Error![]const u8 {
    if (text.len > out.len) return Error.NoSpace;
    @memcpy(out[0..text.len], text);
    return out[0..text.len];
}
