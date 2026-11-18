//! Headless project builds, receipt-only DAP, and build/flash/run orchestration.
const std = @import("std");

const dap = @import("ra8_dap");
pub const flash = @import("flash.zig");
const host = @import("ra8_host");
const listener = @import("../root.zig").dap;
pub const Owner = @import("owner.zig").Owner;

pub const usage = "usage: ra8_emulator project build ROOT CONFIG RECIPE " ++
    "[--zig ABSOLUTE_PATH] [--toolchain-cache ABSOLUTE_PATH]\n" ++
    "       ra8_emulator project dap PORT ROOT CONFIG [--zig ABSOLUTE_PATH] [--toolchain-cache ABSOLUTE_PATH]\n" ++
    "       ra8_emulator project flash ROOT CONFIG RECIPE --connect ADDR " ++
    "--target HOST_ID PROBE_ID BOARD_ID GEN DISAMBIG " ++
    "[--zig ABSOLUTE_PATH] [--toolchain-cache ABSOLUTE_PATH] [--reset] [--uart]\n";

pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    perform(allocator, io, argv) catch |err| {
        std.debug.print("project: {s}\n{s}", .{ @errorName(err), usage });
        return 1;
    };
    return 0;
}

const ToolFlags = struct { compiler: ?[]const u8 = null, cache: ?[]const u8 = null };

fn parseToolFlags(tail: []const []const u8) !ToolFlags {
    var out: ToolFlags = .{};
    var at: usize = 0;
    while (at < tail.len) : (at += 2) {
        if (std.mem.eql(u8, tail[at], "--zig") and out.compiler == null) {
            try host.build.Runner.validateCompiler(tail[at + 1]);
            out.compiler = tail[at + 1];
        } else if (std.mem.eql(u8, tail[at], "--toolchain-cache") and out.cache == null) {
            try host.build.Runner.validateCompiler(tail[at + 1]);
            out.cache = tail[at + 1];
        } else return error.BadArguments;
    }
    return out;
}

fn perform(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    if (argv.len >= 3 and std.mem.eql(u8, argv[2], "flash")) {
        return flash.execute(allocator, io, try flash.parse(argv));
    }
    if (argv.len < 6 or argv.len > 10 or argv.len % 2 != 0) return error.BadArguments;
    const build = std.mem.eql(u8, argv[2], "build");
    if (!build and !std.mem.eql(u8, argv[2], "dap")) return error.BadArguments;
    const tools = try parseToolFlags(argv[6..]);
    var base = try host.workspace.Workspace.open(io, argv[if (build) 3 else 4]);
    defer base.close();
    var project: host.project.Project = .{
        .allocator = allocator,
        .base = &base,
        .backend_compiler = tools.compiler orelse "",
        .toolchain_cache = tools.cache,
    };
    defer project.close();
    try project.open(argv[if (build) 4 else 5]);
    if (build) return buildProject(&project, argv[5]);
    const port = try std.fmt.parseInt(u16, argv[3], 10);
    var owner: Owner = .{ .project = &project };
    defer owner.close();
    var adapter: dap.adapter.Adapter = .{
        .allocator = allocator,
        .opener = .{ .context = &owner, .openFn = Owner.open },
    };
    defer adapter.deinit();
    try listener.listen(allocator, io, port, &adapter);
}

fn buildProject(project: *host.project.Project, recipe: []const u8) !void {
    host.stops.reset();
    try host.stops.install();
    defer host.stops.uninstall();
    defer host.stops.finished();
    const id = try project.start(recipe);
    const job = try project.runner.?.get(id);
    while (!job.done.load(.acquire)) {
        if (host.stops.requested()) try project.runner.?.cancel(id);
        try std.Io.sleep(project.base.io, .fromMilliseconds(5), .awake);
    }
    const path = project.prepare(id) catch |err| {
        try std.Io.File.stderr().writeStreamingAll(project.base.io, job.result[0..job.result_len]);
        try std.Io.File.stderr().writeStreamingAll(project.base.io, "\n");
        return err;
    };
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(project.base.io, &buffer);
    try std.json.Stringify.value(
        .{ .version = 1, .build_id = id, .receipt = path, .target = project.parsed.?.value.target },
        .{},
        &writer.interface,
    );
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}
