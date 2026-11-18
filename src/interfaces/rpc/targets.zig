//! Inventory, reservations, verified ELF/receipt flashing, and streamed
//! progress events sharing one host registry across connections.
const std = @import("std");

const Ack = @import("session/rpc.zig").Ack;
const Context = @import("session/handlers.zig").Context;
const model = @import("ra8_host").targets;
const rpc = @import("ra8_rpc_wire");
const wire = @import("targets_wire.zig");

pub const routes = .{
    .{ @backingInt(wire.Method.list), list },
    .{ @backingInt(wire.Method.reserve), reserve },
    .{ @backingInt(wire.Method.release), release },
    .{ @backingInt(wire.Method.perform), perform },
    .{ @backingInt(wire.Method.flash_begin), flashBegin },
    .{ @backingInt(wire.Method.flash_chunk), flashChunk },
    .{ @backingInt(wire.Method.flash_commit), flashCommit },
    .{ @backingInt(wire.Method.flash_receipt), flashReceipt },
};

pub fn list(context: *Context, _: struct {}) rpc.Outcome(wire.Text) {
    const registry = context.targets orelse return refuse(wire.Text, error.Unavailable);
    registry.refresh();
    var out: std.Io.Writer = .fixed(context.scratch[0..@min(context.scratch.len, wire.max_json)]);
    out.writeByte('[') catch |err| return refuse(wire.Text, err);
    var first = true;
    for (registry.entries) |slot| {
        const entry = slot orelse continue;
        if (!first) out.writeByte(',') catch |err| return refuse(wire.Text, err);
        first = false;
        std.json.Stringify.value(.{
            .target = entry.target,
            .generation = entry.generation,
            .reserved = entry.owner != null,
        }, .{}, &out) catch |err| return refuse(wire.Text, err);
    }
    out.writeByte(']') catch |err| return refuse(wire.Text, err);
    return .{ .ok = .{ .json = out.buffered() } };
}

pub fn reserve(context: *Context, args: wire.Selection) rpc.Outcome(Ack) {
    const registry = context.targets orelse return refuse(Ack, error.Unavailable);
    registry.reserve(context, selection(args)) catch |err| return refuse(Ack, err);
    return .{ .ok = .{ .accepted = 1 } };
}

pub fn release(context: *Context, _: struct {}) rpc.Outcome(Ack) {
    forget(context);
    return .{ .ok = .{ .accepted = 1 } };
}

pub fn perform(context: *Context, args: wire.Perform) rpc.Outcome(wire.Text) {
    const registry = context.targets orelse return refuse(wire.Text, error.Unavailable);
    const json = registry.perform(context, selection(args), args.action, context.scratch) catch |err|
        return refuse(wire.Text, err);
    if (json.len > wire.max_json) return refuse(wire.Text, error.TooLarge);
    context.target_flash.progress.push(@tagName(args.action), json);
    return .{ .ok = .{ .json = json } };
}

pub fn flashBegin(context: *Context, args: wire.FlashBegin) rpc.Outcome(Ack) {
    if (context.targets == null) return refuse(Ack, error.Unavailable);
    const gpa = context.gpa orelse return refuse(Ack, error.Unavailable);
    if (args.total_len == 0 or args.total_len > wire.max_flash_elf) return refuse(Ack, error.InvalidElf);
    context.target_flash.chunks.begin(gpa, args.total_len, args.checksum) catch |err| return refuse(Ack, err);
    return .{ .ok = .{ .accepted = 1 } };
}

pub fn flashChunk(context: *Context, args: wire.FlashChunk) rpc.Outcome(Ack) {
    if (context.targets == null) return refuse(Ack, error.Unavailable);
    context.target_flash.chunks.chunk(args.offset, args.bytes) catch |err| return refuse(Ack, err);
    return .{ .ok = .{ .accepted = 1 } };
}

pub fn flashCommit(context: *Context, args: wire.FlashCommit) rpc.Outcome(wire.Text) {
    const gpa = context.gpa orelse return refuse(wire.Text, error.Unavailable);
    const elf = context.target_flash.chunks.end() catch |err| return refuse(wire.Text, err);
    defer gpa.free(elf);
    return executeFlash(context, selection(args), elf, args.reset != 0, args.uart != 0);
}

