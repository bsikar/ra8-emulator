//! Serve option parsing, separated from session ownership and transport setup.
const std = @import("std");

const card_setup = @import("../card/setup.zig");
const host = @import("ra8_host");
const source_spec = @import("ra8_host").camera.source_spec;

pub const ParsedFlags = struct {
    artifacts_root: ?[]const u8 = null,
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

const FlagStep = enum { taken, stop, bad };

pub fn parseFlag(flags: *ParsedFlags, argv: []const []const u8, at: *usize) FlagStep {
    inline for (.{
        parseAccess, parseInputs, parseCardHistory, parseCapture, parseHistory, parseCameraBudget,
    }) |parseOne| {
        const step = parseOne(flags, argv, at);
        if (step != .stop) return step;
    }
    return .stop;
}

fn parseAccess(flags: *ParsedFlags, argv: []const []const u8, at: *usize) FlagStep {
    const idx = at.*;
    const valued = idx + 1 < argv.len;
    if (std.mem.eql(u8, argv[idx], "--profile-folded") and !flags.folded) {
        flags.folded = true;
    } else if (std.mem.eql(u8, argv[idx], "--allow-state-files") and !flags.allow_state) {
        flags.allow_state = true;
    } else if (std.mem.eql(u8, argv[idx], "--artifacts-root") and flags.artifacts_root == null and valued) {
        at.* += 1;
        if (argv[at.*].len == 0) return .bad;
        flags.artifacts_root = argv[at.*];
    } else return .stop;
    return .taken;
}

fn parseInputs(flags: *ParsedFlags, argv: []const []const u8, at: *usize) FlagStep {
    const idx = at.*;
    const valued = idx + 1 < argv.len;
    if (std.mem.eql(u8, argv[idx], "--build-zig") and flags.build_zig == null and valued) {
        at.* += 1;
        host.build.Runner.validateCompiler(argv[at.*]) catch return .bad;
        flags.build_zig = argv[at.*];
    } else if (std.mem.eql(u8, argv[idx], "--workspace") and flags.workspace == null and valued) {
        at.* += 1;
        if (argv[at.*].len == 0) return .bad;
        flags.workspace = argv[at.*];
    } else if (std.mem.eql(u8, argv[idx], "--cpu1") and flags.cpu1 == null and valued) {
        at.* += 1;
        flags.cpu1 = argv[at.*];
    } else return .stop;
    return .taken;
}

fn parseCardHistory(flags: *ParsedFlags, argv: []const []const u8, at: *usize) FlagStep {
    const idx = at.*;
    const valued = idx + 1 < argv.len;
    if (std.mem.eql(u8, argv[idx], "--sd-dir") and flags.sdhi.dir == null and valued) {
        at.* += 1;
        flags.sdhi.dir = argv[at.*];
    } else if (std.mem.eql(u8, argv[idx], "--app") and valued) {
        at.* += 1;
        flags.sdhi.addApp(argv[at.*]) catch return .bad;
    } else if (std.mem.eql(u8, argv[idx], "--history") and
        flags.history_root == null and
        !flags.history_off and
        valued)
    {
        at.* += 1;
        if (std.mem.eql(u8, argv[at.*], "off")) flags.history_off = true else flags.history_root = argv[at.*];
    } else return .stop;
    return .taken;
}

fn parseCapture(flags: *ParsedFlags, argv: []const []const u8, at: *usize) FlagStep {
    const idx = at.*;
    const valued = idx + 1 < argv.len;
    if (std.mem.eql(u8, argv[idx], "--kept") and !flags.kept) {
        flags.kept = true;
    } else if (std.mem.eql(u8, argv[idx], "--frame-hz") and flags.frame_hz == null and valued) {
        at.* += 1;
        flags.frame_hz = std.fmt.parseInt(u32, argv[at.*], 10) catch return .bad;
    } else if (std.mem.eql(u8, argv[idx], "--usbip") and flags.usbip == null and valued) {
        at.* += 1;
        flags.usbip = std.fmt.parseInt(u16, argv[at.*], 10) catch return .bad;
    } else return .stop;
    return .taken;
}

fn parseHistory(flags: *ParsedFlags, argv: []const []const u8, at: *usize) FlagStep {
    const idx = at.*;
    const valued = idx + 1 < argv.len;
    if (std.mem.eql(u8, argv[idx], "--reopen") and flags.reopen == null and valued) {
        at.* += 1;
        flags.reopen = argv[at.*];
    } else if (std.mem.eql(u8, argv[idx], "--checkpoint-every") and !flags.checkpoint_set and valued) {
        at.* += 1;
        flags.checkpoint_every = std.fmt.parseInt(u32, argv[at.*], 10) catch return .bad;
        flags.checkpoint_set = true;
    } else if (std.mem.eql(u8, argv[idx], "--history-budget") and flags.history_budget == null and valued) {
        at.* += 1;
        flags.history_budget = std.fmt.parseInt(u64, argv[at.*], 10) catch return .bad;
    } else return .stop;
    return .taken;
}

fn parseCameraBudget(flags: *ParsedFlags, argv: []const []const u8, at: *usize) FlagStep {
    const idx = at.*;
    const valued = idx + 1 < argv.len;
    if (std.mem.eql(u8, argv[idx], "--ram-budget") and flags.ram_budget == null and valued) {
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
