//! Session control branch and fork commands (Slice 20.4).
const std = @import("std");
const proto = @import("ra8_rpc").session.rpc;
const Client = @import("client.zig").Client;

pub const BranchCommand = union(enum) {
    branch_ls,
    branch_switch: u32,
    branch_rm: struct { id: u32, confirm: bool },
    fork_confirm,
    fork_cancel,
    fork_status,
};

pub fn parseBranch(args: []const []const u8) !BranchCommand {
    if (args.len == 0) return error.BadArguments;
    if (std.mem.eql(u8, args[0], "ls")) {
        if (args.len != 1) return error.BadArguments;
        return .branch_ls;
    }
    if (std.mem.eql(u8, args[0], "switch")) {
        if (args.len != 2) return error.BadArguments;
        const id = try std.fmt.parseInt(u32, args[1], 0);
        return .{ .branch_switch = id };
    }
    if (std.mem.eql(u8, args[0], "rm")) {
        if (args.len < 2 or args.len > 3) return error.BadArguments;
        const id = try std.fmt.parseInt(u32, args[1], 0);
        var confirm = false;
        if (args.len == 3) {
            if (!std.mem.eql(u8, args[2], "--confirm")) return error.BadArguments;
            confirm = true;
        }
        return .{ .branch_rm = .{ .id = id, .confirm = confirm } };
    }
    return error.UnknownCommand;
}

pub fn parseFork(args: []const []const u8) !BranchCommand {
    if (args.len != 1) return error.BadArguments;
    if (std.mem.eql(u8, args[0], "confirm")) return .fork_confirm;
    if (std.mem.eql(u8, args[0], "cancel")) return .fork_cancel;
    if (std.mem.eql(u8, args[0], "status")) return .fork_status;
    return error.UnknownCommand;
}

pub fn perform(client: *Client, w: anytype, json: bool, cmd: BranchCommand) !void {
    switch (cmd) {
        .branch_ls => try listBranches(client, w, json),
        .branch_switch => |id| try switchBranch(client, w, json, id),
        .branch_rm => |rm| try removeBranch(client, w, json, rm.id, rm.confirm),
        .fork_confirm => try confirmFork(client, w, json),
        .fork_cancel => try cancelFork(client, w, json),
        .fork_status => try statusFork(client, w, json),
    }
}

/// The frozen record.ForkReason value as a word; the base line reads "root".
fn reasonName(reason: u8) []const u8 {
    return switch (reason) {
        0 => "root",
        1 => "writes",
        2 => "taps",
        3 => "buttons",
        4 => "keystrokes",
        5 => "plug_unplug_fault",
        6 => "camera_change",
        7 => "skip_bkpt",
        8 => "load",
        else => "unknown",
    };
}

fn listBranches(client: *Client, w: anytype, json: bool) !void {
    const list = try client.call(proto.BranchList, proto.CoreOnly, .branch_list, .{ .core = .cpu0 });
    const n = proto.branch_wire.count(list.bytes);
    if (json) {
        try w.writeAll("{\"branches\":[");
        for (0..n) |idx| {
            const it = proto.branch_wire.get(list.bytes, idx);
            if (idx > 0) try w.writeAll(",");
            try w.print(
                "{{\"id\":{d},\"parent\":{d},\"fork_r\":{d},\"recorded_end_r\":{d},\"child_count\":{d},\"reason\":\"{s}\",\"live\":{s},\"kept\":{s},\"pinned\":{s}}}",
                .{
                    it.id,
                    it.parent,
                    it.fork_r,
                    it.recorded_end_r,
                    it.child_count,
                    reasonName(it.reason),
                    if (it.flags & 1 != 0) "true" else "false",
                    if (it.flags & 2 != 0) "true" else "false",
                    if (it.flags & 4 != 0) "true" else "false",
                },
            );
        }
        try w.writeAll("]}\n");
        return;
    }

    for (0..n) |idx| {
        const it = proto.branch_wire.get(list.bytes, idx);
        try w.print("branch {d}: parent {d}, fork {d}, end {d}, children {d} ({s})", .{
            it.id,
            it.parent,
            it.fork_r,
            it.recorded_end_r,
            it.child_count,
            reasonName(it.reason),
        });
        if (it.flags & 1 != 0) try w.writeAll(", live");
        if (it.flags & 2 != 0) try w.writeAll(", kept");
        if (it.flags & 4 != 0) try w.writeAll(", pinned");
        try w.writeAll("\n");
    }
}

fn switchBranch(client: *Client, w: anytype, json: bool, id: u32) !void {
    _ = try client.call(proto.Ack, proto.BranchSwitch, .branch_switch, .{ .branch = id });
    if (json) {
        try w.print("{{\"switched\":{d}}}\n", .{id});
    } else {
        try w.print("switched to branch {d}\n", .{id});
    }
}

fn removeBranch(client: *Client, w: anytype, json: bool, id: u32, confirm: bool) !void {
    const flag: u8 = if (confirm) 1 else 0;
    _ = try client.call(proto.Ack, proto.BranchDelete, .branch_delete, .{ .branch = id, .confirm = flag });
    if (json) {
        try w.print("{{\"removed\":{d}}}\n", .{id});
    } else {
        try w.print("removed branch {d}\n", .{id});
    }
}

fn confirmFork(client: *Client, w: anytype, json: bool) !void {
    _ = try client.call(proto.Ack, proto.BranchConfirmFork, .branch_confirm_fork, .{});
    if (json) {
        try w.writeAll("{\"fork\":\"confirmed\"}\n");
    } else {
        try w.writeAll("fork confirmed\n");
    }
}

fn cancelFork(client: *Client, w: anytype, json: bool) !void {
    _ = try client.call(proto.Ack, proto.BranchCancelFork, .branch_cancel_fork, .{});
    if (json) {
        try w.writeAll("{\"fork\":\"canceled\"}\n");
    } else {
        try w.writeAll("fork canceled\n");
    }
}

fn statusFork(client: *Client, w: anytype, json: bool) !void {
    const st = try client.call(proto.ForkStatus, proto.CoreOnly, .branch_status, .{ .core = .cpu0 });
    if (json) {
        if (st.pending != 0) {
            try w.print(
                "{{\"pending\":true,\"branch\":{d},\"r\":{d},\"reason\":\"{s}\"}}\n",
                .{ st.branch, st.r, reasonName(st.reason) },
            );
        } else {
            try w.writeAll("{\"pending\":false}\n");
        }
    } else {
        if (st.pending != 0) {
            try w.print("fork pending at branch {d} r {d} (reason {s})\n", .{ st.branch, st.r, reasonName(st.reason) });
        } else {
            try w.writeAll("no fork pending\n");
        }
    }
}
