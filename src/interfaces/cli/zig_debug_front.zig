//! The debugger on the Zig core (RA8EMU-117): `--cpu zig` with
//! `--debug-script` or `--debug`. The public harness owns CPU0 and its board;
//! this front adds the requested debugger mode and optional CPU1.
const std = @import("std");
const elf = @import("../../core/elf.zig");
const cpu_mod = @import("../../core/cpu/cpu.zig");
const Board = @import("../../board/board.zig").Board;
const board_speed = @import("../../board/board_speed.zig");
const pacing = @import("../../periph/time/pacing.zig");
const script = @import("../../debug/script.zig");
const stop_machine = @import("../../debug/stop_machine.zig");
const zig_script = @import("../../debug/zig_script.zig");
const session_api = @import("../../debug/session_api.zig");
const step_hook = @import("../../debug/step_hook.zig");
const watch_bus = @import("../../debug/watch_bus.zig");
const debug_front = @import("debug_front.zig");
const rsp_dispatch = @import("../../debug/rsp_dispatch.zig");
const rsp_poll = @import("../../debug/rsp_poll.zig");
const second_core = @import("../../core/second_core.zig");
const Guest = @import("../../core/cpu/memory/guest.zig").Guest;
const exclusive_peer = @import("../../core/cpu/exclusive_peer.zig");
const harness = @import("../../harness.zig");

/// Why a request cannot run on the Zig core's debugger yet, or null when it can.
pub fn refusal(request: debug_front.Request) ?[]const u8 {
    if (request.cpu != .zig) return "the debugger runs on --cpu zig";
    return null;
}

/// Open `request.image` through the public harness and serve its debugger.
pub fn run(allocator: std.mem.Allocator, request: debug_front.Request, out: anytype) !u8 {
    if (refusal(request)) |why| {
        std.debug.print("{s}\n", .{why});
        return 2;
    }
    var opened = harness.open(allocator, .{ .elf_path = request.image, .device = .ra8d2 }) catch |err| {
        std.debug.print("cannot open {s}: {s}\n", .{ request.image, @errorName(err) });
        return 1;
    };
    defer opened.deinit();
    var target: zig_script.ZigScript = .{ .image = opened.image(), .session = opened.session() };
    var speed: board_speed.BoardSpeed = .{ .time = &opened.board().time, .clock = try pacing.hostClock() };
    target.session.speed = speed.hook();
    var pair: second_core.zig_run.Driver = undefined;
    var other: Other = .{};
    const named = request.cpu1 orelse return serve(allocator, &target, request.mode, out);
    other.open(allocator, &pair, &opened, named, &target) catch |err| {
        std.debug.print("cannot bring up the second core from {s}: {s}\n", .{ named, @errorName(err) });
        return 1;
    };
    defer other.close(allocator, &pair);
    return serve(allocator, &target, request.mode, out);
}

/// gdb on the port, or the script or terminal.
fn serve(allocator: std.mem.Allocator, target: *zig_script.ZigScript, mode: debug_front.Mode, out: anytype) !u8 {
    if (mode == .gdb) return listen(target.session, mode.gdb);
    return drive(allocator, target, mode, out);
}

/// CPU1 under the debugger, parked in the session until `core 1`.
const Other = struct {
    machine: stop_machine.Machine = .{},
    driver: step_hook.Driver = undefined,
    watching: watch_bus.WatchBus = undefined,
    bytes: []u8 = &.{},
    paired: ?*cpu_mod.Cpu = null,

    fn open(self: *Other, allocator: std.mem.Allocator, pair: *second_core.zig_run.Driver, opened: *harness.Harness, path: []const u8, target: *zig_script.ZigScript) !void {
        self.bytes = try std.fs.cwd().readFileAlloc(allocator, path, second_core.limits.image_bytes);
        errdefer allocator.free(self.bytes);
        try pair.open(allocator, opened.board(), path, opened.guest());
        target.other_image = try elf.Image.init(self.bytes);
        self.driver = .{ .machine = &self.machine };
        self.watching = .{ .inner = pair.core.cpu.bus, .driver = &self.driver };
        pair.core.cpu.bus = self.watching.view();
        exclusive_peer.pair(opened.primaryCpu(), &pair.core.cpu);
        self.paired = opened.primaryCpu();
        target.session.live.other = .{ .core = .{ .cpu = &pair.core.cpu }, .machine = &self.machine, .watch = &self.watching, .index = 1, .budget = target.session.live.budget };
        opened.attachCore(.cpu1, &pair.core.cpu, pair.guest());
        opened.bindSecond(&pair.second, pair.guest());
        try target.session.load(.cpu1, target.other_image.?.bytes);
        try target.session.switchTo(.cpu0);
    }

    fn close(self: *Other, allocator: std.mem.Allocator, pair: *second_core.zig_run.Driver) void {
        if (self.paired) |cpu0| exclusive_peer.unpair(cpu0, &pair.core.cpu);
        pair.close();
        allocator.free(self.bytes);
    }
};

/// Play the script or talk to the terminal.
fn drive(allocator: std.mem.Allocator, target: *zig_script.ZigScript, mode: debug_front.Mode, out: anytype) !u8 {
    switch (mode) {
        .script => |path| {
            const text = std.fs.cwd().readFileAlloc(allocator, path, debug_front.limits.max_file) catch |err| {
                std.debug.print("cannot read {s}: {s}\n", .{ path, @errorName(err) });
                return 1;
            };
            defer allocator.free(text);
            _ = try script.play(target, text, out, true);
        },
        .interactive => try debug_front.converse(target, out),
        .gdb => unreachable,
    }
    try target.session.flushItm(target.session.currentCore(), out, true);
    return 0;
}

/// Wait for gdb on the loopback port and serve it from the Zig core.
fn listen(live: *session_api.Session, port: u16) !u8 {
    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    var server = address.listen(.{ .reuse_address = true }) catch |err| {
        std.debug.print("cannot listen on 127.0.0.1:{d}: {s}\n", .{ port, @errorName(err) });
        return 1;
    };
    defer server.deinit();
    std.debug.print("gdb: listening on 127.0.0.1:{d}\n", .{port});
    const connection = try server.accept();
    defer connection.stream.close();
    var socket = rsp_poll.Socket{ .handle = connection.stream.handle };
    try live.setRunBudget(live.currentCore(), rsp_poll.chunk);
    var target: rsp_dispatch.zig_run.Target = .{ .session = live, .poll = socket.poll() };
    const stub = rsp_dispatch.Dispatch{ .zig = &target };
    const end = try rsp_dispatch.server.serve(stub, connection.stream.reader(), connection.stream.writer());
    std.debug.print("gdb: {s}\n", .{@tagName(end)});
    return 0;
}
