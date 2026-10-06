const std = @import("std");

pub const Request = struct { host: []const u8, port: u16, action: Action, address: u32 = 0, length: u16 = 0 };
pub const Action = enum { capabilities, registers, read, halt, step, cont };

pub fn parse(argv: []const []const u8) !Request {
    if (argv.len < 6 or !std.mem.eql(u8, argv[1], "ctl") or !std.mem.eql(u8, argv[2], "probe")) return error.BadArguments;
    const port = try std.fmt.parseInt(u16, argv[4], 10);
    const action = if (std.mem.eql(u8, argv[5], "capabilities")) Action.capabilities else if (std.mem.eql(u8, argv[5], "registers")) Action.registers else if (std.mem.eql(u8, argv[5], "read")) Action.read else if (std.mem.eql(u8, argv[5], "halt")) Action.halt else if (std.mem.eql(u8, argv[5], "resume")) Action.cont else if (std.mem.eql(u8, argv[5], "step")) Action.step else return error.UnknownAction;
    var request = Request{ .host = argv[3], .port = port, .action = action };
    if (action == .read) {
        if (argv.len != 8) return error.BadArguments;
        request.address = try std.fmt.parseInt(u32, argv[6], 0);
        request.length = try std.fmt.parseInt(u16, argv[7], 10);
        if (request.length == 0 or request.length > 256) return error.BadLength;
    } else if (argv.len != 6) return error.BadArguments;
    if (port == 0) return error.BadPort;
    return request;
}

pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) !u8 {
    const request = parse(argv) catch |err| {
        std.debug.print("ctl probe: {s}\nusage: ra8_emulator ctl probe HOST PORT capabilities|registers|read ADDRESS LENGTH|halt|step|resume\n", .{@errorName(err)});
        return 2;
    };
    if (request.action == .capabilities) {
        try std.io.getStdOut().writer().writeAll("{\"registers\":true,\"memory_read\":true,\"halt\":true,\"resume\":true,\"step\":true,\"speed_control\":false,\"idle_fast_forward\":false,\"fault_injection\":false}\n");
        return 0;
    }
    var stream = try std.net.tcpConnectToHost(allocator, request.host, request.port);
    defer stream.close();
    if (request.action == .cont or request.action == .step) {
        try sendPacket(stream.writer(), if (request.action == .step) "s" else "c");
        return 0;
    }
    var response: [4096]u8 = undefined;
    const writer = stream.writer();
    const reader = stream.reader();
    switch (request.action) {
        .registers => {
            const body = try exchange(reader, writer, "g", &response);
            try std.io.getStdOut().writer().print("{{\"registers_rsp\":\"{s}\"}}\n", .{body});
        },
        .read => {
            var command: [32]u8 = undefined;
            const text = try std.fmt.bufPrint(&command, "m{X},{X}", .{ request.address, request.length });
            const body = try exchange(reader, writer, text, &response);
            try std.io.getStdOut().writer().print("{{\"address\":{d},\"length\":{d},\"memory_rsp\":\"{s}\"}}\n", .{ request.address, request.length, body });
        },
        .halt => {
            try writer.writeByte(3);
            const body = try receivePacket(reader, writer, &response);
            try std.io.getStdOut().writer().print("{{\"halted\":true,\"stop_rsp\":\"{s}\"}}\n", .{body});
        },
        else => unreachable,
    }
    return 0;
}

fn exchange(reader: anytype, writer: anytype, command: []const u8, storage: []u8) ![]const u8 {
    try sendPacket(writer, command);
    return receivePacket(reader, writer, storage);
}

fn receivePacket(reader: anytype, writer: anytype, storage: []u8) ![]const u8 {
    while (true) {
        const byte = try reader.readByte();
        if (byte != '$') continue;
        var length: usize = 0;
        while (true) {
            const next = try reader.readByte();
            if (next == '#') break;
            if (length == storage.len) return error.ResponseTooLong;
            storage[length] = next;
            length += 1;
        }
        _ = try reader.readByte();
        _ = try reader.readByte();
        try writer.writeAll("+");
        return storage[0..length];
    }
}

fn sendPacket(writer: anytype, payload: []const u8) !void {
    var framed: [4096]u8 = undefined;
    if (payload.len + 4 > framed.len) return error.RequestTooLong;
    framed[0] = '$';
    @memcpy(framed[1 .. payload.len + 1], payload);
    framed[payload.len + 1] = '#';
    var checksum: u8 = 0;
    for (payload) |byte| checksum +%= byte;
    const chars = "0123456789abcdef";
    framed[payload.len + 2] = chars[checksum >> 4];
    framed[payload.len + 3] = chars[checksum & 0xf];
    try writer.writeAll(framed[0 .. payload.len + 4]);
}
