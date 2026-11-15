//! One transfer per connection; commit queues a fully validated replacement for the serving loop.
const capture = @import("capture.zig");
const Context = @import("../session/handlers.zig").Context;
const proto = @import("../session/rpc.zig");
const rpc = @import("ra8_rpc_wire");
const spool = @import("spool.zig");
const wire = @import("wire.zig");

pub const routes = .{
    .{ @backingInt(wire.Method.export_begin), exportBegin },
    .{ @backingInt(wire.Method.export_read), exportRead },
    .{ @backingInt(wire.Method.import_begin), importBegin },
    .{ @backingInt(wire.Method.import_write), importWrite },
    .{ @backingInt(wire.Method.import_end), importEnd },
    .{ @backingInt(wire.Method.abort), abort },
};

pub fn exportBegin(context: *Context, args: wire.Export) rpc.Outcome(wire.Descriptor) {
    const service = context.artifacts orelse return refused(wire.Descriptor, error.Unavailable);
    if (context.artifact_transfer.file != null) return refused(wire.Descriptor, error.TransferBusy);
    if (args.recording > 1) return refused(wire.Descriptor, error.InvalidArgument);
    const file = capture.make(service.active, service.spool, args.recording != 0) catch |err| {
        return refused(wire.Descriptor, err);
    };
    const size = (file.stat(service.io) catch |err| {
        file.close(service.io);
        return refused(wire.Descriptor, err);
    }).size;
    const digest = spool.checksum(file, service.io) catch |err| {
        file.close(service.io);
        return refused(wire.Descriptor, err);
    };
    const id = service.id() catch |err| {
        file.close(service.io);
        return refused(wire.Descriptor, err);
    };
    context.artifact_transfer.begin(service.io, file, id, size, digest, false) catch |err| {
        file.close(service.io);
        return refused(wire.Descriptor, err);
    };
    return .{ .ok = .{ .id = id, .total = size, .sha256 = &context.artifact_transfer.expected } };
}

pub fn exportRead(context: *Context, args: wire.Read) rpc.Outcome(wire.Chunk) {
    if (context.artifacts == null) return refused(wire.Chunk, error.Unavailable);
    const chunk = context.artifact_transfer.read(args, context.scratch) catch |err| return refused(wire.Chunk, err);
    return .{ .ok = chunk };
}

pub fn importBegin(context: *Context, args: wire.Begin) rpc.Outcome(wire.Id) {
    const service = context.artifacts orelse return refused(wire.Id, error.Unavailable);
    if (context.artifact_transfer.file != null) return refused(wire.Id, error.TransferBusy);
    if (args.sha256.len != 32) return refused(wire.Id, error.BadChecksum);
    if (args.total == 0 or args.total > wire.max_bundle) return refused(wire.Id, error.TooLarge);
    const id = service.id() catch |err| return refused(wire.Id, err);
    const file = service.spool.file() catch |err| return refused(wire.Id, err);
    context.artifact_transfer.begin(service.io, file, id, args.total, args.sha256[0..32].*, true) catch |err| {
        file.close(service.io);
        return refused(wire.Id, err);
    };
    return .{ .ok = .{ .id = id } };
}

pub fn importWrite(context: *Context, args: wire.Chunk) rpc.Outcome(proto.Ack) {
    if (context.artifacts == null) return refused(proto.Ack, error.Unavailable);
    context.artifact_transfer.append(args) catch |err| return refused(proto.Ack, err);
    return .{ .ok = .{ .accepted = 1 } };
}

pub fn importEnd(context: *Context, args: wire.Id) rpc.Outcome(wire.Commit) {
    const service = context.artifacts orelse return refused(wire.Commit, error.Unavailable);
    const file = context.artifact_transfer.complete(args.id) catch |err| return refused(wire.Commit, err);
    defer context.artifact_transfer.drop();
    service.prepare(file) catch |err| return refused(wire.Commit, err);
    return .{ .ok = .{ .accepted = 1, .reconnect = 1 } };
}

pub fn abort(context: *Context, args: wire.Id) rpc.Outcome(proto.Ack) {
    if (context.artifacts == null) return refused(proto.Ack, error.Unavailable);
    if (context.artifact_transfer.file == null or context.artifact_transfer.id != args.id) {
        return refused(proto.Ack, error.TransferState);
    }
    context.artifact_transfer.drop();
    return .{ .ok = .{ .accepted = 1 } };
}

fn refused(comptime T: type, err: anyerror) rpc.Outcome(T) {
    const code: u16 = switch (err) {
        error.Unavailable => wire.codes.unavailable,
        error.SessionBusy, error.TransferBusy, error.TransferState, error.DetachedHistory => wire.codes.state,
        error.TooLarge => wire.codes.too_large,
        error.AccessDenied, error.NoSpaceLeft, error.WriteFailed, error.ReadFailed => wire.codes.io,
        else => wire.codes.invalid,
    };
    return .{ .err = @fromBackingInt(code) };
}
