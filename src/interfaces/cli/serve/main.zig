//! `ra8_emulator serve` (RA8EMU-737, RA8EMU-736): a headless session server.
//!
//! It opens the ELF through served_setup and answers session RPC
//! frames on stdin/stdout (--stdio) or on one socket client at a time
//! (--listen). Frames are the only thing written to stdout; complaints go
//! to stderr.
const std = @import("std");
const served_setup = @import("ra8_rpc").served_setup;
const served_camera = @import("ra8_rpc").served_camera;
const source_spec = @import("ra8_host").camera.source_spec;
const loop = @import("loop.zig");
const listen = @import("listen.zig");
const card_setup = @import("../card/setup.zig");
const card_apps = @import("ra8_rpc").card_apps;
const txm_debug = @import("ra8_session").txm.debug;
const session_api = @import("ra8_session").api;
const elf = @import("ra8_board").image.elf;
const usbip_run = @import("ra8_usbip").exported.run;
const Workbench = @import("workbench.zig").Workbench;

pub const usage =
    \\usage: ra8_emulator serve [--profile-folded] [--cpu1 CPU1.elf] --stdio <firmware.elf>
    \\       ra8_emulator serve [--profile-folded] [--cpu1 CPU1.elf] [--allow-state-files] --listen unix:PATH|tcp:[HOST]:PORT <firmware.elf>
    \\       --profile-folded samples each core's call stacks for `ctl folded`
    \\       --cpu1 brings CPU1 up from its own image, parked until it is run
    \\       --sd-dir DIR and --app FILE.ra8app[=MODULE.elf] (repeatable) fill the SDHI card, as for a run
    \\       --allow-state-files lets snapshot and restore run on a non-loopback listener
    \\       --workspace DIR enables rooted workbench file operations for connected clients
    \\       --build-zig ABSOLUTE_PATH enables backend Zig builds in that workspace (trusted projects only)
    \\       --history DIR puts the session's persistent history in DIR; --history off keeps it RAM only
    \\       --kept preserves the session on disk after exit (with --history DIR)
    \\       --checkpoint-every N writes a closed-round checkpoint every N rounds (default 64)
    \\       --history-budget BYTES caps the served session's history share (with --history DIR; minimum 128 MiB)
    \\       --frame-hz N caps the frame tap at N captures per host second (0 captures every change; default 60)
    \\       --ram-budget BYTES caps the RAM-only history's share (with --history off; minimum 128 MiB)
    \\       --camera-source KIND[:ARG] and --allow-webcam select the served session's camera source
    \\
;

const Where = union(enum) { stdio, listen: listen.Spec };
const Asked = struct { build_zig: ?[]const u8 = null, where: Where, elf: []const u8, folded: bool = false, cpu1: ?[]const u8 = null, sdhi: card_setup.Sdhi = .{}, allow_state_files: bool = false, history: ?[]const u8 = null, history_off: bool = false, checkpoint_every: u32 = 64, history_budget: ?u64 = null, ram_budget: ?u64 = null, kept: bool = false, reopen: ?[]const u8 = null, frame_hz: ?u32 = null, usbip: ?u16 = null, camera: ?source_spec.Spec = null, allow_webcam: bool = false, workspace: ?[]const u8 = null };

/// Samples taken one every this many instructions under --profile-folded.
pub const fold_every: u32 = 1000;

const ParsedFlags = struct {
    build_zig: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    folded: bool = false,
    allow_state: bool = false,
    cpu1: ?[]const u8 = null,
    sdhi: card_setup.Sdhi = .{},
    history_root: ?[]const u8 = null,
    history_off: bool = false,
    kept: bool = false,
    reopen: ?[]const u8 = null,
    frame_hz: ?u32 = null,
    usbip: ?u16 = null,
    camera: ?source_spec.Spec = null,
    allow_webcam: bool = false,
    checkpoint_every: u32 = 64,
    history_budget: ?u64 = null,
    ram_budget: ?u64 = null,
    checkpoint_set: bool = false,
};

/// The transport and image `argv` asks for, or null for a malformed line.
/// The options come first, in any order, each at most once.
pub fn parse(argv: []const []const u8) ?Asked {
    if (argv.len < 2) return null;
    var flags: ParsedFlags = .{};
    var at: usize = 2;
    while (at < argv.len) : (at += 1) {
        switch (parseFlag(&flags, argv, &at)) {
            .taken => {},
            .stop => break,
            .bad => return null,
        }
    }
    var asked = parseTail(argv, at) orelse return null;
    asked.folded = flags.folded;
    asked.workspace = flags.workspace;
    asked.build_zig = flags.build_zig;
    asked.allow_state_files = flags.allow_state;
    asked.history = flags.history_root;
    asked.history_off = flags.history_off;
    asked.history_budget = flags.history_budget;
    asked.ram_budget = flags.ram_budget;
    asked.checkpoint_every = flags.checkpoint_every;
    asked.cpu1 = flags.cpu1;
    asked.sdhi = flags.sdhi;
    asked.kept = flags.kept;
    asked.reopen = flags.reopen;
    asked.frame_hz = flags.frame_hz;
    asked.usbip = flags.usbip;
    asked.allow_webcam = flags.allow_webcam;
    if (flags.camera) |cam| {
        var c = cam;
        c.allow_webcam = flags.allow_webcam;
        asked.camera = c;
    }
    return if (consistent(asked)) asked else null;
}

