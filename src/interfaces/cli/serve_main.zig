//! `ra8_emulator serve` (RA8EMU-737, RA8EMU-736): a headless session server.
//!
//! It opens the ELF through the public harness and answers session RPC
//! frames on stdin/stdout (--stdio) or on one socket client at a time
//! (--listen). Frames are the only thing written to stdout; complaints go
//! to stderr.
const std = @import("std");
const harness = @import("../../harness.zig");
const board_rtc = @import("../../board/session_rtc.zig");
const board_periph = @import("../../board/session_periph.zig");
const proto = @import("../rpc/session_rpc.zig");
const served = @import("../rpc/session_server.zig");
const loop = @import("serve_loop.zig");
const listen = @import("serve_listen.zig");
const session_plug = @import("../../board/session_plug.zig");
const camera_install = @import("../../board/camera_install.zig");
const camera_registry = @import("../../periph/camera/camera_registry.zig");
const Board = @import("../../board/board.zig").Board;
const session_api = @import("../../debug/session_api.zig");
const region_map = @import("../../debug/region_map.zig");
const region_map_json = @import("../../debug/region_map_json.zig");
const map_main = @import("map_main.zig");

pub const usage =
    \\usage: ra8_emulator serve --stdio <firmware.elf>
    \\       ra8_emulator serve --listen unix:PATH|tcp:[HOST]:PORT <firmware.elf>
    \\
;

const Where = union(enum) { stdio, listen: listen.Spec };
const Asked = struct { where: Where, elf: []const u8 };

/// The transport and image `argv` asks for, or null for a malformed line.
fn parse(argv: []const []const u8) ?Asked {
    if (argv.len == 4 and std.mem.eql(u8, argv[2], "--stdio")) return .{ .where = .stdio, .elf = argv[3] };
    if (argv.len != 5 or !std.mem.eql(u8, argv[2], "--listen")) return null;
    const spec = listen.Spec.parse(argv[3]) catch return null;
    return .{ .where = .{ .listen = spec }, .elf = argv[4] };
}

/// Serve `argv` (`ra8_emulator serve ...`) and return the exit code.
pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    const asked = parse(argv) orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    var owner = harness.open(allocator, io, .{ .elf_path = asked.elf }) catch |err| {
        std.debug.print("serve: cannot open {s}: {s}\n", .{ asked.elf, @errorName(err) });
        return 1;
    };
    defer owner.deinit();
    const Env = served.Server.Env;
    const buffers: loop.Buffers = .{
        .rx = try allocator.alloc(u8, 2 * Env.max_frame),
        .tx = try allocator.alloc(u8, Env.max_frame),
    };
    var context: served.Context = .{ .session = owner.session(), .scratch = try allocator.alloc(u8, proto.max_payload), .state = owner.stateFiles(), .gpa = allocator };
    context.listing = .{ .context = owner.plugs(), .listFn = listParts };
    var camera: Camera = .{ .board = owner.board(), .allocator = allocator, .io = io };
    context.camera = .{ .context = &camera, .setFn = Camera.set };
    context.mapping = .{ .context = &owner, .mapFn = mapImage, .stackFn = stackOf };
    context.clock = board_rtc.clock(owner.board());
    context.peripherals = .{ .context = owner.board(), .listFn = board_periph.listBoard };
    const done = switch (asked.where) {
        .stdio => loop.answerStdio(&context, buffers),
        .listen => |spec| listen.serve(io, spec, &context, buffers),
    };
    done catch |err| {
        std.debug.print("serve: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn listParts(context: *anyopaque, out: []u8) anyerror![]const u8 {
    const plugs: *session_plug.Plugs = @ptrCast(@alignCast(context));
    return plugs.list(out);
}

/// The map of a core's last loaded image, as `--map` text or JSON.
fn mapImage(context: *anyopaque, core: usize, json: bool, out: []u8) anyerror![]const u8 {
    const owner: *harness.Harness = @ptrCast(@alignCast(context));
    const which: session_api.Core = if (core == 0) .cpu0 else .cpu1;
    const image = owner.loadedImage(which) orelse return error.NoImage;
    var w: std.Io.Writer = .fixed(out);
    if (json) {
        try region_map_json.write(&w, image, &region_map.ek_ra8d2);
    } else {
        try map_main.render(&w, image, &region_map.ek_ra8d2);
    }
    return w.buffered();
}

/// The main stack reservation of a core's last loaded image, if it names one.
fn stackOf(context: *anyopaque, core: usize) ?region_map.Stack {
    const owner: *harness.Harness = @ptrCast(@alignCast(context));
    const which: session_api.Core = if (core == 0) .cpu0 else .cpu1;
    const image = owner.loadedImage(which) orelse return null;
    return region_map.stackOf(image, &region_map.ek_ra8d2);
}

/// The board, allocator and io set_camera_source opens sources with.
const Camera = struct {
    board: *Board,
    allocator: std.mem.Allocator,
    io: std.Io,

    fn set(context: *anyopaque, spec: camera_registry.Spec) anyerror!void {
        const self: *Camera = @ptrCast(@alignCast(context));
        try camera_install.install(self.board, self.allocator, self.io, spec);
    }
};
