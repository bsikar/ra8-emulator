//! Session control register, memory, and variable write commands.
const std = @import("std");
const rpc_session = @import("ra8_rpc").session;
const proto = rpc_session.rpc;
const set_var_wire = rpc_session.set_var_wire;
const Client = @import("client.zig").Client;

const intervene = rpc_session.intervene;

pub const WriteCommand = union(enum) {
    write_reg: struct { reg: proto.Register, value: u32 },
    write_mem: struct { addr: u32, bytes: []const u8 },
    set_var: struct { frame: u32, name: []const u8, value: []const u8 },
    /// `console TEXT`: bytes typed into the board's console UART.
    console: []const u8,
    /// `skip-bkpt`: step CPU0 over the BKPT it is stopped on.
    skip_bkpt,
};

/// The machine-changing words: write-reg (or reg NAME VALUE), write-mem
/// (or poke ADDRESS HEX), set [--frame N] NAME=VALUE, console TEXT and skip-bkpt.
/// Returns null for any other word.
pub fn parseWord(allocator: std.mem.Allocator, name: []const u8, args: []const []const u8) !?WriteCommand {
    const eql = std.mem.eql;
    if (eql(u8, name, "write-reg") or (eql(u8, name, "reg") and args.len == 2)) return try parseReg(args);
    if (eql(u8, name, "write-mem") or (eql(u8, name, "poke") and args.len == 2)) return try parseMem(allocator, args);
    if (eql(u8, name, "set")) return try parseSet(args);
    if (eql(u8, name, "console")) return if (args.len == 1) .{ .console = args[0] } else error.BadArguments;
    if (eql(u8, name, "skip-bkpt")) return if (args.len == 0) .skip_bkpt else error.BadArguments;
    return null;
}

/// Parse `set [--frame N] NAME=VALUE`.
pub fn parseSet(args: []const []const u8) !WriteCommand {
    var frame: u32 = 0;
    var assignment: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--frame")) {
            if (i + 1 >= args.len) return error.BadArguments;
            i += 1;
            frame = std.fmt.parseInt(u32, args[i], 0) catch return error.BadArguments;
            continue;
        }
        if (assignment != null) return error.BadArguments;
        assignment = args[i];
    }
    const text = assignment orelse return error.BadArguments;
    const eq = std.mem.indexOfScalar(u8, text, '=') orelse return error.BadArguments;
    const var_name = text[0..eq];
    const value = text[eq + 1 ..];
    if (var_name.len == 0 or value.len == 0) return error.BadArguments;
    return .{ .set_var = .{ .frame = frame, .name = var_name, .value = value } };
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

pub fn perform(client: *Client, w: anytype, json: bool, cmd: WriteCommand) !u8 {
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
        .set_var => |s| return try performSetVar(client, w, json, s.frame, s.name, s.value),
        .console => |text| {
            _ = try client.call(proto.Ack, intervene.ConsoleInput, .console_input, .{ .core = .cpu0, .bytes = text });
            if (json) try w.print("{{\"console\":{d}}}\n", .{text.len}) else try w.print("console: {d} bytes typed\n", .{text.len});
        },
        .skip_bkpt => {
            _ = try client.call(proto.Ack, proto.CoreOnly, .skip_bkpt, .{ .core = .cpu0 });
            if (json) try w.writeAll("{\"skip_bkpt\":true}\n") else try w.writeAll("BKPT skipped\n");
        },
    }
    return 0;
}

fn performSetVar(client: *Client, w: anytype, json: bool, frame: u32, name: []const u8, value: []const u8) !u8 {
    const reply = try client.call(set_var_wire.SetVarReply, set_var_wire.SetVarArgs, .set_var, .{
        .core = .cpu0,
        .frame = frame,
        .name = name,
        .value = value,
    });
    if (reply.status == .ok) {
        if (json) {
            try w.writeAll("{\"set_var\":{\"name\":");
            try writeJsonString(w, name);
            try w.writeAll(",\"value\":");
            try writeJsonString(w, value);
            try w.print(",\"scope\":\"{s}\"", .{@tagName(reply.scope)});
            if (reply.in_register != 0xff) {
                try w.print(",\"register\":\"r{d}\"", .{reply.in_register});
            } else {
                try w.print(",\"address\":{d}", .{reply.address});
            }
            try w.print(",\"size\":{d}}}}}\n", .{reply.size});
        } else if (reply.in_register != 0xff) {
            try w.print("{s} = {s} ({s}, r{d}, {d} bytes)\n", .{ name, value, @tagName(reply.scope), reply.in_register, reply.size });
        } else {
            try w.print("{s} = {s} ({s}, 0x{x:0>8}, {d} bytes)\n", .{ name, value, @tagName(reply.scope), reply.address, reply.size });
        }
        return 0;
    }
    if (json) {
        try w.writeAll("{\"error\":");
        try writeJsonString(w, reply.message);
        try w.print(",\"status\":\"{s}\",\"scope\":\"{s}\",\"name\":", .{ @tagName(reply.status), @tagName(reply.scope) });
        try writeJsonString(w, name);
        try w.writeAll("}\n");
    } else {
        try w.print("error: {s}: {s}\n", .{ name, reply.message });
    }
    return 1;
}

fn writeJsonString(w: anytype, text: []const u8) !void {
    try w.writeByte('"');
    for (text) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}
