//! Capture while the server's serial execution loop is stopped between requests.
const std = @import("std");

const bundle = @import("ra8_snapshot").bundle;
const inventory = @import("inventory.zig");
const session = @import("ra8_session");
const setup = @import("../served_setup.zig");
const Spool = @import("spool.zig").Spool;
const wire = @import("wire.zig");

pub fn quiet(source: *setup.Served) !void {
    const plane = source.owner.transport();
    if (plane.job != null or plane.pending_finish != null or plane.busy() != null) return error.SessionBusy;
}

pub fn make(source: *setup.Served, spool: *Spool, recording: bool) !std.Io.File {
    try quiet(source);
    try source.flushHistory();
    const state = try spool.save(&source.owner.state.files, writeState, 1024 * 1024 * 1024);
    defer state.close(source.io);
    const metadata = try describe(source);
    const root = if (recording) source.owner.session().root else null;
    var list: inventory.Inventory = .{ .gpa = spool.gpa };
    defer list.deinit();
    if (root) |recorded| {
        if (source.history != null and source.owner.session().graph_sink == null) return error.DetachedHistory;
        try sameImages(metadata, recorded);
        try list.gather(source);
    }
    const roots = if (root) |recorded| try spool.save(@constCast(recorded), writeRoot, 64 * 1024 * 1024) else null;
    defer if (roots) |file| file.close(source.io);
    const graph = if (root != null) source.owner.session().fork_router.?.graph.? else null;
    const branches = if (graph) |value| try spool.save(value, writeGraph, 8 * 1024 * 1024) else null;
    defer if (branches) |file| file.close(source.io);
    return archive(source, spool, state, roots, branches, metadata, &list);
}

pub fn describe(source: *setup.Served) !bundle.manifest.Metadata {
    const first = source.owner.loadedImage(.cpu0) orelse return error.NoImage;
    const second = source.owner.loadedImage(.cpu1);
    return .{
        .board = @tagName(source.owner.board().part),
        .elf0 = image("cpu0.elf", first.bytes),
        .elf1 = if (second) |value| image("cpu1.elf", value.bytes) else null,
    };
}

fn image(name: []const u8, bytes: []const u8) bundle.manifest.Image {
    return .{ .name = name, .identity = session.history_root.identity(bytes), .size = bytes.len };
}

fn sameImages(metadata: bundle.manifest.Metadata, root: *const session.history_root.Root) !void {
    if (!std.mem.eql(u8, &metadata.elf0.identity, &root.elf0.identity)) return error.DetachedHistory;
    if ((metadata.elf1 == null) != (root.elf1 == null)) return error.DetachedHistory;
    if (metadata.elf1) |second| {
        if (!std.mem.eql(u8, &second.identity, &root.elf1.?.identity)) return error.DetachedHistory;
    }
}

fn archive(
    source: *setup.Served,
    spool: *Spool,
    state: std.Io.File,
    root: ?std.Io.File,
    branches: ?std.Io.File,
    metadata: bundle.manifest.Metadata,
    list: *inventory.Inventory,
) !std.Io.File {
    const io = source.io;
    var json: [8192]u8 = undefined;
    const manifest = try bundle.manifest.encode(&json, metadata, root != null);
    var size = 1024 + try inventory.entryCost(manifest.len);
    size += try inventory.entryCost((try state.stat(io)).size);
    if (root) |file| size += try inventory.entryCost((try file.stat(io)).size);
    if (branches) |file| size += try inventory.entryCost((try file.stat(io)).size);
    if (size > wire.max_bundle or list.cost > wire.max_bundle - size) return error.TooLarge;
    const output = try spool.file();
    errdefer output.close(io);
    var out_buffer: [65536]u8 = undefined;
    var out = output.writer(io, &out_buffer);
    var state_buffer: [65536]u8 = undefined;
    var state_reader = state.reader(io, &state_buffer);
    var root_buffer: [65536]u8 = undefined;
    var branch_buffer: [65536]u8 = undefined;
    var root_reader = if (root) |file| file.reader(io, &root_buffer) else undefined;
    var branch_reader = if (branches) |file| file.reader(io, &branch_buffer) else undefined;
    const recorded: ?bundle.writer.Recording = if (root) |file| .{
        .root = .{ .reader = &root_reader.interface, .size = (try file.stat(io)).size },
        .branches = .{ .reader = &branch_reader.interface, .size = (try branches.?.stat(io)).size },
    } else null;
    var writer = try bundle.writer.Writer.init(&out.interface, metadata, .{
        .reader = &state_reader.interface,
        .size = (try state.stat(io)).size,
    }, recorded);
    for (list.entries.items) |entry| {
        try inventory.append(&writer, source, entry);
    }
    try writer.finish();
    try out.interface.flush();
    if ((try output.stat(io)).size != size + list.cost) return error.SourceChanged;
    return output;
}

fn writeState(context: *anyopaque, writer: *std.Io.Writer) anyerror!void {
    const files: *session.board.state.Files = @ptrCast(@alignCast(context));
    try files.writeTo(writer);
}

fn writeRoot(context: *anyopaque, writer: *std.Io.Writer) anyerror!void {
    const root: *session.history_root.Root = @ptrCast(@alignCast(context));
    try session.history_root.encode(root, writer);
}

fn writeGraph(context: *anyopaque, writer: *std.Io.Writer) anyerror!void {
    const graph: *session.history_branch.BranchGraph = @ptrCast(@alignCast(context));
    try session.history_branches_codec.encode(graph, writer);
}
