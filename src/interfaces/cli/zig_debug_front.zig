//! The debugger on the Zig core (RA8EMU-117): `--cpu zig` with
//! `--debug-script` or `--debug`. The image is loaded and the board
//! attached as the front end in src/interfaces/cli/debug_front.zig asks;
//! the Zig core then resets out of the same vector table on the board's bus,
//! as src/core/cpu/boot.zig runOnBoard does, and src/debug/zig_script.zig
//! carries the commands out. `--gdb` serves gdb from the same Zig session
//! (RA8EMU-118). `--cpu1` beside it brings CPU1 up on its own Zig core,
//! and `core 0|1` switches between them (RA8EMU-337); `--gdb` serves it as
//! thread 2 (RA8EMU-338).
//! CPU0 runs on its own store
//! (src/interfaces/cli/zig_memory.zig) and CPU1 on one that borrows its SRAM.
const std = @import("std");
const elf = @import("../../core/elf.zig");
const BoardBus = @import("../../core/cpu/board_bus.zig").BoardBus;
const cpu_mod = @import("../../core/cpu/cpu.zig");
const NvicSource = @import("../../core/cpu/exception/nvic_source.zig").NvicSource;
const Board = @import("../../board/board.zig").Board;
const script = @import("../../debug/script.zig");
const session = @import("../../debug/session.zig");
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
const Cpu0 = @import("zig_memory.zig").Cpu0;

const LoaderState = struct {
    cpu0: *cpu_mod.Cpu,
    memory0: Guest,
    cpu1: ?*cpu_mod.Cpu = null,
    memory1: ?Guest = null,

    fn load(context: *anyopaque, core: session_api.Core, bytes: []const u8) anyerror!void {
        const self: *LoaderState = @ptrCast(@alignCast(context));
        const image = try elf.Image.init(bytes);
        const target = switch (core) {
            .cpu0 => .{ self.cpu0, self.memory0 },
            .cpu1 => .{ self.cpu1 orelse return error.CoreNotAttached, self.memory1 orelse return error.CoreNotAttached },
        };
        const cpu = target[0];
        const memory = target[1];
        var index: u16 = 0;
        while (index < image.segmentCount()) : (index += 1) {
            const segment = image.loadSegment(index) orelse continue;
            try memory.write(segment.paddr, segment.bytes);
        }
        const vector = image.vectorBase() orelse return error.NoVectorTable;
        try cpu.reset(vector);
    }
};

/// Why a request cannot run on the Zig core's debugger yet, or null when it can.
pub fn refusal(request: debug_front.Request) ?[]const u8 {
    if (request.cpu != .zig) return "the debugger runs on --cpu zig";
    return null;
}

/// Load `image`, reset the Zig core into it on the board's bus, and run the
/// mode asked for, printing to `out`.
pub fn run(allocator: std.mem.Allocator, image: elf.Image, request: debug_front.Request, out: anytype) !u8 {
    if (refusal(request)) |why| {
        std.debug.print("{s}\n", .{why});
        return 2;
    }
    var board = Board.init(allocator);
    defer board.deinit();
    var cpu0: Cpu0 = .{};
    defer cpu0.close();
    _ = try cpu0.attachStore(&board, image);
    const vector_base = image.vectorBase() orelse {
        std.debug.print("no executable segment, nothing to reset into\n", .{});
        return 1;
    };
    var memory: BoardBus = .{ .memory = .{ .store = .{ .store = &cpu0.store.? } }, .periph = &board.bus, .scs = .{ .partitions = &board.partitions, .regions = &board.regions, .clears = &board.clears } };
    var machine: stop_machine.Machine = .{};
    var driver: step_hook.Driver = .{ .machine = &machine };
    var watching: watch_bus.WatchBus = .{ .inner = memory.view(), .driver = &driver };
    var cpu: cpu_mod.Cpu = .{ .bus = watching.view() };
    var pending: NvicSource = .{};
    cpu.source = pending.source();
    pending.banked = &cpu.banked;
    cpu.reset(vector_base) catch {
        std.debug.print("zig core: no vector table at 0x{X:0>8}\n", .{vector_base});
        return 1;
    };
    var target: zig_script.ZigScript = .{ .image = image, .session = .{ .live = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = session.limits.default_budget, .watch = &watching } } };
    target.session.attachInputScript(&board.input_script);
    var loading: LoaderState = .{ .cpu0 = &cpu, .memory0 = cpu0.own() };
    target.session.attachLoader(.{ .context = &loading, .loadFn = LoaderState.load });
    try target.session.load(.cpu0, image.bytes);
    var pair: second_core.zig_run.Driver = undefined;
    var other: Other = .{};
    const named = request.cpu1 orelse return serve(allocator, &target, request.mode, out);
    other.open(allocator, &pair, cpu0.own(), &board, named, &target, &loading) catch |err| {
        std.debug.print("cannot bring up the second core from {s}: {s}\n", .{ named, @errorName(err) });
        return 1;
    };
    defer other.close(allocator, &pair);
    return serve(allocator, &target, request.mode, out);
}

/// gdb on the port, or the script or terminal.
fn serve(allocator: std.mem.Allocator, target: *zig_script.ZigScript, mode: debug_front.Mode, out: anytype) !u8 {
    if (mode == .gdb) return listen(&target.session, mode.gdb);
    return drive(allocator, target, mode, out);
}

/// CPU1 under the debugger: its Zig core, its own stop machine, and its
/// image kept for symbols, parked in the session until `core 1`.
/// Its loads and stores go through a watch bus of its own, so a watch set
/// on thread 2 stops CPU1.
const Other = struct {
    machine: stop_machine.Machine = .{},
    driver: step_hook.Driver = undefined,
    watching: watch_bus.WatchBus = undefined,
    bytes: []u8 = &.{},

    fn open(self: *Other, allocator: std.mem.Allocator, pair: *second_core.zig_run.Driver, cpu0: Guest, board: *Board, path: []const u8, target: *zig_script.ZigScript, loading: *LoaderState) !void {
        self.bytes = try std.fs.cwd().readFileAlloc(allocator, path, second_core.limits.image_bytes);
        errdefer allocator.free(self.bytes);
        try pair.open(allocator, board, path, cpu0);
        target.other_image = try elf.Image.init(self.bytes);
        self.driver = .{ .machine = &self.machine };
        self.watching = .{ .inner = pair.core.cpu.bus, .driver = &self.driver };
        pair.core.cpu.bus = self.watching.view();
        target.session.live.other = .{ .core = .{ .cpu = &pair.core.cpu }, .machine = &self.machine, .watch = &self.watching, .index = 1, .budget = target.session.live.budget };
        loading.cpu1 = &pair.core.cpu;
        loading.memory1 = pair.guest();
        try target.session.load(.cpu1, target.other_image.?.bytes);
    }

    fn close(self: *Other, allocator: std.mem.Allocator, pair: *second_core.zig_run.Driver) void {
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
        .gdb => unreachable, // run sends --gdb to listen
    }
    try target.session.flushItm(target.session.currentCore(), out, true);
    return 0;
}

/// Wait for gdb on the loopback port and serve it from the Zig core
/// (RA8EMU-118).
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
