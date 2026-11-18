//! A CLI operation reserves, operates or flashes, and releases on one connection.
const std = @import("std");

const Client = @import("client.zig").Client;
const model = @import("ra8_host").targets;
const proto = @import("ra8_rpc").session.rpc;
const wire = @import("ra8_rpc").targets_wire;

pub const FlashRequest = struct {
    selection: wire.Selection,
    source: union(enum) { elf: []const u8, receipt: []const u8 },
    reset: bool = false,
    uart: bool = false,
};

pub const Command = union(enum) {
    list,
    use: struct { selection: wire.Selection, actions: [16]model.Action, count: usize },
    flash: FlashRequest,
};

pub fn parse(args: []const []const u8) !Command {
    if (args.len == 1 and std.mem.eql(u8, args[0], "list")) return .list;
    if (args.len >= 7 and std.mem.eql(u8, args[0], "flash")) return .{ .flash = try parseFlash(args, false) };
    if (args.len >= 7 and std.mem.eql(u8, args[0], "flash-receipt")) return .{ .flash = try parseFlash(args, true) };
    if (args.len < 7 or args.len > 22 or !std.mem.eql(u8, args[0], "use")) return error.BadArguments;
    var actions: [16]model.Action = undefined;
    for (args[6..], 0..) |word, i| {
        actions[i] = std.meta.stringToEnum(model.Action, word) orelse return error.BadArguments;
    }
    return .{ .use = .{
        .selection = try parseSelection(args[1..6]),
        .actions = actions,
        .count = args.len - 6,
    } };
}

fn parseSelection(words: []const []const u8) !wire.Selection {
    const generation = try std.fmt.parseInt(u64, words[3], 10);
    if (generation == 0) return error.BadArguments;
    return .{
        .host_id = words[0],
        .probe_id = words[1],
        .board_id = words[2],
        .generation = generation,
        .disambiguation = if (std.mem.eql(u8, words[4], "-")) "" else words[4],
    };
}

const FlashFlags = struct {
    path: ?[]const u8 = null,
    reset: bool = false,
    uart: bool = false,
};

fn parseFlash(args: []const []const u8, is_receipt: bool) !FlashRequest {
    const sel = try parseSelection(args[1..6]);
    var flags: FlashFlags = .{};
    const path_flag = if (is_receipt) "--receipt" else "--elf";
    var index: usize = 6;
    while (index < args.len) {
        index += try stepFlashFlag(&flags, args[index..], path_flag);
    }
    const chosen = flags.path orelse return error.BadArguments;
    if (chosen.len == 0) return error.BadArguments;
    return .{
        .selection = sel,
        .source = if (is_receipt) .{ .receipt = chosen } else .{ .elf = chosen },
        .reset = flags.reset,
        .uart = flags.uart,
    };
}

fn stepFlashFlag(flags: *FlashFlags, tail: []const []const u8, path_flag: []const u8) !usize {
    const word = tail[0];
    if (std.mem.eql(u8, word, path_flag) and flags.path == null and tail.len >= 2) {
        flags.path = tail[1];
        return 2;
    }
    if (std.mem.eql(u8, word, "--reset") and !flags.reset) {
        flags.reset = true;
        return 1;
    }
    if (std.mem.eql(u8, word, "--uart") and !flags.uart) {
        flags.uart = true;
        return 1;
    }
    return error.BadArguments;
}

pub fn run(client: *Client, output: *std.Io.Writer, command: Command) !void {
    switch (command) {
        .list => {
            const reply = try client.callCode(wire.Text, struct {}, @backingInt(wire.Method.list), .{});
            try output.print("{s}\n", .{reply.json});
        },
        .use => |use| {
            _ = try client.callCode(proto.Ack, wire.Selection, @backingInt(wire.Method.reserve), use.selection);
            for (use.actions[0..use.count]) |action| {
                const operation = wire.operation(use.selection, action);
                const reply = try client.callCode(wire.Text, wire.Perform, @backingInt(wire.Method.perform), operation);
                try output.print("{s}\n", .{reply.json});
                try output.flush();
            }
            _ = try client.callCode(proto.Ack, struct {}, @backingInt(wire.Method.release), .{});
        },
        .flash => return error.BadArguments,
    }
}

