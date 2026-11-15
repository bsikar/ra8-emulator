//! A CLI operation reserves, operates and releases on one connection.
const std = @import("std");

const Client = @import("client.zig").Client;
const model = @import("ra8_host").targets;
const proto = @import("ra8_rpc").session.rpc;
const wire = @import("ra8_rpc").targets_wire;

pub const Command = union(enum) {
    list,
    use: struct { selection: wire.Selection, actions: [16]model.Action, count: usize },
};

pub fn parse(args: []const []const u8) !Command {
    if (args.len == 1 and std.mem.eql(u8, args[0], "list")) return .list;
    if (args.len < 7 or args.len > 22 or !std.mem.eql(u8, args[0], "use")) return error.BadArguments;
    var actions: [16]model.Action = undefined;
    for (args[6..], 0..) |word, i| {
        actions[i] = std.meta.stringToEnum(model.Action, word) orelse return error.BadArguments;
    }
    const generation = try std.fmt.parseInt(u64, args[4], 10);
    if (generation == 0) return error.BadArguments;
    return .{ .use = .{ .selection = .{
        .host_id = args[1],
        .probe_id = args[2],
        .board_id = args[3],
        .generation = generation,
        .disambiguation = if (std.mem.eql(u8, args[5], "-")) "" else args[5],
    }, .actions = actions, .count = args.len - 6 } };
}

pub fn run(client: *Client, output: *std.Io.Writer, command: Command) !void {
    switch (command) {
        .list => {
            const reply = try client.callCode(wire.Text, struct {}, @backingInt(wire.Method.list), .{});
            try output.print("{s}\n", .{reply.json});
        },
        .use => |use| {
            _ = try client.callCode(proto.Ack, wire.Selection, @backingInt(wire.Method.reserve), use.selection);
            // Client.close releases the lease even when an operation fails.
            for (use.actions[0..use.count]) |action| {
                const operation = wire.operation(use.selection, action);
                const reply = try client.callCode(wire.Text, wire.Perform, @backingInt(wire.Method.perform), operation);
                try output.print("{s}\n", .{reply.json});
                try output.flush();
            }
            _ = try client.callCode(proto.Ack, struct {}, @backingInt(wire.Method.release), .{});
        },
    }
}
