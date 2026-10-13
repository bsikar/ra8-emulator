//! The source-line request (RA8EMU-1125): the file and line a core's pc
//! belongs to, looked up in the .debug_line of the image it last loaded,
//! the way `info line` reports it (session/source.zig). Without an image,
//! or when the line table does not cover the pc, `found` is 0 and the path
//! is empty; the leaf reads the file's rows itself.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const proto = @import("rpc.zig");
const handlers = @import("handlers.zig");
const api = @import("ra8_session").api;
const symbols = @import("ra8_session").symbols;
const dwarf_line = @import("ra8_session").dwarf.line;
const session_source = @import("ra8_session").source;

const Image = symbols.Image;
const Outcome = rpc.Outcome(proto.SourceLine);

/// The answer when the pc has no source place to show.
const none: proto.SourceLine = .{ .found = 0, .line = 0, .path = "" };

pub fn sourceLine(context: *handlers.Context, args: proto.CoreOnly) Outcome {
    const which: api.Core = @fromBackingInt(@intCast(@backingInt(args.core)));
    const view = context.session.view(which) catch |err| return refuse(err);
    const pc = view.register(.pc) catch |err| return refuse(err);
    const loaded = imageOf(context, which) orelse return .{ .ok = none };
    const place = (dwarf_line.lookup(dwarf_line.ofImage(loaded), pc) catch null) orelse return .{ .ok = none };
    var spelled: [proto.source_path_cap]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&spelled);
    session_source.path(&writer, place.file) catch return refuse(error.NoRoom);
    return .{ .ok = .{ .found = 1, .line = place.line, .path = spelled[0..writer.buffered().len] } };
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