const FlagStep = enum { taken, stop, bad };

fn parseFlag(flags: *ParsedFlags, argv: []const []const u8, at: *usize) FlagStep {
    const idx = at.*;
    const valued = idx + 1 < argv.len;
    if (std.mem.eql(u8, argv[idx], "--profile-folded") and !flags.folded) {
        flags.folded = true;
    } else if (std.mem.eql(u8, argv[idx], "--allow-state-files") and !flags.allow_state) {
        flags.allow_state = true;
    } else if (std.mem.eql(u8, argv[idx], "--build-zig") and flags.build_zig == null and valued) {
        at.* += 1;
        @import("ra8_host").build.Runner.validateCompiler(argv[at.*]) catch return .bad;
        flags.build_zig = argv[at.*];
    } else if (std.mem.eql(u8, argv[idx], "--workspace") and flags.workspace == null and valued) {
        at.* += 1;
        if (argv[at.*].len == 0) return .bad;
        flags.workspace = argv[at.*];
    } else if (std.mem.eql(u8, argv[idx], "--cpu1") and flags.cpu1 == null and valued) {
        at.* += 1;
        flags.cpu1 = argv[at.*];
    } else if (std.mem.eql(u8, argv[idx], "--sd-dir") and flags.sdhi.dir == null and valued) {
        at.* += 1;
        flags.sdhi.dir = argv[at.*];
    } else if (std.mem.eql(u8, argv[idx], "--app") and valued) {
        at.* += 1;
        flags.sdhi.addApp(argv[at.*]) catch return .bad;
    } else if (std.mem.eql(u8, argv[idx], "--history") and flags.history_root == null and !flags.history_off and valued) {
        at.* += 1;
        if (std.mem.eql(u8, argv[at.*], "off")) flags.history_off = true else flags.history_root = argv[at.*];
    } else if (std.mem.eql(u8, argv[idx], "--kept") and !flags.kept) {
        flags.kept = true;
    } else if (std.mem.eql(u8, argv[idx], "--frame-hz") and flags.frame_hz == null and valued) {
        at.* += 1;
        flags.frame_hz = std.fmt.parseInt(u32, argv[at.*], 10) catch return .bad;
    } else if (std.mem.eql(u8, argv[idx], "--usbip") and flags.usbip == null and valued) {
        at.* += 1;
        flags.usbip = std.fmt.parseInt(u16, argv[at.*], 10) catch return .bad;
    } else if (std.mem.eql(u8, argv[idx], "--reopen") and flags.reopen == null and valued) {
        at.* += 1;
        flags.reopen = argv[at.*];
    } else if (std.mem.eql(u8, argv[idx], "--checkpoint-every") and !flags.checkpoint_set and valued) {
        at.* += 1;
        flags.checkpoint_every = std.fmt.parseInt(u32, argv[at.*], 10) catch return .bad;
        flags.checkpoint_set = true;
    } else if (std.mem.eql(u8, argv[idx], "--history-budget") and flags.history_budget == null and valued) {
        at.* += 1;
        flags.history_budget = std.fmt.parseInt(u64, argv[at.*], 10) catch return .bad;
    } else if (std.mem.eql(u8, argv[idx], "--ram-budget") and flags.ram_budget == null and valued) {
        at.* += 1;
        flags.ram_budget = std.fmt.parseInt(u64, argv[at.*], 10) catch return .bad;
    } else if (std.mem.eql(u8, argv[idx], "--camera-source") and flags.camera == null and valued) {
        at.* += 1;
        flags.camera = source_spec.parse(argv[at.*]) catch return .bad;
    } else if (std.mem.eql(u8, argv[idx], "--allow-webcam") and !flags.allow_webcam) {
        flags.allow_webcam = true;
    } else return .stop;
    return .taken;
}

/// The transport and image after the options: they are dropped, so the
/// transport sits at index 2 as before.
fn parseTail(argv: []const []const u8, at: usize) ?Asked {
    var rest: [5][]const u8 = undefined;
    const left = argv.len - at;
    if (left > 3) return null;
    rest[0] = argv[0];
    rest[1] = argv[1];
    @memcpy(rest[2..][0..left], argv[at..]);
    return parseWhere(rest[0 .. 2 + left]);
}

