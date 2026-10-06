const std = @import("std");
const ra8 = @import("ra8");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const image = if (args.len > 1) args[1] else "../fixtures/plug/gauge_poll.elf";
    const input: ?[]const u8 = if (args.len > 2) args[2] else null;
    var opened = try ra8.harness.open(allocator, .{ .elf_path = image, .input_script = input });
    defer opened.deinit();
    if (input == null) {
        if (opened.session().currentCore() != .cpu0) return error.WrongCore;
        try std.io.getStdOut().writer().writeAll("harness: opened CPU0\n");
        return;
    }
    try smokeFrames(allocator, &opened, if (args.len > 3) args[3] else null);
}

fn smokeFrames(allocator: std.mem.Allocator, opened: *ra8.harness.Harness, output: ?[]const u8) !void {
    try opened.session().waitSettled(2_000_000_000);
    var before = try opened.session().frame(allocator);
    defer before.deinit(allocator);
    try opened.session().waitSettled(2_000_000_000);
    var after = try opened.session().frame(allocator);
    defer after.deinit(allocator);
    if (before.width != after.width or before.height != after.height) return error.FrameShapeChanged;
    if (std.mem.eql(u8, before.pixels, after.pixels)) return error.FrameDidNotChange;
    if (output) |directory| {
        try save(allocator, directory, "frame_00000.ppm", &before);
        try save(allocator, directory, "frame_00001.ppm", &after);
    }
    try std.io.getStdOut().writer().print("harness: {d}x{d}, frames at {d} and {d} ns\n", .{ before.width, before.height, before.virtual_ns, after.virtual_ns });
}

fn save(allocator: std.mem.Allocator, directory: []const u8, name: []const u8, frame: anytype) !void {
    try std.fs.cwd().makePath(directory);
    const path = try std.fs.path.join(allocator, &.{ directory, name });
    defer allocator.free(path);
    const ppm = try frame.ppm(allocator);
    defer allocator.free(ppm);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = ppm });
}
