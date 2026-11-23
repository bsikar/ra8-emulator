//! Service requests remain available while no emulator session exists.
const handlers = @import("handlers.zig");
const proto = @import("rpc.zig");
const rpc = @import("ra8_rpc_wire");

pub const Configure = struct {
    machine: []const u8,
    profile: []const u8,
    pub const max_len = .{ .machine = 64, .profile = 65536 };
};
pub const Status = struct {
    loaded: u8,
    machine: []const u8,
    pub const max_len = .{ .machine = 64 };
};
pub const Hooks = struct {
    context: *anyopaque,
    loadFn: *const fn (*anyopaque, []const u8) anyerror!void,
    closeFn: *const fn (*anyopaque) anyerror!void,
    configureFn: *const fn (*anyopaque, Configure) anyerror!void,
    machineFn: *const fn (*anyopaque) []const u8,
    commitFn: *const fn (*anyopaque) void,
    discardFn: *const fn (*anyopaque) void,
};

pub const routes = .{
    .{ @backingInt(proto.Method.session_status), status },
    .{ @backingInt(proto.Method.session_close), close },
    .{ @backingInt(proto.Method.session_configure), configure },
};

pub fn load(context: *handlers.Context, image: []const u8) handlers.Ack {
    const hooks = context.lifecycle.?;
    hooks.loadFn(hooks.context, image) catch return .{ .err = @fromBackingInt(proto.app_codes.refused) };
    context.session_change_pending = true;
    return .{ .ok = .{ .accepted = 1 } };
}

pub fn status(context: *handlers.Context, _: struct {}) rpc.Outcome(Status) {
    const machine = if (context.session) |session| session.machine_desc.name else if (context.lifecycle) |hooks|
        hooks.machineFn(hooks.context)
    else
        "";
    return .{ .ok = .{ .loaded = @intFromBool(context.session != null), .machine = machine } };
}

pub fn close(context: *handlers.Context, _: struct {}) handlers.Ack {
    const hooks = context.lifecycle orelse return .{ .err = .unknown_method };
    hooks.closeFn(hooks.context) catch return .{ .err = .failed };
    context.session_change_pending = true;
    return .{ .ok = .{ .accepted = 1 } };
}

pub fn configure(context: *handlers.Context, args: Configure) handlers.Ack {
    const hooks = context.lifecycle orelse return .{ .err = .unknown_method };
    hooks.configureFn(hooks.context, args) catch return .{ .err = .bad_args };
    return .{ .ok = .{ .accepted = 1 } };
}

pub fn guard(comptime method: proto.Method, comptime handler: anytype) @TypeOf(handler) {
    return switch (method) {
        .load, .load_begin, .load_chunk, .load_end, .subscribe, .unsubscribe => handler,
        else => Guard(handler).call,
    };
}

fn Guard(comptime handler: anytype) type {
    const info = @typeInfo(@TypeOf(handler)).@"fn";
    return struct {
        fn call(context: *handlers.Context, args: info.param_types[1].?) info.return_type.? {
            if (context.session == null) return .{ .err = @fromBackingInt(proto.app_codes.no_session) };
            return handler(context, args);
        }
    };
}
