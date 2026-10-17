//! Command-line argument parsing for ra8_gui (RA8EMU-1120).
const std = @import("std");
const colors = @import("../ui/colors.zig");
const card_apps = @import("ra8_rpc").card_apps;
const shell_startup = @import("startup.zig");
const source_spec = @import("ra8_host").camera.source_spec;
const host_profiles = @import("ra8_host").profiles;

pub const usage = "usage: ra8_gui [--host NAME] [--hosts FILE] [--attach MODEL@ENDPOINT]... [--click]\n" ++
    "    [--app FILE.ra8app[=MODULE.elf]]... [--camera-source KIND[:ARG]] [--window-stills DIR [--window-stills-every N]]\n" ++
    "    [--frames N] [--theme dark|light|system] [--render-driver NAME]\n" ++
    "    [--headless] [--gui-script PATH] [--gui-video-out PATH] [--gui-video-fps N] [--show-cursor] [IMAGE]\n" ++
    "With no IMAGE the shell opens empty: File > Open ELF starts the session. --headless, --frames and --gui-script need one.\n";

const shell_word = "shell";

pub const Args = struct {
    /// Null when none was named: the shell opens empty (boot.zig).
    image: ?[]const u8 = null,
    apps: [card_apps.max_apps][]const u8 = undefined,
    app_count: usize = 0,
    host: ?[]const u8 = null,
    hosts: ?[]const u8 = null,
    startup: shell_startup.Startup = .{},
    camera: ?source_spec.Spec = null,
    stills: ?[]const u8 = null,
    stills_every: u32 = 1,
    frames: ?u32 = null,
    theme: colors.Choice = .dark,
    theme_set: bool = false,
    render_driver: ?[]const u8 = null,
    headless: bool = false,
    gui_script: ?[]const u8 = null,
    gui_video_out: ?[]const u8 = null,
    gui_video_fps: u32 = 30,
    show_cursor: bool = false,
};

fn addApp(args: *Args, path: []const u8) !void {
    if (args.app_count == card_apps.max_apps) return error.TooManyApps;
    args.apps[args.app_count] = path;
    args.app_count += 1;
}

pub fn parse(argv: []const []const u8) error{Usage}!Args {
    var args: Args = .{};
    var image: ?[]const u8 = null;
    var i: usize = if (argv.len > 1 and std.mem.eql(u8, argv[1], shell_word)) 2 else 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--click")) {
            args.startup.addClick() catch return error.Usage;
        } else if (std.mem.eql(u8, arg, "--headless")) {
            args.headless = true;
        } else if (std.mem.eql(u8, arg, "--show-cursor")) {
            args.show_cursor = true;
        } else if (valued(arg)) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            take(&args, arg, argv[i]) catch return error.Usage;
        } else if (std.mem.startsWith(u8, arg, "-") or image != null) {
            return error.Usage;
        } else image = arg;
    }
    // A run nobody watches has nobody to pick an image.
    if (image == null and (args.headless or args.frames != null or args.gui_script != null)) return error.Usage;
    args.image = image;
    return args;
}

const valued_flags = [_][]const u8{
    "--host",
    "--hosts",
    "--attach",
    "--app",
    "--camera-source",
    "--window-stills",
    "--window-stills-every",
    "--frames",
    "--theme",
    "--render-driver",
    "--gui-script",
    "--gui-video-out",
    "--gui-video-fps",
};

fn valued(arg: []const u8) bool {
    for (valued_flags) |flag| if (std.mem.eql(u8, arg, flag)) return true;
    return false;
}

fn take(args: *Args, flag: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, flag, "--host")) {
        args.host = value;
    } else if (std.mem.eql(u8, flag, "--hosts")) {
        args.hosts = value;
    } else if (std.mem.eql(u8, flag, "--attach")) {
        try args.startup.add(value);
    } else if (std.mem.eql(u8, flag, "--app")) {
        addApp(args, value) catch return error.Usage;
    } else if (std.mem.eql(u8, flag, "--camera-source")) {
        args.camera = try source_spec.parse(value);
    } else if (std.mem.eql(u8, flag, "--window-stills")) {
        args.stills = value;
    } else if (std.mem.eql(u8, flag, "--window-stills-every")) {
        args.stills_every = try count(value);
    } else if (std.mem.eql(u8, flag, "--theme")) {
        args.theme = std.meta.stringToEnum(colors.Choice, value) orelse return error.BadValue;
        args.theme_set = true;
    } else if (std.mem.eql(u8, flag, "--render-driver")) {
        args.render_driver = value;
    } else if (std.mem.eql(u8, flag, "--gui-script")) {
        args.gui_script = value;
    } else if (std.mem.eql(u8, flag, "--gui-video-out")) {
        args.gui_video_out = value;
    } else if (std.mem.eql(u8, flag, "--gui-video-fps")) {
        args.gui_video_fps = try count(value);
    } else {
        args.frames = try count(value);
    }
}

fn count(text: []const u8) !u32 {
    const value = try std.fmt.parseInt(u32, text, 10);
    if (value == 0) return error.BadValue;
    return value;
}

pub fn pick(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, args: Args) !host_profiles.Profile {
    const name = args.host orelse return .local;
    if (std.mem.eql(u8, name, "local")) return .local;
    return host_profiles.load(allocator, io, env, args.hosts, name);
}
