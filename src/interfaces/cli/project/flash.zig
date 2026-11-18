//! Headless build -> receipt verification -> selected-device flash/verify ->
//! optional reset and UART capture (`ra8_emulator project flash ...`).
const std = @import("std");

const ctl_client = @import("../ctl/client.zig");
const host = @import("ra8_host");
const Spec = @import("../serve/listen.zig").Spec;
const target_ctl = @import("../ctl/targets.zig");
const wire = @import("ra8_rpc").targets_wire;

pub const Args = struct {
    root: []const u8,
    config: []const u8,
    recipe: []const u8,
    connect: Spec,
    selection: wire.Selection,
    compiler: ?[]const u8 = null,
    cache: ?[]const u8 = null,
    reset: bool = false,
    uart: bool = false,
};

const Raw = struct {
    connect: ?Spec = null,
    selection: ?wire.Selection = null,
    compiler: ?[]const u8 = null,
    cache: ?[]const u8 = null,
    reset: bool = false,
    uart: bool = false,
};

pub fn parse(argv: []const []const u8) !Args {
    if (argv.len < 14 or !std.mem.eql(u8, argv[2], "flash")) return error.BadArguments;
    var raw: Raw = .{};
    var index: usize = 6;
    while (index < argv.len) {
        index += try stepFlag(&raw, argv[index..]);
    }
    return .{
        .root = argv[3],
        .config = argv[4],
        .recipe = argv[5],
        .connect = raw.connect orelse return error.BadArguments,
        .selection = raw.selection orelse return error.BadArguments,
        .compiler = raw.compiler,
        .cache = raw.cache,
        .reset = raw.reset,
        .uart = raw.uart,
    };
}

fn stepFlag(raw: *Raw, tail: []const []const u8) !usize {
    const flag = tail[0];
    if (std.mem.eql(u8, flag, "--reset") and !raw.reset) {
        raw.reset = true;
        return 1;
    }
    if (std.mem.eql(u8, flag, "--uart") and !raw.uart) {
        raw.uart = true;
        return 1;
    }
    if (std.mem.eql(u8, flag, "--target") and raw.selection == null) {
        raw.selection = try parseTarget(tail);
        return 6;
    }
    if (tail.len < 2) return error.BadArguments;
    return stepPair(raw, flag, tail[1]);
}

fn stepPair(raw: *Raw, flag: []const u8, value: []const u8) !usize {
    if (std.mem.eql(u8, flag, "--connect") and raw.connect == null) {
        raw.connect = try Spec.parse(value);
        return 2;
    }
    if (std.mem.eql(u8, flag, "--zig") and raw.compiler == null) {
        try host.build.Runner.validateCompiler(value);
        raw.compiler = value;
        return 2;
    }
    if (std.mem.eql(u8, flag, "--toolchain-cache") and raw.cache == null) {
        try host.build.Runner.validateCompiler(value);
        raw.cache = value;
        return 2;
    }
    return error.BadArguments;
}

fn parseTarget(tail: []const []const u8) !wire.Selection {
    if (tail.len < 6) return error.BadArguments;
    const gen = try std.fmt.parseInt(u64, tail[4], 10);
    if (gen == 0) return error.BadArguments;
    return .{
        .host_id = tail[1],
        .probe_id = tail[2],
        .board_id = tail[3],
        .generation = gen,
        .disambiguation = if (std.mem.eql(u8, tail[5], "-")) "" else tail[5],
    };
}

pub fn execute(allocator: std.mem.Allocator, io: std.Io, args: Args) !void {
    var base = try host.workspace.Workspace.open(io, args.root);
    defer base.close();
    var project: host.project.Project = .{
        .allocator = allocator,
        .base = &base,
        .backend_compiler = args.compiler orelse "",
        .toolchain_cache = args.cache,
    };
    defer project.close();
    try project.open(args.config);
    if (!std.mem.eql(u8, project.parsed.?.value.target, args.selection.board_id)) {
        return error.TargetProfileMismatch;
    }

    const prepared = try buildAndPrepare(&project, args.recipe);
    const elf = try project.load(prepared.receipt);
    defer allocator.free(elf);

    const client = try ctl_client.Client.open(allocator, io, .{ .socket = args.connect });
    defer client.close();
    const hw = try target_ctl.flashElfCall(allocator, client, args.selection, elf, args.reset, args.uart);
    defer allocator.free(hw);

    var buffer: [8192]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    try writer.interface.print("{{\"version\":1,\"build_id\":{d},\"receipt\":", .{prepared.id});
    try std.json.Stringify.encodeJsonString(prepared.receipt, .{}, &writer.interface);
    try writer.interface.print(",\"target\":", .{});
    try std.json.Stringify.encodeJsonString(project.parsed.?.value.target, .{}, &writer.interface);
    try writer.interface.print(",\"hardware\":{s}}}\n", .{hw});
    try writer.interface.flush();
}

const Built = struct { id: u64, receipt: []const u8 };

fn buildAndPrepare(project: *host.project.Project, recipe: []const u8) !Built {
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
    const receipt_path = project.prepare(id) catch |err| {
        try std.Io.File.stderr().writeStreamingAll(project.base.io, job.result[0..job.result_len]);
        try std.Io.File.stderr().writeStreamingAll(project.base.io, "\n");
        return err;
    };
    return .{ .id = id, .receipt = receipt_path };
}
