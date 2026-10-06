//! `shell` from main (RA8EMU-770): the docked debugger shell in a window.
//! It picks the host (the local one unless --host names a profile in the
//! hosts file), starts that host's session, loads the image once the session
//! greets, and runs the shell loop (RA8EMU-763) until the window closes.
//! Only the local host connects so far; SSH profiles join with RA8EMU-761.
const std = @import("std");
const host_profiles = @import("host_profiles.zig");
const window_main = @import("window_main.zig");
const platform = @import("../../gui/platform.zig");
const pane_layout = @import("../../gui/pane_layout.zig");
const shell_loop = @import("../../gui/shell_loop.zig");
const shell_panes = @import("../../gui/shell_panes.zig");
const shell_console = @import("../../gui/shell_console.zig");
const session_link = @import("../../gui/session_link.zig");
const proto = @import("../rpc/session_rpc.zig");

const Env = proto.Client.Env;
const usage = "usage: ra8_emulator shell [--host NAME] [--hosts FILE] IMAGE\n";

/// Largest image the shell reads, as main does for a run.
const max_image: usize = 64 * 1024 * 1024;

/// A pause between frames so an idle shell does not spin a core.
const frame_gap_ns: u64 = 4 * std.time.ns_per_ms;

pub const Args = struct {
    image: []const u8,
    host: ?[]const u8 = null,
    hosts: ?[]const u8 = null,
};

/// Parse `ra8_emulator shell [--host NAME] [--hosts FILE] IMAGE`.
pub fn parse(argv: []const []const u8) error{Usage}!Args {
    if (argv.len < 2 or !std.mem.eql(u8, argv[1], "shell")) return error.Usage;
    var args: Args = .{ .image = "" };
    var image: ?[]const u8 = null;
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        const host = std.mem.eql(u8, arg, "--host");
        if (host or std.mem.eql(u8, arg, "--hosts")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            if (host) args.host = argv[i] else args.hosts = argv[i];
        } else if (std.mem.startsWith(u8, arg, "-") or image != null) {
            return error.Usage;
        } else image = arg;
    }
    args.image = image orelse return error.Usage;
    return args;
}

/// The host the shell connects to: the local one unless --host names a
/// profile, which comes from the hosts file. "local" needs no file.
pub fn pick(allocator: std.mem.Allocator, args: Args) !host_profiles.Profile {
    const name = args.host orelse return .local;
    if (std.mem.eql(u8, name, "local")) return .local;
    return host_profiles.load(allocator, args.hosts, name);
}

/// Run the shell; 2 when the command line, host, or window is unusable.
/// `allocator` is main's arena.
pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) !u8 {
    const args = parse(argv) catch {
        std.debug.print(usage, .{});
        return 2;
    };
    const profile = pick(allocator, args) catch |err| {
        std.debug.print("no host {s}: {s}\n", .{ args.host.?, @errorName(err) });
        return 2;
    };
    if (profile == .ssh) {
        std.debug.print("the shell connects to the local host only so far; ctl --host reaches ssh hosts\n", .{});
        return 2;
    }
    const bytes = std.fs.cwd().readFileAlloc(allocator, args.image, max_image) catch |err| {
        std.debug.print("cannot read {s}: {s}\n", .{ args.image, @errorName(err) });
        return 1;
    };
    const window = window_main.open() orelse {
        std.debug.print("shell needs a window: build the emulator with -Dgui\n", .{});
        return 2;
    };
    defer if (window_main.opener) |how| how.close();
    try local(allocator, window, args.image, bytes);
    return 0;
}

/// Start a local `serve --stdio` on this executable and run the shell on it.
fn local(allocator: std.mem.Allocator, window: platform.Platform, path: []const u8, bytes: []const u8) !void {
    const exe = try std.fs.selfExePathAlloc(allocator);
    var child: session_link.Local = undefined;
    try child.spawn(allocator, exe, path);
    const rx = try allocator.alloc(u8, 2 * Env.max_frame);
    const tx = try allocator.alloc(u8, Env.max_frame);
    var link: session_link.Link = undefined;
    link.open(child.transport(), rx, tx);
    var shell = shell_loop.Shell.init(allocator, try pane_layout.twoCore(allocator));
    defer shell.deinit();
    shell.link = &link;
    var console = shell_console.Console.init(allocator);
    defer console.deinit();
    shell.console = &console;
    var panes: shell_panes.Panes = .{ .console = &console };
    shell.painter = panes.painter();
    try drive(&shell, window, path, bytes);
    link.close();
    child.end();
    _ = try child.reap();
}

/// Step `shell` until its window closes, loading the image once its session
/// has greeted.
pub fn drive(shell: *shell_loop.Shell, window: platform.Platform, path: []const u8, bytes: []const u8) !void {
    var sent = false;
    while (try shell.step(window)) {
        if (!sent and shell.state() == .connected) {
            const link = shell.link orelse return;
            try shell.status.load(link, path, bytes);
            sent = true;
        }
        std.time.sleep(frame_gap_ns);
    }
}
