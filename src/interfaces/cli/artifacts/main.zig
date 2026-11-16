//! Stream portable session bundles through an existing headless server.
const std = @import("std");

const Client = @import("../ctl/client.zig").Client;
const download = @import("download.zig");
const Spec = @import("../serve/listen.zig").Spec;
const upload = @import("upload.zig");

pub const usage =
    "usage: ra8_emulator export-session --connect tcp:HOST:PORT FILE [--state-only]\n" ++
    "       ra8_emulator import-session --connect tcp:HOST:PORT FILE\n" ++
    "       the server must enable --artifacts-root DIR; import closes the connection\n";

pub const Asked = struct { importing: bool, target: Spec, path: []const u8, recording: bool };

pub fn parse(argv: []const []const u8) ?Asked {
    if (argv.len < 5 or argv.len > 6 or !std.mem.eql(u8, argv[2], "--connect")) return null;
    const importing = std.mem.eql(u8, argv[1], "import-session");
    if (!importing and !std.mem.eql(u8, argv[1], "export-session")) return null;
    if (argv[4].len == 0) return null;
    if (argv.len == 6 and (importing or !std.mem.eql(u8, argv[5], "--state-only"))) return null;
    return .{
        .importing = importing,
        .target = Spec.parse(argv[3]) catch return null,
        .path = argv[4],
        .recording = argv.len == 5,
    };
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    const asked = parse(argv) orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    const client = Client.open(gpa, io, .{ .socket = asked.target }) catch |err| {
        std.debug.print("artifacts: connect: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer client.close();
    // Capturing and validating a recording can outlast an ordinary control request.
    client.wait_ms = 600_000;
    const result = if (asked.importing)
        upload.send(client, asked.path)
    else
        download.save(gpa, client, asked.path, asked.recording);
    result catch |err| {
        std.debug.print("artifacts: {s} (RPC refusal 0x{x})\n", .{ @errorName(err), client.refused });
        return 1;
    };
    return 0;
}
