//! Shell branch and fork coordinator (Slice 20.4): manages fork confirmation
//! and branch list interactions over RPC Link.
const std = @import("std");
const proto = @import("ra8_rpc").session.rpc;
const session_link = @import("../session_link.zig");
const Link = session_link.Link;
const branch_list = @import("../ui/branch_list.zig");
const fork_banner = @import("../ui/fork_banner.zig");
const geom = @import("../geom.zig");
const Rect = geom.Rect;

pub const State = struct {
    fork_pending: bool = false,
    first_fork_confirmed: bool = false,
    items_buf: [32]branch_list.Item = undefined,
    items_len: usize = 0,
    confirming_id: ?u32 = null,
    list_open: bool = false,

    pub fn items(self: *const State) []const branch_list.Item {
        return self.items_buf[0..self.items_len];
    }

    pub fn handleStatus(self: *State, status: proto.ForkStatus) void {
        self.fork_pending = (status.pending != 0);
    }

    pub fn handleList(self: *State, list: proto.BranchList) void {
        const count = @min(proto.branch_wire.count(list.bytes), self.items_buf.len);
        for (0..count) |idx| {
            const it = proto.branch_wire.get(list.bytes, idx);
            self.items_buf[idx] = .{
                .id = it.id,
                .parent = it.parent,
                .fork_r = it.fork_r,
                .end_r = it.recorded_end_r,
                .child_count = it.child_count,
                .is_live = (it.flags & 1 != 0),
                .is_kept = (it.flags & 2 != 0),
                .is_pinned = (it.flags & 4 != 0),
            };
        }
        self.items_len = count;
    }

    pub fn onBannerAction(self: *State, link: *Link, action: fork_banner.Action) !void {
        switch (action) {
            .confirm => {
                _ = try link.send(proto.BranchConfirmFork, .branch_confirm_fork, .{});
                self.fork_pending = false;
                self.first_fork_confirmed = true;
            },
            .cancel => {
                _ = try link.send(proto.BranchCancelFork, .branch_cancel_fork, .{});
                self.fork_pending = false;
            },
            .none => {},
        }
    }

    pub fn onListAction(self: *State, link: *Link, action: branch_list.Action) !void {
        switch (action) {
            .switch_branch => |id| {
                _ = try link.send(proto.BranchSwitch, .branch_switch, .{ .branch = id });
            },
            .request_delete => |id| {
                self.confirming_id = id;
            },
            .confirm_delete => |id| {
                _ = try link.send(proto.BranchDelete, .branch_delete, .{ .branch = id, .confirm = 1 });
                self.confirming_id = null;
            },
            .cancel_delete => {
                self.confirming_id = null;
            },
            .none => {},
        }
    }
};