pub fn flashReceipt(context: *Context, args: wire.FlashReceipt) rpc.Outcome(wire.Text) {
    if (context.targets == null) return refuse(wire.Text, error.Unavailable);
    const project = context.project orelse return refuse(wire.Text, error.Unavailable);
    const parsed = project.parsed orelse return refuse(wire.Text, error.ProjectNotOpen);
    if (!std.mem.eql(u8, parsed.value.target, args.board_id)) {
        return refuse(wire.Text, error.TargetProfileMismatch);
    }
    const elf = project.load(args.receipt) catch |err| return refuse(wire.Text, err);
    defer project.allocator.free(elf);
    return executeFlash(context, selection(args), elf, args.reset != 0, args.uart != 0);
}

fn executeFlash(
    context: *Context,
    sel: model.Selection,
    elf: []const u8,
    do_reset: bool,
    do_uart: bool,
) rpc.Outcome(wire.Text) {
    const registry = context.targets orelse return refuse(wire.Text, error.Unavailable);
    var flash_buf: [2048]u8 = undefined;
    const flash_json = registry.flash(context, sel, elf, &flash_buf) catch |err| return refuse(wire.Text, err);
    context.target_flash.progress.push("flash", flash_json);

    var reset_buf: [1024]u8 = undefined;
    const reset_json: ?[]const u8 = if (do_reset) blk: {
        const res = registry.perform(context, sel, .reset, &reset_buf) catch |err| return refuse(wire.Text, err);
        context.target_flash.progress.push("reset", res);
        break :blk res;
    } else null;

    var uart_buf: [4096]u8 = undefined;
    const uart_json: ?[]const u8 = if (do_uart) blk: {
        const cap = registry.perform(context, sel, .uart, &uart_buf) catch |err| return refuse(wire.Text, err);
        context.target_flash.progress.push("uart", cap);
        break :blk cap;
    } else null;

    var out: std.Io.Writer = .fixed(context.scratch[0..@min(context.scratch.len, wire.max_json)]);
    out.print("{{\"flash\":{s},\"reset\":{s},\"uart\":{s}}}", .{
        flash_json,
        reset_json orelse "null",
        uart_json orelse "null",
    }) catch |err| return refuse(wire.Text, err);
    return .{ .ok = .{ .json = out.buffered() } };
}

pub fn pump(context: *Context, server: anytype, tx: []u8) !void {
    for (0..8) |_| {
        const item = context.target_flash.progress.pop() orelse return;
        try server.emit(
            wire.Progress,
            wire.progress_topic,
            .{
                .sequence = item.sequence,
                .stage = item.stage[0..item.stage_len],
                .json = item.json[0..item.json_len],
            },
            tx,
        );
    }
}

pub fn forget(context: *Context) void {
    context.target_flash.reset();
    if (context.targets) |registry| registry.release(context);
}

fn selection(args: anytype) model.Selection {
    return .{
        .host_id = args.host_id,
        .probe_id = args.probe_id,
        .board_id = args.board_id,
        .generation = args.generation,
        .disambiguation = args.disambiguation,
    };
}

fn refuse(comptime T: type, err: anyerror) rpc.Outcome(T) {
    const code = switch (err) {
        error.Unavailable => wire.codes.unavailable,
        error.StaleSelection, error.StaleLease, error.Disconnected => wire.codes.stale,
        error.AmbiguousIdentity => wire.codes.ambiguous,
        error.TargetBusy, error.AlreadyReserved => wire.codes.busy,
        error.NotReserved => wire.codes.ownership,
        error.Unsupported => wire.codes.unsupported,
        error.CustodianUnavailable => wire.codes.custodian,
        error.BadArgs,
        error.BadChecksum,
        error.NotElf,
        error.InvalidElf,
        error.UnsupportedElfTarget,
        error.EmptyLoadImage,
        error.TooManySegments,
        error.InvalidFlashWindow,
        error.AddressOutOfRange,
        error.TargetProfileMismatch,
        error.ProjectNotOpen,
        error.InvalidBuildReceipt,
        error.SourceChanged,
        error.ArtifactChanged,
        error.ProjectConfigChanged,
        error.StaleBuildSelection,
        => wire.codes.invalid_artifact,
        else => wire.codes.failed,
    };
    return .{ .err = @fromBackingInt(code) };
}
