//! The shell's state diff leaf: the checkpoint behind the cursor compared
//! with another checkpoint of the session's history, asked over the link
//! (diff 0x013C) into the diff pane's view. The leaf compares the checkpoint at or
//! behind the cursor against the newest checkpoint first; its step buttons move
//! the other side one checkpoint earlier or later. An ask goes out while a diff
//! leaf is on screen, after every stop and after a branch switch.
const std = @import("std");
const rpc = @import("ra8_rpc");
const proto = rpc.session.rpc;
const diff_wire = rpc.session.diff_wire;
const session_link = @import("../session_link.zig");
const diff_pane = @import("../ui/diff_pane.zig");
const pane_layout = @import("../ui/pane_layout.zig");
const shell_frame = @import("../ui/shell/frame.zig");

const Link = session_link.Link;

pub const State = struct {
    view: diff_pane.DiffView = .{},
    /// Checkpoints the cursor's line held at the last answer.
    frames: u16 = 0,
    /// The checkpoint compared against, or null for the newest until the first
    /// answer says how many there are.
    pick: ?u16 = null,
    want: bool = true,
    asked: ?u32 = null,
    refused: bool = false,
    b_buf: [12]u8 = undefined,

    /// Send the due ask unless one is in flight or no diff leaf is shown.
    pub fn attach(self: *State, link: *Link, layout: *const pane_layout.Layout) void {
        if (!layout.shows(.diff) or link.state != .connected or !self.want or self.asked != null) return;
        const b: []const u8 = if (self.pick) |at|
            std.fmt.bufPrint(&self.b_buf, "{d}", .{at}) catch "latest"
        else
            "latest";
        self.asked = link.send(proto.DiffArgs, .diff, .{ .a = "cursor", .b = b }) catch |err| switch (err) {
            error.TableFull => return,
            else => null,
        };
        self.want = false;
        if (self.asked == null) self.refuse();
    }

    /// A stop moves the cursor, so the diff is due again; the answer to the
    /// ask in flight becomes the view. Returns whether the view changed.
    pub fn observe(self: *State, allocator: std.mem.Allocator, arrival: session_link.Arrival) bool {
        switch (arrival) {
            .event => |event| {
                if (event.topic == @backingInt(proto.Topic.stop)) self.want = true;
                return false;
            },
            .response => |response| {
                if (self.asked != response.id) return false;
                self.asked = null;
                const body = switch (response.result) {
                    .ok => |bytes| bytes,
                    .err => {
                        self.refuse();
                        return true;
                    },
                };
                self.take(allocator, body) catch self.refuse();
                return true;
            },
        }
    }

    /// A load or a branch switch: whatever was compared is stale.
    pub fn reload(self: *State) void {
        self.want = true;
        self.pick = null;
        self.frames = 0;
        self.view.clear();
    }

    /// A press on a step button of a diff leaf. Returns whether one took it.
    pub fn press(self: *State, layout: *const pane_layout.Layout, solved: *const pane_layout.Solved, x: i32, y: i32) bool {
        for (solved.panes.items) |placed| {
            const pane = layout.pane(placed.index) orelse continue;
            if (pane.kind != .diff) continue;
            const body = shell_frame.bodyOf(placed.area);
            switch (diff_pane.hit(body, x, y)) {
                .none => {},
                .earlier => return self.step(-1),
                .later => return self.step(1),
            }
        }
        return false;
    }

    pub fn step(self: *State, delta: i32) bool {
        if (self.frames == 0) return true;
        const at: i32 = self.pick orelse self.frames - 1;
        const moved = std.math.clamp(at + delta, 0, @as(i32, self.frames) - 1);
        self.pick = @intCast(moved);
        self.want = true;
        return true;
    }

    fn take(self: *State, allocator: std.mem.Allocator, body: []const u8) !void {
        const wire = try proto.decode(proto.DiffWire, body);
        var decoded = try diff_wire.decode(allocator, wire.bytes);
        defer decoded.deinit(allocator);
        self.frames = decoded.frames;
        if (self.pick == null and decoded.frames > 0) self.pick = decoded.frames - 1;
        const view = &self.view;
        const scroll = view.scroll_offset;
        view.clear();
        view.scroll_offset = scroll;
        view.pos_a = .{ .branch = decoded.a.branch, .r = decoded.a.r, .phase = .cpu0, .o = 0, .gap = .retired };
        view.pos_b = .{ .branch = decoded.b.branch, .r = decoded.b.r, .phase = .cpu0, .o = 0, .gap = .retired };
        for (decoded.regs) |r| _ = view.addReg(r.core, r.name, r.val_a, r.val_b);
        for (decoded.pages) |p| _ = view.addPage(p.address, 0);
        for (decoded.periphs) |p| {
            var at: [16]u8 = undefined;
            const register = std.fmt.bufPrint(&at, "+0x{x}", .{p.offset}) catch "+?";
            _ = view.addPeriph(p.unit, register, p.old_val, p.new_val);
        }
        var label: [64]u8 = undefined;
        view.setLabel(std.fmt.bufPrint(&label, "cursor ckpt r{d} vs ckpt {d} of {d} r{d}", .{ decoded.a.r, (self.pick orelse 0) + 1, decoded.frames, decoded.b.r }) catch "cursor vs checkpoint");
        view.picked = true;
        self.refused = false;
    }

    /// A refused ask leaves the view empty with the note in its header.
    pub fn refuse(self: *State) void {
        self.refused = true;
        self.pick = null;
        self.view.clear();
        self.view.setLabel("the session holds no checkpoint to compare");
        self.view.picked = true;
    }
};
