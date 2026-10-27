//! The `marker_set` request: arms a marker after recording. The marker's
//! place is resolved against the loaded image, the recorded history is
//! replayed once to index every arrival at it, the arrivals join the
//! session's navigation index, and the host storage the application bound
//! keeps them so a reopened history needs no second replay. The machine
//! returns to where it stood before the replay.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const proto = @import("rpc.zig");
const handlers = @import("handlers.zig");
const session_mod = @import("ra8_session");

const late_marker = session_mod.history_late_marker;
const marker_scan = session_mod.transport_marker_scan;
const Outcome = rpc.Outcome(proto.NavQueryResult);

/// The cache file the arrivals are kept in, inside the history's index space.
pub const cache_file = "markers.idx";

const Scan = struct {
    plane: *session_mod.transport.Transport,
    scanned: bool = false,

    fn run(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        address: u32,
        out: *std.ArrayListUnmanaged(late_marker.Position),
    ) anyerror!void {
        const self: *Scan = @ptrCast(@alignCast(context));
        self.scanned = true;
        try marker_scan.scan(self.plane, allocator, address, out);
    }
};

/// How long the committed log is now. A marker's arrivals are good for a log
/// of exactly this length; a history that grew past it has later ones.
pub fn historyEnd(plane: *session_mod.transport.Transport) u64 {
    const bridge = plane.history orelse return 0;
    const read = bridge.logBytes orelse return 0;
    return (read(bridge.context) catch return 0).len;
}

pub fn markerSet(context: *handlers.Context, args: proto.MarkerSetArgs) Outcome {
    if (args.name.len == 0) return .{ .err = .bad_args };
    const plane = context.transport orelse return refuse();
    const wall = context.wall orelse return refuse();
    const gpa = context.gpa orelse return refuse();
    const nav = context.session.nav_index orelse return refuse();
    const named = resolve(context, args.place) orelse return .{ .err = .bad_args };
    const address = named & ~@as(u32, 1); // the Thumb bit names the mode, not the place
    const end = historyEnd(plane);
    nav.dropStaleMarkers(end);
    if (nav.markerArrivalCount(args.name) == 0) {
        const origin = context.session.currentPosition();
        var scan: Scan = .{ .plane = plane };
        const armed = late_marker.armLate(gpa, context.nav.markers, cache_file, args.name, address, end, .{
            .context = &scan,
            .runFn = &Scan.run,
        }, nav);
        // The replay moves the machine; it goes back whether or not it indexed.
        if (scan.scanned) marker_scan.returnTo(plane, origin, wall) catch return refuse();
        _ = armed catch return refuse();
    }
    return reply(nav, args.name);
}

fn reply(nav: *const late_marker.NavIndex, name: []const u8) Outcome {
    const count = nav.markerArrivalCount(name);
    const first = nav.getMarkerArrival(name, 1) orelse return .{ .ok = .{ .found = 0, .count = count } };
    return .{ .ok = .{
        .found = 1,
        .branch = first.branch,
        .r = first.r,
        .phase = @backingInt(first.phase),
        .o = first.o,
        .gap = @backingInt(first.gap),
        .count = count,
    } };
}

/// A `0x` address as written, or a symbol of the loaded image.
fn resolve(context: *handlers.Context, place: []const u8) ?u32 {
    if (place.len > 2 and place[0] == '0' and (place[1] == 'x' or place[1] == 'X')) {
        return std.fmt.parseInt(u32, place[2..], 16) catch null;
    }
    const mapping = context.mapping orelse return null;
    const image_fn = mapping.imageFn orelse return null;
    const image = image_fn(mapping.context, 0) orelse return null;
    return session_mod.symbols.addressOf(image, place);
}

fn refuse() Outcome {
    return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
}