pub fn runWithIo(
    allocator: std.mem.Allocator,
    io: std.Io,
    client: *Client,
    output: *std.Io.Writer,
    command: Command,
) !void {
    switch (command) {
        .list, .use => return run(client, output, command),
        .flash => |req| {
            const json = switch (req.source) {
                .elf => |path| blk: {
                    const elf = try std.Io.Dir.cwd().readFileAlloc(
                        io,
                        path,
                        allocator,
                        .limited(@intCast(wire.max_flash_elf)),
                    );
                    defer allocator.free(elf);
                    break :blk try flashElfCall(allocator, client, req.selection, elf, req.reset, req.uart);
                },
                .receipt => |rec| try flashReceiptCall(allocator, client, req.selection, rec, req.reset, req.uart),
            };
            defer allocator.free(json);
            try output.print("{s}\n", .{json});
            try output.flush();
        },
    }
}

pub fn flashElfCall(
    allocator: std.mem.Allocator,
    client: *Client,
    sel: wire.Selection,
    elf: []const u8,
    do_reset: bool,
    do_uart: bool,
) ![]u8 {
    if (elf.len == 0 or elf.len > wire.max_flash_elf) return error.Oversize;
    client.wait_ms = @max(client.wait_ms, 90_000);
    _ = try client.callCode(proto.Ack, wire.Selection, @backingInt(wire.Method.reserve), sel);
    _ = try client.callCode(proto.Ack, wire.FlashBegin, @backingInt(wire.Method.flash_begin), .{
        .total_len = elf.len,
        .checksum = std.hash.Crc32.hash(elf),
    });
    var offset: usize = 0;
    while (offset < elf.len) : (offset += wire.max_chunk) {
        const stop = @min(offset + wire.max_chunk, elf.len);
        _ = try client.callCode(proto.Ack, wire.FlashChunk, @backingInt(wire.Method.flash_chunk), .{
            .offset = offset,
            .bytes = elf[offset..stop],
        });
    }
    const reply = try client.callCode(wire.Text, wire.FlashCommit, @backingInt(wire.Method.flash_commit), .{
        .host_id = sel.host_id,
        .probe_id = sel.probe_id,
        .board_id = sel.board_id,
        .generation = sel.generation,
        .disambiguation = sel.disambiguation,
        .reset = @intFromBool(do_reset),
        .uart = @intFromBool(do_uart),
    });
    const saved = try allocator.dupe(u8, reply.json);
    errdefer allocator.free(saved);
    _ = try client.callCode(proto.Ack, struct {}, @backingInt(wire.Method.release), .{});
    return saved;
}

pub fn flashReceiptCall(
    allocator: std.mem.Allocator,
    client: *Client,
    sel: wire.Selection,
    receipt: []const u8,
    do_reset: bool,
    do_uart: bool,
) ![]u8 {
    client.wait_ms = @max(client.wait_ms, 90_000);
    _ = try client.callCode(proto.Ack, wire.Selection, @backingInt(wire.Method.reserve), sel);
    const reply = try client.callCode(wire.Text, wire.FlashReceipt, @backingInt(wire.Method.flash_receipt), .{
        .host_id = sel.host_id,
        .probe_id = sel.probe_id,
        .board_id = sel.board_id,
        .generation = sel.generation,
        .disambiguation = sel.disambiguation,
        .receipt = receipt,
        .reset = @intFromBool(do_reset),
        .uart = @intFromBool(do_uart),
    });
    const saved = try allocator.dupe(u8, reply.json);
    errdefer allocator.free(saved);
    _ = try client.callCode(proto.Ack, struct {}, @backingInt(wire.Method.release), .{});
    return saved;
}
