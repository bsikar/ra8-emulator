//! Build ownership and live event delivery for a single served connection.
const rpc = @import("ra8_rpc_wire");
const wire = @import("build_wire.zig");
const Context = @import("session/handlers.zig").Context;
const Ack = @import("session/rpc.zig").Ack;
pub const routes = .{ .{ @backingInt(wire.Method.start), start }, .{ @backingInt(wire.Method.status), status }, .{ @backingInt(wire.Method.cancel), cancel } };

pub fn start(context: *Context, args: wire.Start) rpc.Outcome(wire.Id) {
    const runner = context.build_runner orelse return refuse(wire.Id, error.Unavailable);
    const id = runner.start(.{ .step = args.step, .options = args.options, .artifact = args.artifact, .timeout_ms = args.timeout_ms }) catch |err| return refuse(wire.Id, err);
    context.build_id = id;
    context.build_completion_sent = false;
    return .{ .ok = .{ .id = id } };
}

pub fn status(context: *Context, args: wire.Id) rpc.Outcome(wire.Status) {
    const runner = context.build_runner orelse return refuse(wire.Status, error.Unavailable);
    if (args.id != context.build_id) return refuse(wire.Status, error.UnknownBuild);
    const job = runner.get(args.id) catch |err| return refuse(wire.Status, err);
    const done = job.done.load(.acquire);
    return .{ .ok = .{ .id = args.id, .done = @intFromBool(done), .result = if (done) job.result[0..job.result_len] else "" } };
}

pub fn cancel(context: *Context, args: wire.Id) rpc.Outcome(Ack) {
    const runner = context.build_runner orelse return refuse(Ack, error.Unavailable);
    if (args.id != context.build_id) return refuse(Ack, error.UnknownBuild);
    runner.cancel(args.id) catch |err| return refuse(Ack, err);
    return .{ .ok = .{ .accepted = 1 } };
}

pub fn forget(context: *Context) void {
    if (context.build_runner) |runner| runner.release(context.build_id);
    context.build_id = 0;
    context.build_completion_sent = false;
}

pub fn pump(context: *Context, server: anytype, tx: []u8) !void {
    const runner = context.build_runner orelse return;
    if (context.build_id == 0) return;
    const job = runner.get(context.build_id) catch return;
    // Finite work per server pump, including when output floods the subscriber.
    for (0..8) |_| {
        // Acquire completion before checking the queue: its final push must precede
        // the empty observation, or completion could overtake the last chunk.
        const done = job.done.load(.acquire);
        const event = job.queue.pop(runner.io) orelse {
            if (done and !context.build_completion_sent) {
                try server.emit(wire.Status, wire.completed_topic, .{ .id = job.id, .done = 1, .result = job.result[0..job.result_len] }, tx);
                context.build_completion_sent = true;
            }
            return;
        };
        try server.emit(wire.Event, wire.event_topic, .{ .id = job.id, .sequence = event.sequence, .kind = event.kind, .bytes = event.bytes[0..event.len] }, tx);
    }
}

fn refuse(comptime T: type, err: anyerror) rpc.Outcome(T) {
    const code: u16 = switch (err) {
        error.InvalidRecipe, error.InvalidPath, error.NameTooLong => return .{ .err = .bad_args },
        error.BuildBusy => wire.codes.busy,
        error.UnknownBuild => wire.codes.unknown_job,
        error.Unavailable => wire.codes.unavailable,
        else => wire.codes.io,
    };
    return .{ .err = @fromBackingInt(code) };
}
