//! Match a recorded compiler invocation to the selected project recipe.
const std = @import("std");

const config = @import("config.zig");
const receipt = @import("receipt.zig");
const request = @import("../build/request.zig");

pub fn verify(
    allocator: std.mem.Allocator,
    recipe: config.Recipe,
    value: receipt.Receipt,
    original: receipt.Record,
    compiler: []const u8,
) !void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const selected = try request.parse(arena.allocator(), recipe.request());
    if (!std.mem.eql(u8, selected.step, original.step)) return error.InvalidBuildReceipt;
    try same(selected.options, original.options);

    var buffer: [1024]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&buffer, "{s}/out", .{value.directory});
    const fixed = [_][]const u8{
        value.compiler,
        "build",
        "-j1",
        "--color=off",
        "--prefix",
        prefix,
        "--build-file",
        "build.zig",
    };
    const has_step: usize = @intFromBool(selected.step.len != 0);
    if (original.argv.len != fixed.len + has_step + selected.options.len) return error.InvalidBuildReceipt;
    try same(&fixed, original.argv[0..fixed.len]);

    if (has_step != 0 and !std.mem.eql(u8, original.argv[fixed.len], selected.step)) {
        return error.InvalidBuildReceipt;
    }
    try same(selected.options, original.argv[fixed.len + has_step ..]);

    const artifact = try std.fmt.bufPrint(&buffer, "{s}/out/{s}", .{ value.directory, selected.artifact });
    if (!std.mem.eql(u8, artifact, value.artifact) or !std.mem.eql(u8, value.compiler, compiler)) {
        return error.InvalidBuildReceipt;
    }
}

fn same(wanted: []const []const u8, actual: []const []const u8) !void {
    if (wanted.len != actual.len) return error.InvalidBuildReceipt;
    for (wanted, actual) |asked, built| {
        if (!std.mem.eql(u8, asked, built)) return error.InvalidBuildReceipt;
    }
}
