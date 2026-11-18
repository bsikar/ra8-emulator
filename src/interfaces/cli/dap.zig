//! `ra8_emulator dap PORT [IMAGE]`: one DAP client on loopback TCP.
//! Launch supplies `program`; attach uses the optional preloaded IMAGE.
const std = @import("std");

const dap = @import("ra8_dap");
const image_file = @import("image_file.zig");
const machine_mod = @import("ra8_chip").core.machine;
const ready = @import("ra8_host").sock.ready;
const session = @import("ra8_session");

pub const Owner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    machine: *const machine_mod.Machine = &machine_mod.catalog.ra8p1,
    harness: ?session.harness.Harness = null,

    pub fn open(context: *anyopaque, path: []const u8) anyerror!dap.adapter.Target {
        const self: *Owner = @ptrCast(@alignCast(context));
        if (self.harness != null) return error.TargetAlreadyLoaded;
        const bytes = try image_file.read(self.io, self.allocator, path);
        defer self.allocator.free(bytes);
        self.harness = try session.harness.open(self.allocator, self.io, .{
            .elf_bytes = bytes,
            .machine = self.machine,
            .history_frames = 0,
        });
        const h = &self.harness.?;
        h.session().history = null;
        return .{ .session = h.session(), .images = .{ h.image(), null } };
    }
};

/// What `ra8_emulator dap [--part NAME] PORT [IMAGE]` asked for.
pub const Args = struct {
    machine: *const machine_mod.Machine = &machine_mod.catalog.ra8p1,
    port: u16,
    image: ?[]const u8 = null,
};

/// The request `argv` makes, or null for a malformed line. `--part` and
/// `--device` are taken only after the subcommand and only with a value.
pub fn parseArgs(argv: []const []const u8, machines: []const *const machine_mod.Machine) ?Args {
    var machine: *const machine_mod.Machine = &machine_mod.catalog.ra8p1;
    var rest: [4][]const u8 = undefined;
    var len: usize = 0;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        if (i >= 2 and isPartFlag(argv[i])) {
            i += 1;
            if (i >= argv.len) return null;
            machine = machine_mod.catalog.findIn(machines, argv[i]) orelse return null;
        } else {
            if (len == rest.len) return null;
            rest[len] = argv[i];
            len += 1;
        }
    }
    if (len < 3) return null;
    const port = std.fmt.parseInt(u16, rest[2], 10) catch return null;
    return .{ .machine = machine, .port = port, .image = if (len == 4) rest[3] else null };
}

fn isPartFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--part") or std.mem.eql(u8, arg, "--device");
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    const args = parseArgs(argv, &machine_mod.catalog.all) orelse {
        std.debug.print("usage: ra8_emulator dap [--part NAME] PORT [IMAGE]\n", .{});
        return 1;
    };
    var owner: Owner = .{ .allocator = allocator, .io = io, .machine = args.machine };
    defer if (owner.harness) |*h| h.deinit();
    var adapter: dap.adapter.Adapter = .{
        .allocator = allocator,
        .opener = .{ .context = &owner, .openFn = Owner.open },
    };
    defer adapter.deinit();
    if (args.image) |path| adapter.target = try Owner.open(&owner, path);
    try listen(allocator, io, args.port, &adapter);
    return 0;
}

pub fn listen(allocator: std.mem.Allocator, io: std.Io, port: u16, adapter: *dap.adapter.Adapter) !void {
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    std.debug.print("dap: listening on tcp:{f}\n", .{server.socket.address});
    const stream = try server.accept(io);
    defer stream.close(io);
    try serve(allocator, io, stream, adapter);
}

fn serve(allocator: std.mem.Allocator, io: std.Io, stream: std.Io.net.Stream, adapter: *dap.adapter.Adapter) !void {
    var decoder: dap.framing.Decoder = .{};
    var reply: std.Io.Writer.Allocating = .init(allocator);
    defer reply.deinit();
    var bytes: [4096]u8 = undefined;
    while (!adapter.closed) {
        const available = try ready.wait(io, stream.socket.handle, if (adapter.pending != null) 0 else 20);
        if (available.any()) {
            var buffers = [_][]u8{&bytes};
            const got = try stream.readWithControl(io, &buffers, &.{});
            if (got.data_len == 0) return;
            for (bytes[0..got.data_len]) |byte| {
                if (try decoder.push(byte)) |message| try adapter.request(message, &reply.writer);
                if (adapter.closed) break;
            }
        }
        if (!adapter.closed) try adapter.pump(&reply.writer);
        if (reply.written().len != 0) {
            try ready.sendAll(io, stream.socket.handle, reply.written(), 2000);
            reply.clearRetainingCapacity();
        }
    }
}
