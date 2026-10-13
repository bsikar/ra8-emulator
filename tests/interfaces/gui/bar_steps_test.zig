//! Host tests for the bar's step controls over a served session (RA8EMU-1188):
//! step over, step into and step out land on the expected instruction. The
//! fp_basic image walks six instructions from its entry to the `bl` that
//! calls its body, so each control's call-site behaviour has an exact
//! address; the pc's low bit rides along whichever way the loader set it.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const test_paths = @import("test_paths");
const status_bar = gui_app.status.bar;
const session_link = gui_app.session_link;
const capture = gui_app.time.bar_capture;
const Run = gui_app.shell.run.Run;
const proto = ra8.rpc.session.rpc;
const Link = session_link.Link;
const Status = status_bar.Status;

const Env = proto.Client.Env;
const elf_path = "tests/fixtures/fpu/fp_basic.elf";

// From the entry: ldr, ldr, orr.w, str, dsb, isb reach the bl at 0x0200001a.
const entry = 0x0200_0008;
const walk = [_]u32{ 0x0200_000a, 0x0200_000c, 0x0200_0010, 0x0200_0012, 0x0200_0016, 0x0200_001a };
const after_call = 0x0200_001e;
const callee = 0x0200_0024;

fn pending(status: *const Status) bool {
    return status.load_id != null or status.pc_id != null or status.run == .running;
}

fn settle(link: *Link, status: *Status) !void {
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (pending(status)) {
        if (std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() > deadline) return error.Timeout;
        if (link.state != .connected) return error.LinkLost;
        if (link.pump()) |arrival| status.observe(link, arrival) else try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn connect(link: *Link) !void {
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (link.state == .connecting and std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline) {
        _ = link.pump();
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(link.state == .connected);
}

fn pc(status: *const Status) u32 {
    return status.run.halted.address;
}

const Rig = struct {
    local: session_link.Local,
    rx: []u8,
    tx: []u8,
    link: Link,
    status: Status = .{},
    run: Run = .{},

    fn spawn() !Rig {
        const gpa = std.testing.allocator;
        var r: Rig = .{ .local = undefined, .rx = undefined, .tx = undefined, .link = undefined };
        try r.local.spawn(std.testing.io, test_paths.emulator, elf_path);
        errdefer r.local.child.kill(std.testing.io);
        r.rx = try gpa.alloc(u8, 2 * Env.max_frame);
        errdefer gpa.free(r.rx);
        r.tx = try gpa.alloc(u8, Env.max_frame);
        errdefer gpa.free(r.tx);
        r.link.open(r.local.transport(), r.rx, r.tx);
        try connect(&r.link);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, elf_path, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        try r.status.load(&r.link, elf_path, bytes);
        try settle(&r.link, &r.status);
        return r;
    }

    fn done(self: *Rig) !void {
        self.local.end();
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try self.local.reap());
        const gpa = std.testing.allocator;
        gpa.free(self.rx);
        gpa.free(self.tx);
    }

    /// Step from the entry to the call, expecting every pc on the way.
    fn toCall(self: *Rig) !void {
        const bit = pc(&self.status) & 1;
        try std.testing.expectEqual(entry | bit, pc(&self.status));
        for (walk) |want| {
            try capture.press(.step, &self.status, &self.run, &self.link);
            try settle(&self.link, &self.status);
            try std.testing.expectEqual(want | bit, pc(&self.status));
        }
    }
};

test "the bar's step over at a call lands after it" {
    var rig = try Rig.spawn();
    defer rig.done() catch unreachable;
    const bit = pc(&rig.status) & 1;
    try rig.toCall();
    try capture.press(.over, &rig.status, &rig.run, &rig.link);
    try settle(&rig.link, &rig.status);
    try std.testing.expectEqual(after_call | bit, pc(&rig.status));
}

test "the bar's step into at a call lands on the callee" {
    var rig = try Rig.spawn();
    defer rig.done() catch unreachable;
    const bit = pc(&rig.status) & 1;
    try rig.toCall();
    try capture.press(.step, &rig.status, &rig.run, &rig.link);
    try settle(&rig.link, &rig.status);
    try std.testing.expectEqual(callee | bit, pc(&rig.status));
}

test "the bar's step out of a call returns to the caller" {
    var rig = try Rig.spawn();
    defer rig.done() catch unreachable;
    const bit = pc(&rig.status) & 1;
    try rig.toCall();
    try capture.press(.step, &rig.status, &rig.run, &rig.link);
    try settle(&rig.link, &rig.status);
    try std.testing.expectEqual(callee | bit, pc(&rig.status));
    try capture.press(.out, &rig.status, &rig.run, &rig.link);
    try settle(&rig.link, &rig.status);
    try std.testing.expectEqual(after_call | bit, pc(&rig.status));
}
