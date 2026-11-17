//! Bounded annotated disassembly from the backend that owns the loaded ELF.
const std = @import("std");

const Client = @import("client.zig").Client;
const proto = @import("ra8_rpc").session.rpc;

pub fn parse(args: []const []const u8) !proto.Disassemble {
    if (args.len < 1 or args.len > 2) return error.BadArguments;
    const address = try std.fmt.parseInt(u32, args[0], 0);
    const count = if (args.len == 2) try std.fmt.parseInt(u16, args[1], 0) else 16;
    if (count == 0 or count > 64 or address & 1 != 0) return error.BadArguments;
    return .{ .core = .cpu0, .address = address, .count = count };
}

pub fn run(client: *Client, out: *std.Io.Writer, json: bool, args: proto.Disassemble) !void {
    const reply = try client.call(proto.Disassembly, proto.Disassemble, .disassemble, args);
    try print(out, json, reply);
}

pub fn print(out: *std.Io.Writer, json: bool, reply: proto.Disassembly) !void {
    if (json) {
        try std.json.Stringify.value(reply, .{}, out);
        try out.writeByte('\n');
    } else try out.writeAll(reply.text);
}
