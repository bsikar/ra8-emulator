//! Lifecycle dispatch keeps native host moves first and supplies authority.
const bridge = @import("bridge.zig");
const name = @import("../name.zig");
const probe_api = @import("probe.zig");

const builtin = @import("builtin");
const std = @import("std");

const Context = @import("context.zig").Context;
const intent = @import("intent.zig");
const preserve = @import("move.zig").preserve;
const tree = @import("tree.zig");

pub fn directory(context: Context, from: []const u8, to: []const u8, purpose: []const u8, probe: ?tree.Probe) !void {
    const base = context.source;
    if (builtin.os.tag != .linux or
        base.native_provider == null or
        (if (probe) |hook| hook.force_fallback else false)) return tree.directoryProbed(
        base.allocator,
        base.io,
        base.dir,
        from,
        context.target.dir,
        to,
        purpose,
        probe,
    );
    var buffer: name.Buffer = undefined;
    const anchor = try intent.leaf(&buffer, name.classify(from).id);
    if (present(base.io, base.dir, anchor)) {
        const parsed = try intent.read(base.allocator, base.io, base.dir, anchor, true);
        defer parsed.deinit();
        return bridge.settle(context, base.native_provider.?, parsed.value);
    }
    if (try tree.moving(base.io, base.dir, from)) return tree.directoryProbed(
        base.allocator,
        base.io,
        base.dir,
        from,
        context.target.dir,
        to,
        purpose,
        probe,
    );
    try context.validate(from);
    {
        var source = try base.dir.openDir(base.io, from, .{ .iterate = true, .follow_symlinks = false });
        defer source.close(base.io);
        try tree.preflight(base.io, source, 0);
    }
    try probe_api.reach(probe, .native_before, base.dir, from, context.target.dir, to);
    preserve(base.io, base.dir, from, context.target.dir, to) catch |err| switch (err) {
        error.OperationUnsupported => try bridge.move(context, from, to, purpose),
        else => return err,
    };
    try probe_api.reach(probe, .native_moved, base.dir, from, context.target.dir, to);
}

fn present(io: std.Io, root: std.Io.Dir, path: []const u8) bool {
    _ = root.statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}
