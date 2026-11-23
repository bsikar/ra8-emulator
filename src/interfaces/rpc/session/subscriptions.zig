//! Topic requests are retained while idle and rebound to the next session.
const connection = @import("connection.zig");
const cores = @import("cores.zig");
const handlers = @import("handlers.zig");
const proto = @import("rpc.zig");

const Context = handlers.Context;
const ack: handlers.Ack = .{ .ok = .{ .accepted = 1 } };

fn bit(topic: proto.Topic) u8 {
    return @as(u8, 1) << @intCast(@backingInt(topic) - @backingInt(proto.Topic.stop));
}

pub fn subscribe(context: *Context, args: proto.Subscription) handlers.Ack {
    if (context.session) |session| {
        if (!session.hasCore(handlers.core(args.core))) {
            return .{ .err = @fromBackingInt(proto.app_codes.no_core) };
        }
        attach(context, args.topic) catch return .{ .err = @fromBackingInt(proto.app_codes.refused) };
    }
    if (args.topic == .lcd_dirty) context.lcd_rate[@backingInt(args.core)] = args.rate;
    context.topics[@backingInt(args.core)] |= bit(args.topic);
    return ack;
}

fn feed(context: *Context, slot: *?usize) !void {
    if (slot.* == null) slot.* = try context.session.?.subscribe();
}

fn attach(context: *Context, topic: proto.Topic) !void {
    switch (topic) {
        .uart => try feed(context, &context.uart_feed),
        .session => try feed(context, &context.session_feed),
        .trace => {
            if (context.trace_feed != null) return;
            const on = context.trace_on orelse return error.Unavailable;
            if (!on.onFn(on.context)) return error.Unavailable;
            try feed(context, &context.trace_feed);
        },
        .lcd_dirty => {
            if (context.lcd_feed != null) return;
            const display = context.session.?.display orelse return error.Unavailable;
            if (context.gpa == null) return error.Unavailable;
            try feed(context, &context.lcd_feed);
            display.watch(true);
        },
        else => {},
    }
}

pub fn unsubscribe(context: *Context, args: proto.Subscription) handlers.Ack {
    if (context.session) |session| {
        if (cores.absent(session, handlers.core(args.core))) {
            return .{ .err = @fromBackingInt(proto.app_codes.no_core) };
        }
    }
    context.topics[@backingInt(args.core)] &= ~bit(args.topic);
    if (!context.wants(args.core, .lcd_dirty)) {
        context.lcd_rate[@backingInt(args.core)] = 0;
        context.lcd_pending[@backingInt(args.core)] = null;
    }
    if (!context.wants(.cpu0, .uart) and !context.wants(.cpu1, .uart)) connection.release(context, &context.uart_feed);
    if (!context.wants(.cpu0, .lcd_dirty) and !context.wants(.cpu1, .lcd_dirty)) connection.unwatch(context);
    if (!context.wants(.cpu0, .session) and !context.wants(.cpu1, .session)) {
        connection.release(context, &context.session_feed);
    }
    if (!context.wants(.cpu0, .trace) and !context.wants(.cpu1, .trace)) {
        connection.release(context, &context.trace_feed);
    }
    return ack;
}
