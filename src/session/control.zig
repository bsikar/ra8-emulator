//! Session run control and event streaming helpers (Slice 20.3).
const display_api = @import("display.zig");
const stream = @import("event/stream.zig");

const std = @import("std");

const api = @import("api.zig");
const itm = @import("ra8_chip").periph.itm;
const stop_machine = @import("stop_machine.zig");

pub fn checkRegister(session: *const api.Session, core: api.Core, which: api.Register) api.Error!void {
    const info = session.coreInfo(core) orelse return api.Error.CoreNotAttached;
    if (which == .vpr and !info.mve) return api.Error.UnsupportedRegister;
    if (isFpRegister(which) and !info.hasFpu()) return api.Error.UnsupportedRegister;
}

fn isFpRegister(which: api.Register) bool {
    if (which == .fpscr) return true;
    const tag = @backingInt(which);
    return tag >= @backingInt(api.Register.s0) and tag <= @backingInt(api.Register.s31);
}

pub fn rewind(session: *api.Session, core: api.Core, back: u32) anyerror!void {
    if (session.persistent_recorder) |rec| try rec.force();
    try session.select(core);
    const h = session.history orelse return api.Error.NoHistory;
    try h.restore(back);
    session.publish(.{ .core = core, .kind = .rewound });
}

pub fn stepBack(session: *api.Session, core: api.Core) anyerror!void {
    const h = session.history orelse return api.Error.NoHistory;
    return rewind(session, core, h.cursor + 1);
}

pub fn reverseContinue(session: *api.Session, core: api.Core) anyerror!void {
    const h = session.history orelse return api.Error.NoHistory;
    if (h.len() == 0) return api.History.Error.NotRecorded;
    const machine = try session.machine(core);
    var at = h.cursor + 1;
    while (at < h.len()) : (at += 1) {
        const frame_info = try h.frame(at);
        if (frame_info.tag == 1 or machine.breaks.hit(frame_info.pc) != null) break;
    }
    if (at >= h.len()) at = h.len() - 1;
    if (at <= h.cursor) return api.History.Error.NotRecorded;
    return rewind(session, core, at);
}

pub fn interrupt(session: *api.Session, core: api.Core) anyerror!stop_machine.Stop {
    if (session.persistent_recorder) |rec| try rec.force();
    try session.select(core);
    const stop = session.live.machine.interrupt();
    session.publish(.{ .core = core, .kind = .stopped, .ended = .{ .stop = stop } });
    return stop;
}

pub fn pause(session: *api.Session, core: api.Core) anyerror!void {
    if (session.persistent_recorder) |rec| try rec.force();
    try session.select(core);
    if (session.smooth_rewind) |smooth| {
        if (smooth.status == .playing_backward) {
            try smooth.pause();
            session.publish(.{ .core = core, .kind = .paused });
            return;
        }
    }
    session.live.machine.requestHalt();
    session.publish(.{ .core = core, .kind = .paused });
}

pub fn itmPort(session: *api.Session, core: api.Core) anyerror!*itm.Itm {
    return &(try session.machine(core)).itm;
}

pub fn flushItm(session: *api.Session, core: api.Core, out: anytype, final: bool) anyerror!void {
    try (try itmPort(session, core)).flush(out, final);
}

pub fn publish(session: *api.Session, event: api.Event) void {
    var stamped = event;
    stamped.virtual_ns = if (session.event_clock) |clock| clock.nowFn(clock.context) else session.now() catch 0;
    session.event_stream.publish(stamped);
}

pub fn subscribe(session: *api.Session) api.Error!usize {
    return session.event_stream.subscribe() orelse api.Error.TooManySubscribers;
}

pub fn unsubscribe(session: *api.Session, id: usize) void {
    session.event_stream.unsubscribe(id);
}

pub fn pollEvents(session: *api.Session, id: usize, out: []api.Event) ?stream.Read {
    return session.event_stream.read(id, out);
}

pub fn dirty(session: *api.Session) void {
    if (session.live.boundary) |edge| if (edge.saved) |saved| {
        saved.stretch.dirty = true;
    };
}

pub fn waitSettled(session: *api.Session, timeout_ns: u64) anyerror!void {
    const display = session.display orelse return display_api.Error.NoDisplay;
    try display.waitSettled(timeout_ns);
}

pub fn frame(session: *api.Session, allocator: std.mem.Allocator) anyerror!api.Frame {
    const display = session.display orelse return display_api.Error.NoDisplay;
    return display.frame(allocator);
}
