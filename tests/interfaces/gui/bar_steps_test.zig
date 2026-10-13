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

fn settle(link: *Link, statuses: []const *Status) !void {
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (true) {
        var busy = false;
        for (statuses) |s| busy = busy or pending(s);
        if (!busy) return;
        if (std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() > deadline) return error.Timeout;
        if (link.state != .connected) return error.LinkLost;
        if (link.pump()) |arrival| {
            for (statuses) |s| s.observe(link, arrival);
        } else try std.testing.io.sleep(.fromMilliseconds(1), .awake);
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
        try settle(&r.link, &.{&r.status});
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
            try settle(&self.link, &.{&self.status});
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
    try settle(&rig.link, &.{&rig.status});
    try std.testing.expectEqual(after_call | bit, pc(&rig.status));
}

test "the bar's step into at a call lands on the callee" {
    var rig = try Rig.spawn();
    defer rig.done() catch unreachable;
    const bit = pc(&rig.status) & 1;
    try rig.toCall();
    try capture.press(.step, &rig.status, &rig.run, &rig.link);
    try settle(&rig.link, &.{&rig.status});
    try std.testing.expectEqual(callee | bit, pc(&rig.status));
}

test "the bar's step out of a call returns to the caller" {
    var rig = try Rig.spawn();
    defer rig.done() catch unreachable;
    const bit = pc(&rig.status) & 1;
    try rig.toCall();
    try capture.press(.step, &rig.status, &rig.run, &rig.link);
    try settle(&rig.link, &.{&rig.status});
    try std.testing.expectEqual(callee | bit, pc(&rig.status));
    try capture.press(.out, &rig.status, &rig.run, &rig.link);
    try settle(&rig.link, &.{&rig.status});
    try std.testing.expectEqual(after_call | bit, pc(&rig.status));
}

// The ThreadX dual fixture (RA8EMU-840): both images walk the same fifteen
// instructions from reset to the `bl` that calls spin, and spin returns, so
// over, into and out each have an exact address on both cores; the second
// core's image is the same walk 0x000c_0000 higher.
const dual0_path = test_paths.threadx_dual;
const dual1_path = test_paths.threadx_dual_cpu1;
const dual_base0 = 0x0200_0040;
const dual_base1 = 0x020c_0040;
const dual_walk = [_]u32{ 0x0200_0044, 0x0200_0046, 0x0200_004a, 0x0200_004c, 0x0200_004e, 0x0200_0050, 0x0200_0052, 0x0200_0056, 0x0200_0058, 0x0200_005a, 0x0200_005c, 0x0200_0060, 0x0200_0064, 0x0200_0066, 0x0200_006a };
const dual_after0 = 0x0200_006e;
const dual_callee0 = 0x0200_009c;

fn dualAt(want: u32, base: u32) u32 {
    return want - dual_base0 + base;
}

const DualRig = struct {
    local: session_link.Local,
    rx: []u8,
    tx: []u8,
    link: Link,
    cpu0: Status = .{},
    cpu1: Status = .{ .core = .cpu1 },
    run0: Run = .{},
    run1: Run = .{ .core = .cpu1 },

    fn spawn() !DualRig {
        const gpa = std.testing.allocator;
        var r: DualRig = .{ .local = undefined, .rx = undefined, .tx = undefined, .link = undefined };
        try r.local.spawnArgs(std.testing.io, test_paths.emulator, dual0_path, &.{ "--cpu1", dual1_path });
        errdefer r.local.child.kill(std.testing.io);
        r.rx = try gpa.alloc(u8, 2 * Env.max_frame);
        errdefer gpa.free(r.rx);
        r.tx = try gpa.alloc(u8, Env.max_frame);
        errdefer gpa.free(r.tx);
        r.link.open(r.local.transport(), r.rx, r.tx);
        try connect(&r.link);
        const bytes0 = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, dual0_path, gpa, .limited(1 << 20));
        defer gpa.free(bytes0);
        try r.cpu0.load(&r.link, dual0_path, bytes0);
        const bytes1 = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, dual1_path, gpa, .limited(1 << 20));
        defer gpa.free(bytes1);
        try r.cpu1.load(&r.link, dual1_path, bytes1);
        try settle(&r.link, &.{ &r.cpu0, &r.cpu1 });
        return r;
    }

    fn done(self: *DualRig) !void {
        self.local.end();
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try self.local.reap());
        const gpa = std.testing.allocator;
        gpa.free(self.rx);
        gpa.free(self.tx);
    }

    /// Step one core from its reset to its call, expecting every pc on the way.
    fn toCall(self: *DualRig, status: *Status, run: *Run, base: u32) !void {
        const bit = pc(status) & 1;
        try std.testing.expectEqual(base | bit, pc(status));
        for (dual_walk) |want| {
            try capture.press(.step, status, run, &self.link);
            try settle(&self.link, &.{ &self.cpu0, &self.cpu1 });
            try std.testing.expectEqual(dualAt(want, base) | bit, pc(status));
        }
    }
};