/// Whether the history options make sense together.
fn consistent(asked: Asked) bool {
    if (asked.build_zig != null and asked.workspace == null) return false;
    // A cap means nothing without a persistent history to cap.
    if (asked.history_budget != null and asked.history == null) return false;
    // Kept means nothing without a persistent history.
    if (asked.kept and asked.history == null) return false;
    // A reopened session is one already on disk.
    if (asked.reopen != null and (asked.history == null or asked.kept)) return false;
    // A RAM share cap means nothing without a RAM-only history to cap.
    return asked.ram_budget == null or asked.history_off;
}

fn parseWhere(argv: []const []const u8) ?Asked {
    if (argv.len == 4 and std.mem.eql(u8, argv[2], "--stdio")) return .{ .where = .stdio, .elf = argv[3] };
    if (argv.len != 5 or !std.mem.eql(u8, argv[2], "--listen")) return null;
    const spec = listen.Spec.parse(argv[3]) catch return null;
    return .{ .where = .{ .listen = spec }, .elf = argv[4] };
}

/// Each paired app's display name and module ELF, as the session places them.
/// Places and clears real breakpoints for breaks named before their
/// module loaded, through the served session (RA8EMU-1141).
const BreakArmer = struct {
    session: *session_api.Session,
    fn arm(ctx: *anyopaque, of: txm_debug.Core, address: u32) anyerror!u32 {
        const self: *BreakArmer = @ptrCast(@alignCast(ctx));
        return self.session.setBreakpoint(of, .{ .address = address });
    }
    fn drop(ctx: *anyopaque, of: txm_debug.Core, id: u32) anyerror!void {
        const self: *BreakArmer = @ptrCast(@alignCast(ctx));
        return self.session.clearBreakpoint(of, id);
    }
};

/// Serve `argv` (`ra8_emulator serve ...`) and return the exit code.
pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    const asked = parse(argv) orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    // Declared before the session so the bridge outlives the session's release of it.
    var bridges = std.heap.ArenaAllocator.init(allocator);
    defer bridges.deinit();
    var setup: served_setup.Served = undefined;
    const history_opts: ?served_setup.HistoryOpts = if (asked.history) |root|
        .{ .root = root, .checkpoint_every = asked.checkpoint_every, .budget = asked.history_budget, .kept = asked.kept, .reopen = asked.reopen, .frame_hz = asked.frame_hz }
    else if (asked.history_off)
        .{ .checkpoint_every = asked.checkpoint_every, .ram_budget = asked.ram_budget, .frame_hz = asked.frame_hz }
    else
        null;
    setup.openInputs(allocator, io, asked.elf, null, history_opts, if (asked.cpu1) |path| .{ .path = path } else null, .{ .card = asked.sdhi }) catch |err| {
        std.debug.print("serve: cannot open {s}: {s}\n", .{ asked.elf, @errorName(err) });
        return 1;
    };
    defer setup.deinit();
    var workbench: Workbench = .{};
    workbench.open(io, asked.workspace, asked.build_zig) catch |err| {
        std.debug.print("serve: cannot open workbench: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer workbench.close();
    workbench.bind(&setup.context);
    if (asked.camera) |cam| {
        served_camera.set(&setup, cam) catch |err| {
            std.debug.print("serve: cannot open camera source: {s}\n", .{@errorName(err)});
            return 1;
        };
    }
    if (asked.usbip) |port| {
        usbip_run.install(&setup.owner.board().usb, bridges.allocator(), io, port) catch |err| {
            std.debug.print("serve: cannot export the FS device: {s}\n", .{@errorName(err)});
            return 1;
        };
        setup.attachUsbip() catch |err| {
            std.debug.print("serve: cannot record the USB/IP bridge: {s}\n", .{@errorName(err)});
            return 1;
        };
    }
    var armer = BreakArmer{ .session = setup.context.session };
    if (setup.context.modules) |table|
        table.armer = .{ .ctx = &armer, .arm = BreakArmer.arm, .drop = BreakArmer.drop };
    if (asked.folded) setup.sampleStacks(fold_every) catch |err| {
        std.debug.print("serve: cannot sample stacks: {s}\n", .{@errorName(err)});
        return 1;
    };
    // Snapshot and restore stay off a non-loopback TCP listener unless the
    // operator asked for them there (RA8EMU-1175): a network peer could
    // otherwise overwrite or read files as the serving user.
    switch (asked.where) {
        .listen => |spec| if (!listen.allowsState(spec, asked.allow_state_files)) {
            setup.context.state = null;
            std.debug.print("serve: snapshot and restore are off on a non-loopback listener; pass --allow-state-files to keep them\n", .{});
        },
        .stdio => {},
    }
    const buffers: loop.Buffers = .{ .rx = setup.rx, .tx = setup.tx };
    const context = &setup.context;
    const done = switch (asked.where) {
        .stdio => loop.answerStdio(io, context, buffers),
        .listen => |spec| listen.serve(io, spec, context, buffers),
    };
    done catch |err| {
        std.debug.print("serve: {s}\n", .{@errorName(err)});
        return 1;
    };
    setup.flushHistory() catch |err| {
        std.debug.print("serve: cannot flush history: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}
