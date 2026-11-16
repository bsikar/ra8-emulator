//! Explicit provisioning and network-free doctor/resolution; never implicit setup.
const std = @import("std");

const toolchain = @import("ra8_host").toolchain;

pub const Asked = struct { setup: bool, request: toolchain.provision.Request };

pub fn parse(argv: []const []const u8) !Asked {
    if (argv.len < 5 or !std.mem.eql(u8, argv[1], "toolchain")) return error.BadArguments;
    const setup = std.mem.eql(u8, argv[2], "setup");
    if (!setup and !std.mem.eql(u8, argv[2], "doctor")) return error.BadArguments;
    var asked: Asked = .{ .setup = setup, .request = .{ .plan = .{ .host = argv[3], .target = argv[4] } } };
    var at: usize = 5;
    while (at < argv.len) : (at += 1) {
        try flag(&asked, argv, &at);
    }
    if (asked.request.download and (asked.request.plan.offline or asked.request.archive_path != null)) {
        return error.SetupPolicyConflict;
    }
    return asked;
}

fn flag(asked: *Asked, argv: []const []const u8, at: *usize) !void {
    const name = argv[at.*];
    if (std.mem.eql(u8, name, "--offline") and !asked.request.plan.offline) {
        asked.request.plan.offline = true;
        return;
    }
    if (std.mem.eql(u8, name, "--download") and asked.setup and !asked.request.download) {
        asked.request.download = true;
        return;
    }
    if (at.* + 1 >= argv.len) return error.BadArguments;
    const slot: *?[]const u8 = if (std.mem.eql(u8, name, "--cache-root"))
        &asked.request.plan.cache_root
    else if (std.mem.eql(u8, name, "--project-zig"))
        &asked.request.plan.project_zig
    else if (std.mem.eql(u8, name, "--backend-zig"))
        &asked.request.plan.backend_zig
    else if (std.mem.eql(u8, name, "--archive") and asked.setup)
        &asked.request.archive_path
    else
        return error.BadArguments;
    if (slot.* != null) return error.BadArguments;
    at.* += 1;
    slot.* = argv[at.*];
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    const asked = parse(argv) catch |err| return fail(err);
    const result = (if (asked.setup)
        toolchain.provision.setup(allocator, io, asked.request)
    else
        toolchain.provision.resolve(allocator, io, asked.request.plan)) catch |err| return fail(err);
    defer allocator.free(result.compiler_path);
    const target = try toolchain.target.find(asked.request.plan.target);
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(io, &buffer);
    try std.json.Stringify.value(.{
        .compiler = result,
        .target = target,
        .scope = "Only the approved pinned Zig baseline is managed. Vendor SDK, probe/flash, driver and NPU " ++
            "requirements remain target-specific and unsupported by setup until pinned and approved.",
    }, .{ .whitespace = .indent_2 }, &output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
    return 0;
}

fn fail(err: anyerror) u8 {
    std.debug.print("toolchain: {s}; setup needs --cache-root ABS and either --archive ABS " ++
        "(offline kit) or explicit --download; doctor/build never download. " ++
        "Invalid explicit compilers never fall back.\n", .{@errorName(err)});
    return 2;
}
