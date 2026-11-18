//! Transport carrier for a `probe-agent` session: either a TCP socket (local
//! loopback or SSH tunnel) or a spawned `probe-agent --stdio` process from a
//! named `ra8_host.profiles` (`local` or `ssh`) host profile.
const std = @import("std");

const host = @import("ra8_host");
const host_spawn = @import("../host/spawn.zig");

const auth = host.probe_host.auth;
const profiles = host.profiles;
const wire = host.probe_host.wire;

pub const Spec = union(enum) {
    tcp: struct {
        address: []const u8,
        port: u16,
    },
    profile: struct {
        name: []const u8 = "",
        hosts_file: []const u8 = "",
        profile: profiles.Profile,
        remote_targets: []const u8,
        remote_secret_file: []const u8,
        local_emulator: []const u8 = "",
    },
};

pub const Link = union(enum) {
    closed,
    tcp: struct {
        stream: std.Io.net.Stream,
        session: auth.Session,
    },
    child: struct {
        proc: std.process.Child,
        session: auth.Session,
    },

    pub fn isOpen(self: *const Link) bool {
        return self.* != .closed;
    }

    pub fn close(self: *Link, io: std.Io) void {
        switch (self.*) {
            .closed => {},
            .tcp => |t| t.stream.close(io),
            .child => |*c| {
                if (c.proc.stdin) |in| in.close(io);
                c.proc.stdin = null;
                c.proc.kill(io);
            },
        }
        self.* = .closed;
    }

    pub fn connect(self: *Link, io: std.Io, spec: Spec, host_id: []const u8, key: auth.Key) !void {
        if (self.isOpen()) return;
        switch (spec) {
            .tcp => |tcp| {
                const remote = try std.Io.net.HostName.init(tcp.address);
                var stream = try remote.connect(io, tcp.port, .{ .mode = .stream });
                errdefer stream.close(io);
                var tx: [1024]u8 = undefined;
                var writer = stream.writer(io, &tx);
                const session = try auth.authenticateClientFrom(
                    io,
                    .{ .socket = .{ .handle = stream.socket.handle } },
                    &writer.interface,
                    host_id,
                    key,
                );
                self.* = .{ .tcp = .{ .stream = stream, .session = session } };
            },
            .profile => |prof| {
                var child = try spawnAgent(io, prof, host_id);
                errdefer {
                    if (child.stdin) |in| in.close(io);
                    child.stdin = null;
                    child.kill(io);
                }
                var tx: [1024]u8 = undefined;
                var writer = child.stdin.?.writerStreaming(io, &tx);
                const session = try auth.authenticateClientFrom(
                    io,
                    .{ .pipe = .{ .file = child.stdout.? } },
                    &writer.interface,
                    host_id,
                    key,
                );
                self.* = .{ .child = .{ .proc = child, .session = session } };
            },
        }
    }

    pub fn send(self: *Link, io: std.Io, req: wire.Request) !void {
        var tx: [2048]u8 = undefined;
        switch (self.*) {
            .closed => return error.AgentDisconnected,
            .tcp => |*t| {
                var writer = t.stream.writer(io, &tx);
                wire.send(&writer.interface, &t.session, req) catch return error.AgentDisconnected;
            },
            .child => |*c| {
                var writer = c.proc.stdin.?.writerStreaming(io, &tx);
                wire.send(&writer.interface, &c.session, req) catch return error.AgentDisconnected;
            },
        }
    }

    pub fn receive(
        self: *Link,
        allocator: std.mem.Allocator,
        io: std.Io,
        scratch: []u8,
        timeout_ms: u32,
    ) !std.json.Parsed(wire.Reply) {
        return switch (self.*) {
            .closed => error.AgentDisconnected,
            .tcp => |*t| wire.receiveSocket(
                wire.Reply,
                allocator,
                io,
                t.stream.socket.handle,
                &t.session,
                scratch,
                timeout_ms,
            ),
            .child => |*c| wire.receivePipe(
                wire.Reply,
                allocator,
                io,
                c.proc.stdout.?,
                &c.session,
                scratch,
                timeout_ms,
            ),
        };
    }
};

pub fn agentArgv(
    allocator: std.mem.Allocator,
    io: std.Io,
    prof: anytype,
    host_id: []const u8,
) ![]const []const u8 {
    return switch (prof.profile) {
        .local => blk: {
            const exe = if (prof.local_emulator.len != 0)
                prof.local_emulator
            else
                try std.process.executablePathAlloc(io, allocator);
            break :blk allocator.dupe([]const u8, &.{
                exe,             "probe-agent",
                "--targets",     prof.remote_targets,
                "--secret-file", prof.remote_secret_file,
                "--host-id",     host_id,
                "--stdio",
            });
        },
        .ssh => |ssh| blk: {
            const cmd = try std.fmt.allocPrint(
                allocator,
                "{s} probe-agent --targets {s} --secret-file {s} --host-id {s} --stdio",
                .{
                    try host_spawn.quote(allocator, ssh.emulator),
                    try host_spawn.quote(allocator, prof.remote_targets),
                    try host_spawn.quote(allocator, prof.remote_secret_file),
                    try host_spawn.quote(allocator, host_id),
                },
            );
            break :blk allocator.dupe([]const u8, &.{ ssh.program, "-T", ssh.destination, cmd });
        },
    };
}

fn spawnAgent(io: std.Io, prof: anytype, host_id: []const u8) !std.process.Child {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const argv = try agentArgv(arena.allocator(), io, prof, host_id);
    return std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .create_no_window = true,
    });
}
