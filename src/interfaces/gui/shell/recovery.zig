//! Undo and clean image reset requests; refresh panes only after acceptance.
const proto = @import("ra8_rpc").session.rpc;
const loop = @import("loop.zig");
const session_link = @import("../session_link.zig");

pub const Method = enum { undo_write, reset_image };

pub const Recovery = struct {
    asked: ?struct { id: u32, method: Method, link: *session_link.Link, connection: u64 } = null,
    feed: ?struct { link: *session_link.Link, connection: u64, next: u2 = 0 } = null,

    /// Observe restores from other clients even without a board pane.
    pub fn attach(self: *Recovery, shell: *loop.Shell) void {
        self.sync(shell);
        const link = shell.link orelse return;
        if (link.state != .connected or link.caps() & proto.recovery_cap == 0) return;
        if (self.feed == null) self.feed = .{ .link = link, .connection = link.connection };
        while (self.feed.?.next < 2) : (self.feed.?.next += 1) {
            const core: proto.Core = if (self.feed.?.next == 0) .cpu0 else .cpu1;
            _ = link.send(proto.Subscription, .subscribe, .{ .core = core, .topic = .session }) catch return;
        }
    }

    /// A replacement connection or image cannot finish an older request.
    pub fn sync(self: *Recovery, shell: *loop.Shell) void {
        const link = shell.link orelse {
            self.asked = null;
            self.feed = null;
            return;
        };
        if (self.feed) |feed| if (link != feed.link or link.connection != feed.connection or link.state != .connected) {
            self.feed = null;
        };
        const asked = self.asked orelse return;
        if (link != asked.link or link.connection != asked.connection or link.state != .connected or
            shell.status.load_id != null or !shell.loaded) self.asked = null;
    }

    pub fn pending(self: *Recovery, shell: *loop.Shell) bool {
        self.sync(shell);
        return self.asked != null;
    }

    pub fn ask(self: *Recovery, shell: *loop.Shell, method: Method) void {
        self.sync(shell);
        const link = shell.link orelse return;
        if (!shell.loaded or shell.status.load_id != null or self.asked != null) return;
        if (shell.status.run == .running or shell.status.run_id != null) return;
        if (shell.time) |time| if (time.run.lit) return;
        if (link.caps() & proto.recovery_cap == 0) return self.refuse(shell, method);
        const id = switch (method) {
            .undo_write => link.send(proto.CoreOnly, .undo_write, .{ .core = .cpu0 }),
            .reset_image => link.send(proto.CoreOnly, .reset_image, .{ .core = .cpu0 }),
        } catch return self.refuse(shell, method);
        self.asked = .{ .id = id, .method = method, .link = link, .connection = link.connection };
    }

    pub fn observe(self: *Recovery, shell: *loop.Shell, arrival: session_link.Arrival) bool {
        self.sync(shell);
        const response = switch (arrival) {
            .response => |response| response,
            .event => |event| {
                if (event.topic != @backingInt(proto.Topic.session) or !shell.loaded or shell.status.load_id != null) return false;
                const link = shell.link orelse return false;
                if (link.state != .connected) return false;
                const change = proto.decode(proto.SessionEvent, event.payload) catch return false;
                if (change.kind == .loaded) {
                    self.asked = null;
                    return false;
                }
                if (change.kind != .rewound) return false;
                return restored(shell);
            },
        };
        const asked = self.asked orelse return false;
        if (response.id != asked.id or response.connection != asked.connection) return false;
        self.asked = null;
        const ack: ?proto.Ack = if (response.result == .ok) proto.decode(proto.Ack, response.result.ok) catch null else null;
        if (ack == null or ack.?.accepted != 1) {
            self.refuse(shell, asked.method);
            return false;
        }
        return restored(shell);
    }

    fn restored(shell: *loop.Shell) bool {
        shell.status.refused = null;
        shell.status.run = .unknown;
        if (shell.link) |link| {
            shell.status.pc_id = link.send(proto.ReadRegister, .read_register, .{ .core = shell.status.core, .register = .pc }) catch null;
        }
        return true;
    }

    fn refuse(_: *Recovery, shell: *loop.Shell, method: Method) void {
        shell.status.refused = if (method == .undo_write) .undo else .reset_image;
    }
};
