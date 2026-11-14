//! Connection-owned project, build and subscription cleanup.
const Context = @import("handlers.zig").Context;
const project = @import("../project.zig");
const build = @import("../build.zig");

/// Drop every subscription, as a new connection starts with none.
pub fn forget(context: *Context) void {
    project.forget(context);
    build.forget(context);
    context.workspace_watches.clear();
    context.topics = .{ 0, 0 };
    context.pending = null;
    context.advance_ticket = null;
    context.advance_from_ns = 0;
    context.advance_target_ns = 0;
    context.transport_epoch = 0;
    context.lcd_rate = .{ 0, 0 };
    context.lcd_pending = .{ null, null };
    context.lcd_holds = 0;
    release(context, &context.uart_feed);
    unwatch(context);
    release(context, &context.session_feed);
    release(context, &context.trace_feed);
}

/// Give up the panel feed, and the watch on the panel that came with it.
pub fn unwatch(context: *Context) void {
    if (context.lcd_feed == null) return;
    release(context, &context.lcd_feed);
    if (context.session.display) |display| display.watch(false);
}

pub fn release(context: *Context, feed: *?usize) void {
    const id = feed.* orelse return;
    context.session.unsubscribe(id);
    feed.* = null;
}
