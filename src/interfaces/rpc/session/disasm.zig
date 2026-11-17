//! The same bounded annotated rows for remote panes and ctl clients.
const std = @import("std");

const api = @import("ra8_session").api;
const disasm = @import("ra8_session").disasm;
const handlers = @import("handlers.zig");
const rpc = @import("ra8_rpc_wire");
const wire = @import("disasm_wire.zig");

pub fn read(context: *handlers.Context, args: wire.Request) rpc.Outcome(wire.Reply) {
    const core: api.Core = if (args.core == .cpu0) .cpu0 else .cpu1;
    const view = context.session.view(core) catch return refuse();
    if (args.count == 0 or args.count > disasm.max_rows) return refuse();
    var rows: [disasm.max_rows]disasm.Row = undefined;
    const next = disasm.capture(view, handlers.imageOf(context, core), args.address, rows[0..args.count]) catch {
        return refuse();
    };
    const room = @min(context.scratch.len, wire.Reply.max_len.text);
    var writer: std.Io.Writer = .fixed(context.scratch[0..room]);
    for (rows[0..args.count]) |row| disasm.write(row, &writer) catch return tooLong();
    return .{ .ok = .{ .core = args.core, .count = args.count, .next = next, .text = writer.buffered() } };
}

fn refuse() rpc.Outcome(wire.Reply) {
    return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
}

fn tooLong() rpc.Outcome(wire.Reply) {
    return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.too_long)) };
}
