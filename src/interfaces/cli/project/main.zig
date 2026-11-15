//! Headless project builds and receipt-only DAP, sharing the RPC host service.
const std = @import("std");

const dap = @import("ra8_dap");
const host = @import("ra8_host");
const listener = @import("../root.zig").dap;
pub const Owner = @import("owner.zig").Owner;

pub const usage = "usage: ra8_emulator project build ROOT CONFIG RECIPE [--zig ABSOLUTE_PATH]\n" ++
    "       ra8_emulator project dap PORT ROOT CONFIG [--zig ABSOLUTE_PATH]\n";

pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    perform(allocator, io, argv) catch |err| {
        std.debug.print("project: {s}\n{s}", .{ @errorName(err), usage });
        return 1;
    };
    return 0;
}

fn perform(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    if (argv.len != 6 and argv.len != 8) return error.BadArguments;
    const build = std.mem.eql(u8, argv[2], "build");
    if (!build and !std.mem.eql(u8, argv[2], "dap")) return error.BadArguments;
    var compiler: []const u8 = "";
    if (argv.len == 8) {
        if (!std.mem.eql(u8, argv[6], "--zig")) return error.BadArguments;
        compiler = argv[7];
    }
    var base = try host.workspace.Workspace.open(io, argv[if (build) 3 else 4]);
    defer base.close();
    var project: host.project.Project = .{ .allocator = allocator, .base = &base, .backend_compiler = compiler };
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
