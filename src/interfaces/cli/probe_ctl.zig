const std = @import("std");

pub const Request = struct { host: []const u8, port: u16, action: Action, address: u32 = 0, length: u16 = 0 };
pub const Action = enum { capabilities, registers, read, halt, step, cont };

pub fn parse(argv: []const []const u8) !Request {
    if (argv.len < 6 or
        !std.mem.eql(u8, argv[1], "ctl") or
        !std.mem.eql(u8, argv[2], "probe")) return error.BadArguments;
    const port = try std.fmt.parseInt(u16, argv[4], 10);
    const action = if (std.mem.eql(u8, argv[5], "capabilities"))
        Action.capabilities
    else if (std.mem.eql(u8, argv[5], "registers"))
        Action.registers
    else if (std.mem.eql(u8, argv[5], "read"))
        Action.read
    else if (std.mem.eql(u8, argv[5], "halt"))
        Action.halt
    else if (std.mem.eql(u8, argv[5], "resume"))
        Action.cont
    else if (std.mem.eql(u8, argv[5], "step"))
        Action.step
    else
        return error.UnknownAction;
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

pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    _ = allocator;
    const request = parse(argv) catch |err| {
        std.debug.print(
            "ctl probe: {s}\n" ++
                "usage: ra8_emulator ctl probe HOST PORT capabilities|registers|read ADDRESS " ++
                "LENGTH|halt|step|resume\n",
            .{@errorName(err)},
        );
        return 2;
    };
    var stdout = std.Io.File.stdout().writerStreaming(io, &.{});
    try execute(io, request, &stdout.interface);
    try stdout.interface.flush();
    return 0;
}

/// The inventory adapter uses the same real-board RSP transport as direct probe control.
pub fn execute(io: std.Io, request: Request, output: *std.Io.Writer) !void {
    if (request.action == .capabilities) return executeInner(io, request, output);
    const Result = union(enum) { done: anyerror!void, timeout: anyerror!void };
    var results: [2]Result = undefined;
    var select: std.Io.Select(Result) = .init(io, &results);
    defer _ = select.cancel();
    try select.concurrent(.done, executeInner, .{ io, request, output });
    try select.concurrent(.timeout, deadline, .{io});
    switch (try select.await()) {
        .done => |result| try result,
        .timeout => return error.Timeout,
    }
}

fn deadline(io: std.Io) anyerror!void {
    try io.sleep(.fromSeconds(5), .awake);
}

fn executeInner(io: std.Io, request: Request, output: *std.Io.Writer) anyerror!void {
    if (request.action == .capabilities) {
        try output.print(
            "{s}",
            .{
                "{\"registers\":true,\"memory_read\":true,\"halt\":true,\"resume\":true,\"step\":" ++
                    "true,\"speed_control\":false,\"idle_fast_forward\":false,\"fault_injection\":fal" ++
                    "se}\n",
            },
        );
        return;
    }
    const host = try std.Io.net.HostName.init(request.host);
    var stream = try host.connect(io, request.port, .{ .mode = .stream });
    defer stream.close(io);
    var send_buffer: [4096]u8 = undefined;
    var stream_writer = stream.writer(io, &send_buffer);
    const writer = &stream_writer.interface;
    if (request.action == .cont or request.action == .step) {
        try sendPacket(writer, if (request.action == .step) "s" else "c");
        try output.writeAll("{\"sent\":true}\n");
        return;
    }
    var receive_buffer: [4096]u8 = undefined;
    var stream_reader = stream.reader(io, &receive_buffer);
    const reader = &stream_reader.interface;
    var response: [4096]u8 = undefined;
    switch (request.action) {
        .registers => {
            const body = try exchange(reader, writer, "g", &response);
            try std.json.Stringify.value(.{ .registers_rsp = body }, .{}, output);
            try output.writeByte('\n');
        },
        .read => {
            var command: [32]u8 = undefined;
            const text = try std.fmt.bufPrint(&command, "m{X},{X}", .{ request.address, request.length });
            const body = try exchange(reader, writer, text, &response);
            try output.print(
                "{{\"address\":{d},\"length\":{d},\"memory_rsp\":\"{s}\"}}\n",
                .{ request.address, request.length, body },
            );
        },
        .halt => {
            try writer.writeByte(3);
            try writer.flush();
            const body = try receivePacket(reader, writer, &response);
            try std.json.Stringify.value(.{ .halted = true, .stop_rsp = body }, .{}, output);
            try output.writeByte('\n');
        },
        else => unreachable,
    }
    return;
}

fn exchange(reader: anytype, writer: anytype, command: []const u8, storage: []u8) ![]const u8 {
    try sendPacket(writer, command);
    return receivePacket(reader, writer, storage);
}

fn receivePacket(reader: anytype, writer: anytype, storage: []u8) ![]const u8 {
    while (true) {
        const byte = try reader.takeByte();
        if (byte != '$') continue;
        var length: usize = 0;
        while (true) {
            const next = try reader.takeByte();
            if (next == '#') break;
            if (length == storage.len) return error.ResponseTooLong;
            storage[length] = next;
            length += 1;
        }
        const high = try std.fmt.charToDigit(try reader.takeByte(), 16);
        const low = try std.fmt.charToDigit(try reader.takeByte(), 16);
        var checksum: u8 = 0;
        for (storage[0..length]) |value| {
            checksum +%= value;
        }
        if (checksum != high * 16 + low) return error.BadChecksum;
        try writer.writeAll("+");
        try writer.flush();
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
    for (payload) |byte| {
        checksum +%= byte;
    }
    const chars = "0123456789abcdef";
    framed[payload.len + 2] = chars[checksum >> 4];
    framed[payload.len + 3] = chars[checksum & 0xf];
    try writer.writeAll(framed[0 .. payload.len + 4]);
    try writer.flush();
}