test "the bar's step over at a call lands after it on both cores" {
    var rig = try DualRig.spawn();
    defer rig.done() catch unreachable;
    try rig.toCall(&rig.cpu0, &rig.run0, dual_base0);
    try capture.press(.over, &rig.cpu0, &rig.run0, &rig.link);
    try settle(&rig.link, &.{ &rig.cpu0, &rig.cpu1 });
    try std.testing.expectEqual(dualAt(dual_after0, dual_base0) | (pc(&rig.cpu0) & 1), pc(&rig.cpu0));

    try rig.toCall(&rig.cpu1, &rig.run1, dual_base1);
    try capture.press(.over, &rig.cpu1, &rig.run1, &rig.link);
    try settle(&rig.link, &.{ &rig.cpu0, &rig.cpu1 });
    try std.testing.expectEqual(dualAt(dual_after0, dual_base1) | (pc(&rig.cpu1) & 1), pc(&rig.cpu1));
}

test "the bar's step into at a call lands on the callee on both cores" {
    var rig = try DualRig.spawn();
    defer rig.done() catch unreachable;
    try rig.toCall(&rig.cpu0, &rig.run0, dual_base0);
    try capture.press(.step, &rig.cpu0, &rig.run0, &rig.link);
    try settle(&rig.link, &.{ &rig.cpu0, &rig.cpu1 });
    try std.testing.expectEqual(dualAt(dual_callee0, dual_base0) | (pc(&rig.cpu0) & 1), pc(&rig.cpu0));

    try rig.toCall(&rig.cpu1, &rig.run1, dual_base1);
    try capture.press(.step, &rig.cpu1, &rig.run1, &rig.link);
    try settle(&rig.link, &.{ &rig.cpu0, &rig.cpu1 });
    try std.testing.expectEqual(dualAt(dual_callee0, dual_base1) | (pc(&rig.cpu1) & 1), pc(&rig.cpu1));
}

test "the bar's step out of a call returns to the caller on both cores" {
    var rig = try DualRig.spawn();
    defer rig.done() catch unreachable;
    try rig.toCall(&rig.cpu0, &rig.run0, dual_base0);
    try capture.press(.step, &rig.cpu0, &rig.run0, &rig.link);
    try settle(&rig.link, &.{ &rig.cpu0, &rig.cpu1 });
    try capture.press(.out, &rig.cpu0, &rig.run0, &rig.link);
    try settle(&rig.link, &.{ &rig.cpu0, &rig.cpu1 });
    try std.testing.expectEqual(dualAt(dual_after0, dual_base0) | (pc(&rig.cpu0) & 1), pc(&rig.cpu0));

    try rig.toCall(&rig.cpu1, &rig.run1, dual_base1);
    try capture.press(.step, &rig.cpu1, &rig.run1, &rig.link);
    try settle(&rig.link, &.{ &rig.cpu0, &rig.cpu1 });
    try capture.press(.out, &rig.cpu1, &rig.run1, &rig.link);
    try settle(&rig.link, &.{ &rig.cpu0, &rig.cpu1 });
    try std.testing.expectEqual(dualAt(dual_after0, dual_base1) | (pc(&rig.cpu1) & 1), pc(&rig.cpu1));
}
