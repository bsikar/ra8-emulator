//! Export the versioned toolchain decision and per-host/per-target preflight plan.
const std = @import("std");
const plan = @import("ra8_host").toolchain.plan;
const usage = "usage: ra8_emulator toolchain plan HOST TARGET [--project-zig PATH] [--backend-zig PATH] [--cache-root PATH] [--offline]\n";

pub fn parse(argv: []const []const u8) !plan.Request {
    if (argv.len < 5 or !std.mem.eql(u8, argv[1], "toolchain") or !std.mem.eql(u8, argv[2], "plan")) return error.BadArguments;
    var request: plan.Request = .{ .host = argv[3], .target = argv[4] };
    var at: usize = 5;
    while (at < argv.len) : (at += 1) {
        const flag = argv[at];
        if (std.mem.eql(u8, flag, "--offline") and !request.offline) {
            request.offline = true;
            continue;
        }
        if (at + 1 >= argv.len) return error.BadArguments;
        const value = argv[at + 1];
        if (std.mem.eql(u8, flag, "--project-zig") and request.project_zig == null) {
            request.project_zig = value;
        } else if (std.mem.eql(u8, flag, "--backend-zig") and request.backend_zig == null) {
            request.backend_zig = value;
        } else if (std.mem.eql(u8, flag, "--cache-root") and request.cache_root == null) {
            request.cache_root = value;
        } else return error.BadArguments;
        at += 1;
    }
    return request;
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    const request = parse(argv) catch {
        try std.Io.File.stderr().writeStreamingAll(io, usage);
        return 2;
    };
    const result = plan.make(allocator, request) catch |err| {
        std.debug.print("toolchain: {s}\n", .{@errorName(err)});
        return 2;
    };
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(io, &buffer);
    try std.json.Stringify.value(result, .{ .whitespace = .indent_2 }, &output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
    return 0;
}
