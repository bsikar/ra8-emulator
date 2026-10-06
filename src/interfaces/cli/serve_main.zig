//! `ra8_emulator serve --stdio ELF` (RA8EMU-737): a headless session server.
//!
//! It opens the ELF through the public harness, wraps stdin and stdout in
//! the session RPC transport and answers requests until stdin closes.
//! Frames are the only thing written to stdout; complaints go to stderr.
const std = @import("std");
const harness = @import("../../harness.zig");
const proto = @import("../rpc/session_rpc.zig");
const served = @import("../rpc/session_server.zig");
const Stdio = @import("../rpc/stdio_transport.zig").Stdio;

pub const usage = "usage: ra8_emulator serve --stdio <firmware.elf>\n";

/// How long an idle server waits on stdin before checking it again.
const idle_wait_ms = 20;

/// Serve `argv` (`ra8_emulator serve --stdio ELF`) and return the exit code.
pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) !u8 {
    if (argv.len != 4 or !std.mem.eql(u8, argv[2], "--stdio")) {
        std.debug.print("{s}", .{usage});
        return 2;
    }
    var owner = harness.open(allocator, .{ .elf_path = argv[3] }) catch |err| {
        std.debug.print("serve: cannot open {s}: {s}\n", .{ argv[3], @errorName(err) });
        return 1;
    };
    defer owner.deinit();
    const Env = served.Server.Env;
    const scratch = try allocator.alloc(u8, proto.max_payload);
    const rx = try allocator.alloc(u8, 2 * Env.max_frame);
    const tx = try allocator.alloc(u8, Env.max_frame);
    var context: served.Context = .{ .session = owner.session(), .scratch = scratch };
    var stdio: Stdio = .{};
    var host = served.Host.init(stdio.transport(), rx, &context);
    serveUntilClosed(&host, stdio.input, tx) catch |err| {
        std.debug.print("serve: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

/// Answer frames until the client closes its end of `input`.
fn serveUntilClosed(host: *served.Host, input: std.posix.fd_t, tx: []u8) !void {
    while (true) {
        if (try host.poll(tx) != .idle) continue;
        if (try closed(input)) return;
    }
}

/// Wait briefly for input; true once the writer hung up with nothing left.
fn closed(input: std.posix.fd_t) !bool {
    var fds = [_]std.posix.pollfd{.{ .fd = input, .events = std.posix.POLL.IN, .revents = 0 }};
    _ = try std.posix.poll(&fds, idle_wait_ms);
    const revents = fds[0].revents;
    return revents & std.posix.POLL.HUP != 0 and revents & std.posix.POLL.IN == 0;
}
