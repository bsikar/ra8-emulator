//! Window port tests: the port forwards to its binding, and its stream
//! helpers hand back the bytes the binding wrote.

const std = @import("std");
const ra8 = @import("ra8");
const port_mod = ra8.session.history_window_port;

const Fake = struct {
    at: port_mod.Position = .{},
    stepped: usize = 0,
    restored: usize = 0,
    loaded_board: ?bool = null,

    const vtable: port_mod.Port.VTable = .{
        .position = position,
        .line = line,
        .cpu = cpu,
        .step = step,
        .saveFull = saveFull,
        .restoreFull = restoreFull,
        .saveSide = saveSide,
        .loadSide = loadSide,
    };

    fn of(context: *anyopaque) *Fake {
        return @ptrCast(@alignCast(context));
    }
    fn position(context: *anyopaque) port_mod.Position {
        return of(context).at;
    }
    fn line(context: *anyopaque) u32 {
        return of(context).at.branch;
    }
    fn cpu(_: *anyopaque, _: port_mod.Core) ?*port_mod.Cpu {
        return null;
    }
    fn step(context: *anyopaque, _: port_mod.Core) anyerror!void {
        const self = of(context);
        self.stepped += 1;
        self.at.o += 1;
    }
    fn saveFull(_: *anyopaque, writer: *std.Io.Writer) anyerror!void {
        try writer.writeAll("full");
    }
    fn restoreFull(context: *anyopaque, bytes: []const u8) anyerror!void {
        if (!std.mem.eql(u8, bytes, "full")) return error.BadValue;
        of(context).restored += 1;
    }
    fn saveSide(context: *anyopaque, writer: *std.Io.Writer) anyerror!void {
        try writer.print("side{d}", .{of(context).at.o});
    }
    fn loadSide(context: *anyopaque, _: []const u8, board: bool) anyerror!void {
        of(context).loaded_board = board;
    }
};

test "the port forwards to its binding" {
    var fake: Fake = .{ .at = .{ .branch = 3 } };
    const port: port_mod.Port = .{ .context = &fake, .vtable = &Fake.vtable };
    try std.testing.expectEqual(@as(u32, 3), port.line());
    try std.testing.expect(port.cpu(.cpu0) == null);
    try port.step(.cpu1);
    try std.testing.expectEqual(@as(usize, 1), fake.stepped);
    try std.testing.expectEqual(@as(u32, 1), port.position().o);
    try port.restoreFull("full");
    try std.testing.expectEqual(@as(usize, 1), fake.restored);
    try port.loadSide("x", true);
    try std.testing.expectEqual(@as(?bool, true), fake.loaded_board);
}

test "the stream helpers return what the binding wrote" {
    const gpa = std.testing.allocator;
    var fake: Fake = .{};
    const port: port_mod.Port = .{ .context = &fake, .vtable = &Fake.vtable };
    const full = try port.fullBytes(gpa);
    defer gpa.free(full);
    try std.testing.expectEqualStrings("full", full);

    var image: std.ArrayList(u8) = .empty;
    defer image.deinit(gpa);
    try port.sideInto(gpa, &image);
    try std.testing.expectEqualStrings("side0", image.items);
    // A second save replaces the image rather than appending to it.
    try port.step(.cpu0);
    try port.sideInto(gpa, &image);
    try std.testing.expectEqualStrings("side1", image.items);
}
