//! Shell branch and fork coordinator (Slice 20.4): manages fork confirmation
//! and branch list interactions over RPC Link.
const std = @import("std");
const proto = @import("ra8_rpc").session.rpc;
const session_link = @import("../session_link.zig");
const Link = session_link.Link;
const branch_list = @import("../ui/branch_list.zig");
const branch_tree = @import("../branch_tree.zig");
const pane_layout = @import("../ui/pane_layout.zig");
const shell_frame = @import("../ui/shell/frame.zig");
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
    /// A list ask is due on the next attach.
    want: bool = true,
    /// The id of the list ask in flight.
    asked: ?u32 = null,
    /// The id of the branch switch in flight, and the branch it goes to.
    switching: ?u32 = null,
    /// The session would not list its branches (it keeps no history).
    refused: bool = false,
    /// The session refused the last switch.
    switch_refused: bool = false,
    answered: bool = false,
    /// A fork status ask is due, the id of the one in flight, and the id of
    /// a confirm or cancel on the wire.
    status_want: bool = false,
    status_asked: ?u32 = null,
    deciding: ?u32 = null,

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

/// What an arrival did to the branch state.
pub const Seen = enum { none, listed, switched };

/// The branch tree leaf's session side: the list asked over the link while
/// a leaf shows it, and a click on a branch node sent as a branch switch.
pub const Feed = struct {
    state: State = .{},
    /// A branches leaf is on screen, which is what makes asks worth sending.
    shown: bool = false,

    /// Send the due list ask unless one is in flight or no leaf shows it.
    pub fn attach(self: *Feed, link: *Link, layout: *const pane_layout.Layout) void {
        self.shown = layout.shows(.branches);
        const state = &self.state;
        if (link.state == .connected and state.status_want and state.status_asked == null) {
            state.status_asked = link.send(proto.CoreOnly, .branch_status, .{ .core = .cpu0 }) catch null;
            state.status_want = false;
        }
        if (!self.shown or link.state != .connected or !state.want or state.asked != null) return;
        state.asked = link.send(proto.CoreOnly, .branch_list, .{ .core = .cpu0 }) catch |err| switch (err) {
            error.TableFull => return,
            else => null,
        };
        state.want = false;
        // A shown tree also watches for a fork waiting on its confirmation.
        state.status_want = true;
        if (state.asked == null) state.refused = true;
    }

    /// A stop makes the list due again, the answer to the ask in flight
    /// becomes the shown list, and a switch's answer says whether the line
    /// moved.
    pub fn observe(self: *Feed, arrival: session_link.Arrival) Seen {
        const state = &self.state;
        switch (arrival) {
            .event => |event| {
                if (event.topic == @backingInt(proto.Topic.stop)) state.want = true;
                return .none;
            },
            .response => |response| {
                // A refused edit may be a fork waiting to be confirmed.
                if (response.result == .err) state.status_want = true;
                if (state.status_asked == response.id) {
                    state.status_asked = null;
                    if (response.result == .ok) if (proto.decode(proto.ForkStatus, response.result.ok)) |status| state.handleStatus(status) else |_| {};
                    return .none;
                }
                if (state.deciding == response.id) {
                    state.deciding = null;
                    state.status_want = true;
                    state.want = true;
                    return if (response.result == .ok) .switched else .none;
                }
                if (state.asked == response.id) {
                    state.asked = null;
                    return self.listed(response.result);
                }
                if (state.switching == response.id) {
                    state.switching = null;
                    state.switch_refused = response.result != .ok;
                    state.want = true;
                    return if (response.result == .ok) .switched else .none;
                }
                return .none;
            },
        }
    }

    fn listed(self: *Feed, result: session_link.Env.Result) Seen {
        const body = switch (result) {
            .ok => |bytes| bytes,
            .err => {
                self.state.refused = true;
                return .none;
            },
        };
        const list = proto.decode(proto.BranchList, body) catch {
            self.state.refused = true;
            return .none;
        };
        self.state.handleList(list);
        self.state.refused = false;
        self.state.answered = true;
        return .listed;
    }

    /// A new image starts a new history: the old list is stale.
    pub fn reload(self: *Feed) void {
        self.state.want = true;
        self.state.items_len = 0;
        self.state.answered = false;
    }

    /// The leaf's note while it has no tree to draw, or null.
    pub fn note(self: *const Feed) ?[]const u8 {
        if (self.state.refused) return "the session keeps no history";
        if (!self.state.answered) return "waiting for the branches";
        if (self.state.items_len == 0) return "no branches recorded";
        return null;
    }

    /// A press on the fork banner: confirm or cancel the pending fork.
    /// `banner` is the banner's row. Returns whether a button took it.
    pub fn pressBanner(self: *Feed, link: *Link, banner: Rect, x: i32, y: i32) bool {
        const state = &self.state;
        if (!state.fork_pending or state.deciding != null) return false;
        const action = fork_banner.hit(.{ .x = banner.x, .y = banner.y, .w = banner.w, .h = banner.h }, x, y);
        state.deciding = switch (action) {
            .none => return false,
            .confirm => link.send(proto.BranchConfirmFork, .branch_confirm_fork, .{}) catch null,
            .cancel => link.send(proto.BranchCancelFork, .branch_cancel_fork, .{}) catch null,
        };
        state.fork_pending = false;
        if (action == .confirm) state.first_fork_confirmed = true;
        return true;
    }

    /// A left press on a node of a branches leaf: switch to its branch.
    /// Returns whether the press landed on a node.
    pub fn press(self: *Feed, link: *Link, layout: *const pane_layout.Layout, solved: *const pane_layout.Solved, x: i32, y: i32) bool {
        for (solved.panes.items) |placed| {
            const pane = layout.pane(placed.index) orelse continue;
            if (pane.kind != .branches) continue;
            const body = shell_frame.bodyOf(placed.area);
            switch (branch_tree.hit(body, self.state.items(), x, y)) {
                .none => {},
                .switch_branch => |id| {
                    if (self.state.switching != null) return true;
                    self.state.switching = link.send(proto.BranchSwitch, .branch_switch, .{ .branch = id }) catch null;
                    self.state.switch_refused = self.state.switching == null;
                    return true;
                },
            }
        }
        return false;
    }
};
