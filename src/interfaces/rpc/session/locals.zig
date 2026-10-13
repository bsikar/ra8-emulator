//! The locals request (RA8EMU-805): a stopped core's function's locals,
//! walked from the .debug_info of the image it last loaded the way
//! `info locals` answers (session/dwarf/locals.zig); each row names the
//! local, its type's name and byte size, and where its bytes live.
//! Without an image the answer carries no rows.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const proto = @import("rpc.zig");
const handlers = @import("handlers.zig");
const locals_wire = @import("../locals_wire.zig");
const api = @import("ra8_session").api;
const symbols = @import("ra8_session").symbols;
const dwarf_locals = @import("ra8_session").dwarf.locals;
const unwind = @import("ra8_session").unwind;
const backtrace_mod = @import("backtrace.zig");

const Image = symbols.Image;
const Outcome = rpc.Outcome(proto.Locals);

pub fn locals(context: *handlers.Context, args: proto.CoreOnly) Outcome {
    const which: api.Core = @fromBackingInt(@intCast(@backingInt(args.core)));
    const view = context.session.view(which) catch |err| return refuse(err);
    if (context.scratch.len < proto.locals_bytes) return refuse(error.NoRoom);
    const pc = view.register(.pc) catch |err| return refuse(err);
    return rowsAt(context, which, args.core, pc);
}

/// Locals at a chosen frame (RA8EMU-1187): frame 0 is the stopped pc, the
/// same answer the locals op gives; frame n walks the .debug_frame chain
/// and reads the function containing that frame's call site.
pub fn localsAt(context: *handlers.Context, args: proto.CoreFrame) Outcome {
    const which: api.Core = @fromBackingInt(@intCast(@backingInt(args.core)));
    const view = context.session.view(which) catch |err| return refuse(err);
    if (context.scratch.len < proto.locals_bytes) return refuse(error.NoRoom);
    const pc = pcAtFrame(context, view, which, args.frame) catch |err| return refuse(err);
    return rowsAt(context, which, args.core, pc);
}

/// The pc a frame's locals read at: the stopped pc, or the call site the
/// frame sits in (a return address is the instruction after the call).
fn pcAtFrame(context: *handlers.Context, view: anytype, which: api.Core, frame: u32) !u32 {
    if (frame == 0) return view.register(.pc);
    const image = imageOf(context, which);
    var walked: [unwind.limits.frames]unwind.Frame = undefined;
    const count = try backtrace_mod.walk(view, image, &walked);
    if (frame >= count) return error.BadFrame;
    const found = walked[frame];
    return if (found.exact) found.pc else found.pc -% 1;
}

fn rowsAt(context: *handlers.Context, which: api.Core, shown: proto.Core, pc: u32) Outcome {
    const loaded = imageOf(context, which) orelse return .{ .ok = .{ .core = shown, .count = 0, .rows = "" } };
    var into: [proto.locals_rows]dwarf_locals.Local = undefined;
    const count = dwarf_locals.inFunction(dwarf_locals.ofImage(loaded), pc, &into) catch |err| return refuse(err);
    var at: usize = 0;
    for (into[0..count]) |found| {
        locals_wire.put(context.scratch[0..proto.locals_bytes], &at, describe(found)) catch |err| return refuse(err);
    }
    return .{ .ok = .{ .core = shown, .count = @intCast(count), .rows = context.scratch[0..at] } };
}

fn describe(found: dwarf_locals.Local) proto.LocalRow {
    var row: proto.LocalRow = .{ .name = "", .type_name = "", .size = 0, .where_kind = proto.where_kinds.none, .where_a = 0, .where_b = 0 };
    row.name = found.name[0..@min(found.name.len, proto.local_name_cap)];
    row.type_name = found.type_name[0..@min(found.type_name.len, proto.local_type_cap)];
    row.size = found.size;
    if (found.where) |place| switch (place) {
        .frame => |offset| {
            row.where_kind = proto.where_kinds.frame;
            row.where_a = @bitCast(offset);
        },
        .register => |indirect| {
            row.where_kind = proto.where_kinds.register;
            row.where_a = indirect.reg;
            row.where_b = @bitCast(indirect.offset);
        },
        .in_register => |reg| {
            row.where_kind = proto.where_kinds.in_register;
            row.where_a = reg;
        },
        .address => |at| {
            row.where_kind = proto.where_kinds.address;
            row.where_a = at;
        },
    };
    return row;
}

/// The image the serving side holds for `core`, if any.
fn imageOf(context: *handlers.Context, core: api.Core) ?Image {
    const mapping = context.mapping orelse return null;
    const imageFn = mapping.imageFn orelse return null;
    return imageFn(mapping.context, @backingInt(core));
}

fn refuse(err: anyerror) Outcome {
    if (err == error.CoreNotAttached) return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.no_core)) };
    return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
}
