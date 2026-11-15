//! Small real recording, archived while its source session still owns the lease.
const std = @import("std");
const ra8 = @import("ra8");

const bundle = ra8.snapshot.bundle;
const history = ra8.host.history;
const rig = @import("../regression_rig.zig");
const gpa = std.testing.allocator;
pub const elf = @embedFile("../../../fixtures/gpio/blink.elf");

pub const Archive = struct {
    bytes: std.Io.Writer.Allocating,
    retired: u64,
    position: ra8.session.history_position.Position,

    pub fn deinit(self: *Archive) void {
        self.bytes.deinit();
    }
};

pub fn metadata() bundle.manifest.Metadata {
    return .{ .board = "ek-ra8d2", .elf0 = .{
        .name = "blink.elf",
        .identity = ra8.session.history_root.identity(elf),
        .size = elf.len,
    } };
}

pub fn recording(bad_log: bool) !Archive {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(path);
    var original: ra8.rpc.served_setup.Served = undefined;
    try original.openInitial(gpa, std.testing.io, "", rig.small_profile, .{ .root = path, .elf_bytes = elf, .checkpoint_every = 1 }, null);
    defer original.deinit();
    try original.owner.session().setRunBudget(.cpu0, 40_000);
    _ = try original.owner.session().run(.cpu0, .run);
    try original.flushHistory();
    const bind = original.history.?;
    const store = history.storage.Store.from(&bind.session);
    if (bad_log) {
        const log = try store.vtable.open(store.context, .log, "events-0", .update);
        defer log.vtable.close(log.context);
        try log.vtable.write(log.context, try log.vtable.length(log.context), "torn");
        try log.vtable.sync(log.context);
    }
    var state = std.Io.Writer.Allocating.init(gpa);
    defer state.deinit();
    try original.owner.state.files.writeTo(&state.writer);
    const root = try ra8.rpc.object_read.readTopRoot(store, gpa);
    defer gpa.free(root);
    const branches = try ra8.session.history_branches_codec.encodeAlloc(&bind.graph, gpa);
    defer gpa.free(branches);
    var state_reader = std.Io.Reader.fixed(state.written());
    var root_reader = std.Io.Reader.fixed(root);
    var branch_reader = std.Io.Reader.fixed(branches);
    var result: Archive = .{ .bytes = .init(gpa), .retired = original.owner.primaryCpu().retired, .position = original.owner.session().currentPosition() };
    errdefer result.deinit();
    var writer = try bundle.writer.Writer.init(&result.bytes.writer, metadata(), .{ .reader = &state_reader, .size = state.written().len }, .{
        .root = .{ .reader = &root_reader, .size = root.len },
        .branches = .{ .reader = &branch_reader, .size = branches.len },
    });
    try space(&writer, store, .log);
    try space(&writer, store, .objects);
    try writer.finish();
    return result;
}

const Names = struct {
    items: std.ArrayList([]const u8) = .empty,

    fn visit(context: *anyopaque, name: []const u8, size: u64) anyerror!void {
        _ = size;
        const self: *Names = @ptrCast(@alignCast(context));
        const copy = try gpa.dupe(u8, name);
        errdefer gpa.free(copy);
        try self.items.append(gpa, copy);
    }

    fn less(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }
};

fn space(writer: *bundle.writer.Writer, store: history.storage.Store, area: history.layout.Space) !void {
    var names: Names = .{};
    defer {
        for (names.items.items) |name| {
            gpa.free(name);
        }
        names.items.deinit(gpa);
    }
    try store.vtable.list(store.context, area, .{ .context = &names, .visit = Names.visit });
    std.mem.sort([]const u8, names.items.items, {}, Names.less);
    for (names.items.items) |name| {
        const byte = try store.vtable.open(store.context, area, name, .read);
        defer byte.vtable.close(byte.context);
        const held: *history.session.Session = @ptrCast(@alignCast(store.context));
        const file = try history.storage.native(byte);
        var buffer: [65536]u8 = undefined;
        var reader = file.readerStreaming(held.base.io, &buffer);
        try writer.add(if (area == .log) .log else .objects, name, .{ .reader = &reader.interface, .size = try byte.vtable.length(byte.context) });
    }
}
