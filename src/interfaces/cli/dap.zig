//! `ra8_emulator dap PORT [IMAGE]`: one DAP client on loopback TCP.
//! Launch supplies `program`; attach uses the optional preloaded IMAGE.
const std = @import("std");
const dap = @import("ra8_dap");
const session = @import("ra8_session");
const ready = @import("ra8_host").sock.ready;
const image_file = @import("image_file.zig");

pub const Owner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    harness: ?session.harness.Harness = null,

    pub fn open(context: *anyopaque, path: []const u8) anyerror!dap.adapter.Target {
        const self: *Owner = @ptrCast(@alignCast(context));
        if (self.harness != null) return error.TargetAlreadyLoaded;
        const bytes = try image_file.read(self.io, self.allocator, path);
        defer self.allocator.free(bytes);
        self.harness = try session.harness.open(self.allocator, self.io, .{ .elf_bytes = bytes, .history_frames = 0 });
        const h = &self.harness.?;
        h.session().history = null;
        return .{ .session = h.session(), .images = .{ h.image(), null } };
    }
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    if (argv.len < 3 or argv.len > 4) {
        std.debug.print("usage: ra8_emulator dap PORT [IMAGE]\n", .{});
        return 1;
    }
    const port = std.fmt.parseInt(u16, argv[2], 10) catch return 1;
    var owner: Owner = .{ .allocator = allocator, .io = io };
    defer if (owner.harness) |*h| h.deinit();
    var adapter: dap.adapter.Adapter = .{ .allocator = allocator, .opener = .{ .context = &owner, .openFn = Owner.open } };
    defer adapter.deinit();
    if (argv.len == 4) adapter.target = try Owner.open(&owner, argv[3]);
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    std.debug.print("dap: listening on tcp:{f}\n", .{server.socket.address});
    const stream = try server.accept(io);
    defer stream.close(io);
    try serve(allocator, io, stream, &adapter);
    return 0;
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
