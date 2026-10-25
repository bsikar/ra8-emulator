//! Session control register and memory write commands.
const std = @import("std");
const proto = @import("ra8_rpc").session.rpc;
const Client = @import("client.zig").Client;

const intervene = @import("ra8_rpc").session.intervene;

pub const WriteCommand = union(enum) {
    write_reg: struct { reg: proto.Register, value: u32 },
    write_mem: struct { addr: u32, bytes: []const u8 },
    /// `console TEXT`: bytes typed into the board's console UART.
    console: []const u8,
    /// `skip-bkpt`: step CPU0 over the BKPT it is stopped on.
    skip_bkpt,
};

/// The machine-changing words: write-reg (or reg NAME VALUE), write-mem
/// (or poke ADDRESS HEX), console TEXT and skip-bkpt. Null for any other.
pub fn parseWord(allocator: std.mem.Allocator, name: []const u8, args: []const []const u8) !?WriteCommand {
    const eql = std.mem.eql;
    if (eql(u8, name, "write-reg") or (eql(u8, name, "reg") and args.len == 2)) return try parseReg(args);
    if (eql(u8, name, "write-mem") or (eql(u8, name, "poke") and args.len == 2)) return try parseMem(allocator, args);
    if (eql(u8, name, "console")) return if (args.len == 1) .{ .console = args[0] } else error.BadArguments;
    if (eql(u8, name, "skip-bkpt")) return if (args.len == 0) .skip_bkpt else error.BadArguments;
    return null;
}

pub fn parseReg(args: []const []const u8) !WriteCommand {
    if (args.len != 2) return error.BadArguments;
    const reg = std.meta.stringToEnum(proto.Register, args[0]) orelse return error.UnknownRegister;
    const val = try std.fmt.parseInt(u32, args[1], 0);
    return .{ .write_reg = .{ .reg = reg, .value = val } };
}

pub fn parseMem(allocator: std.mem.Allocator, args: []const []const u8) !WriteCommand {
    if (args.len != 2) return error.BadArguments;
    const addr = try std.fmt.parseInt(u32, args[0], 0);
    const hex = if (std.mem.startsWith(u8, args[1], "0x") or std.mem.startsWith(u8, args[1], "0X"))
        args[1][2..]
    else
        args[1];
    if (hex.len == 0 or hex.len % 2 != 0) return error.BadHexLength;
    const byte_count = hex.len / 2;
    const bytes = try allocator.alloc(u8, byte_count);
    errdefer allocator.free(bytes);
    for (bytes, 0..) |*b, i| {
        b.* = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch return error.BadHexByte;
    }
    return .{ .write_mem = .{ .addr = addr, .bytes = bytes } };
}

pub fn perform(client: *Client, w: anytype, json: bool, cmd: WriteCommand) !void {
    switch (cmd) {
        .write_reg => |reg| {
            _ = try client.call(proto.Ack, proto.WriteRegister, .write_register, .{
                .core = .cpu0,
                .register = reg.reg,
                .value = reg.value,
            });
            if (json) {
                try w.print("{{\"write_reg\":{{\"register\":\"{s}\",\"value\":{d}}}}}\n", .{ @tagName(reg.reg), reg.value });
            } else {
                try w.print("register {s} set to 0x{x:0>8}\n", .{ @tagName(reg.reg), reg.value });
            }
        },
        .write_mem => |mem| {
            _ = try client.call(proto.Ack, proto.WriteMemory, .write_memory, .{
                .core = .cpu0,
                .address = mem.addr,
                .bytes = mem.bytes,
            });
            if (json) {
                try w.print("{{\"write_mem\":{{\"address\":{d},\"length\":{d}}}}}\n", .{ mem.addr, mem.bytes.len });
            } else {
                try w.print("memory at 0x{x:0>8} ({d} bytes) written\n", .{ mem.addr, mem.bytes.len });
            }
        },
        .console => |text| {
            _ = try client.call(proto.Ack, intervene.ConsoleInput, .console_input, .{ .core = .cpu0, .bytes = text });
            if (json) try w.print("{{\"console\":{d}}}\n", .{text.len}) else try w.print("console: {d} bytes typed\n", .{text.len});
        },
        .skip_bkpt => {
            _ = try client.call(proto.Ack, proto.CoreOnly, .skip_bkpt, .{ .core = .cpu0 });
            if (json) try w.writeAll("{\"skip_bkpt\":true}\n") else try w.writeAll("BKPT skipped\n");
        },
    }
}
