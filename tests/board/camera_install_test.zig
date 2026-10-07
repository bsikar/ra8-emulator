//! Covers src/board/camera_install.zig (RA8EMU-795): a spec that opens
//! replaces the CEU's source and closes the old one; one that cannot be
//! opened leaves the old source in place and open.
const std = @import("std");
const ra8 = @import("ra8");

const Board = ra8.board.Board;
const install = ra8.board.camera_install.install;
const registry = ra8.periph.ceu.camera.registry;
const FrameSource = ra8.periph.ceu.camera.frame_source.FrameSource;
const Shape = ra8.periph.ceu.camera.frame_source.Shape;

const Stub = struct {
    closed: u32 = 0,

    fn frame(_: *anyopaque, _: u64, _: Shape) void {}
    fn fill(_: *anyopaque, _: u32, _: u32, out: []u8) void {
        @memset(out, 0);
    }
    fn close(context: *anyopaque) void {
        const self: *Stub = @ptrCast(@alignCast(context));
        self.closed += 1;
    }
    const vtable: FrameSource.VTable = .{ .frame = frame, .fill = fill, .close = close };

    fn source(self: *Stub) FrameSource {
        return .{ .context = self, .vtable = &vtable, .label = "stub" };
    }
};

test "a spec that opens replaces the source and closes the old one" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var stub: Stub = .{};
    board.capture.source = stub.source();
    try install(&board, std.testing.allocator, std.testing.io, try registry.parse("gradient"));
    try std.testing.expectEqual(@as(u32, 1), stub.closed);
    try std.testing.expectEqualStrings("synthetic gradient", board.capture.source.label);
}

test "a spec that cannot be opened keeps the old source open" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var stub: Stub = .{};
    board.capture.source = stub.source();
    const missing = try registry.parse("image:/nonexistent/ra8emu-795.png");
    try std.testing.expect(std.meta.isError(install(&board, std.testing.allocator, std.testing.io, missing)));
    try std.testing.expectEqual(@as(u32, 0), stub.closed);
    try std.testing.expectEqualStrings("stub", board.capture.source.label);
    board.capture.source = (registry.Spec{}).open(std.testing.allocator, std.testing.io, &board.wire.sensor.format) catch unreachable;
}
