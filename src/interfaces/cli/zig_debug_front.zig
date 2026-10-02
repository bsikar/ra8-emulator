//! The debugger on the Zig core (RA8EMU-117): `--cpu zig` with
//! `--debug-script` or `--debug`. The image is loaded and the board
//! attached as for a Unicorn debug session (src/interfaces/cli/debug_front.zig);
//! the Zig core then resets out of the same vector table on the board's bus,
//! as src/core/cpu/boot.zig runOnBoard does, and src/debug/zig_script.zig
//! carries the commands out. `--gdb` serves gdb from the same Zig session
//! (RA8EMU-118). `--cpu1` beside it and `--cpu lockstep` are not debugger
//! targets yet and say so.
const std = @import("std");
const engine = @import("../../core/engine.zig");
const elf = @import("../../core/elf.zig");
const BoardBus = @import("../../core/cpu/board_bus.zig").BoardBus;
const cpu_mod = @import("../../core/cpu/cpu.zig");
const NvicSource = @import("../../core/cpu/exception/nvic_source.zig").NvicSource;
const Board = @import("../../board/board.zig").Board;
const script = @import("../../debug/script.zig");
const session = @import("../../debug/session.zig");
const stop_machine = @import("../../debug/stop_machine.zig");
const zig_script = @import("../../debug/zig_script.zig");
const zig_session = @import("../../debug/zig_session.zig");
const step_hook = @import("../../debug/step_hook.zig");
const watch_bus = @import("../../debug/watch_bus.zig");
const debug_front = @import("debug_front.zig");
const rsp_dispatch = @import("../../debug/rsp_dispatch.zig");
const rsp_poll = @import("../../debug/rsp_poll.zig");

/// Why a request cannot run on the Zig core's debugger yet, or null when it can.
pub fn refusal(request: debug_front.Request) ?[]const u8 {
    if (request.cpu != .zig) return "the debugger runs on --cpu unicorn or --cpu zig";
    if (request.cpu1 != null) return "--cpu1 beside --cpu zig is not in the debugger yet";
    return null;
}

/// Load `image`, reset the Zig core into it on the board's bus, and run the
/// mode asked for, printing to `out`.
pub fn run(allocator: std.mem.Allocator, image: elf.Image, request: debug_front.Request, out: anytype) !u8 {
    if (refusal(request)) |why| {
        std.debug.print("{s}\n", .{why});
        return 2;
    }
    var core = try engine.Engine.open();
    defer core.close();
    try core.mapBoardRam();
    var board = Board.init(allocator);
    defer board.deinit();
    try board.attach(&core);
    _ = try core.loadImage(image);
    const vector_base = image.vectorBase() orelse {
        std.debug.print("no executable segment, nothing to reset into\n", .{});
        return 1;
    };
    var memory: BoardBus = .{ .memory = .{ .core = &core }, .periph = &board.bus, .scs = .{ .partitions = &board.partitions, .regions = &board.regions, .clears = &board.clears } };
    var machine: stop_machine.Machine = .{};
    var driver: step_hook.Driver = .{ .machine = &machine };
    var watching: watch_bus.WatchBus = .{ .inner = memory.view(), .driver = &driver };
    var cpu: cpu_mod.Cpu = .{ .bus = watching.view() };
    var pending: NvicSource = .{};
    cpu.source = pending.source();
    cpu.reset(vector_base) catch {
        std.debug.print("zig core: no vector table at 0x{X:0>8}\n", .{vector_base});
        return 1;
    };
    var target: zig_script.ZigScript = .{ .image = image, .session = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = session.limits.default_budget, .watch = &watching } };
    if (request.mode == .gdb) return listen(&core, &target.session, request.mode.gdb);
    return drive(allocator, &target, request.mode, out);
}

/// Play the script or talk to the terminal, as the Unicorn front does.
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
    try target.session.machine.itm.flush(out, true);
    return 0;
}

/// Wait for gdb on the loopback port and serve it from the Zig core, the
/// way debug_front.zig's listen serves the Unicorn session (RA8EMU-118).
fn listen(core: *const engine.Engine, live: *zig_session.ZigSession, port: u16) !u8 {
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
    live.budget = rsp_poll.chunk;
    var target: rsp_dispatch.zig_run.Target = .{ .session = live, .poll = socket.poll() };
    const stub = rsp_dispatch.Dispatch{ .core = core, .zig = &target };
    const end = try rsp_dispatch.server.serve(stub, connection.stream.reader(), connection.stream.writer());
    std.debug.print("gdb: {s}\n", .{@tagName(end)});
    return 0;
}
