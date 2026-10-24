//! Tests for src/interfaces/gdb/rsp/zig.zig and the Dispatch path that reaches it.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Machine = ra8.session.stop_machine.Machine;
const dispatch = ra8.gdb.rsp.dispatch;
const zig_run = dispatch.zig_run;
const zig_session = ra8.session.step_hook.zig.session;
const transport = ra8.session.transport;

/// A wall the legacy (no-transport) targets can carry: one millisecond per
/// read, never actually read by the budget loop it replaces.
var legacy_wall_ns: u64 = 0;
fn legacyWallNow(context: *anyopaque) u64 {
    _ = context;
    legacy_wall_ns += 1_000_000;
    return legacy_wall_ns;
}
fn legacyWall() transport.Wall {
    return .{ .context = &legacy_wall_ns, .nowFn = legacyWallNow };
}

const session_api = ra8.session.api;

/// 64 bytes of RAM at address 0, the vector table first.
const Ram = struct {
    bytes: [64]u8,

    fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + into.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + from.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(self.bytes[address..][0..from.len], from);
    }
};

// sp 0x40, reset 0x09 ; 0x08 bf00 nop ; 0x0A f3af 8000 nop.w ; 0x0E bf00 nop ; 0x10 ba80 (unallocated)
fn ram() Ram {
    var r: Ram = .{ .bytes = @as([64]u8, @splat(0)) };
    const image = [_]u8{
        0x40, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00,
        0x00, 0xBF, 0xAF, 0xF3, 0x00, 0x80, 0x00, 0xBF,
        0x80, 0xBA,
    };
    @memcpy(r.bytes[0..image.len], &image);
    return r;
}

fn expectReply(target: *zig_run.Target, request: []const u8, want: []const u8) !void {
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings(want, try zig_run.answer(target, request, &out));
}

test "one thread: thread queries and selecting any other thread" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    const session: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 100 };
    var api_session: session_api.Session = .{ .live = session };
    var target: zig_run.Target = .{ .session = &api_session, .wall = legacyWall() };
    try expectReply(&target, "qfThreadInfo", "m1");
    try expectReply(&target, "qsThreadInfo", "l");
    try expectReply(&target, "qC", "QC1");
    try expectReply(&target, "Hg1", "OK");
    try expectReply(&target, "Hg0", "OK");
    try expectReply(&target, "Hg2", "E00");
    try expectReply(&target, "T2", "E00");
    try expectReply(&target, "vCont?", "vCont;c;C;s;S");
    try expectReply(&target, "?", "T05thread:1;");
}

test "with CPU1 attached it is thread 2, and selecting it moves g, s and ?" {
    var memory0 = ram();
    var cpu0: Cpu = .{ .bus = memory0.view() };
    try cpu0.reset(0);
    var memory1 = ram();
    var cpu1: Cpu = .{ .bus = memory1.view() };
    try cpu1.reset(0);
    var machine0 = Machine{};
    var machine1 = Machine{};
    const session: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu0 }, .machine = &machine0, .budget = 100, .other = .{ .core = .{ .cpu = &cpu1 }, .machine = &machine1 } };
    var api_session: session_api.Session = .{ .live = session };
    var target: zig_run.Target = .{ .session = &api_session, .wall = legacyWall() };
    try expectReply(&target, "qfThreadInfo", "m1,2");
    try expectReply(&target, "T2", "OK");
    try expectReply(&target, "T3", "E00");
    try expectReply(&target, "Hg2", "OK");
    try expectReply(&target, "qC", "QC2");
    try std.testing.expectEqual(@as(u8, 1), api_session.live.index);
    try expectReply(&target, "s", "T05thread:2;");
    try std.testing.expectEqual(@as(u32, 0x0A), cpu1.regs.pc);
    try std.testing.expectEqual(@as(u32, 0x08), cpu0.regs.pc);
    try expectReply(&target, "vCont;s:1", "T05thread:1;");
    try std.testing.expectEqual(@as(u32, 0x0A), cpu0.regs.pc);
    try expectReply(&target, "Hg0", "OK");
    try expectReply(&target, "qC", "QC1");
}

test "s steps one instruction, c stops on a break and then on the core's fault" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    _ = try machine.addBreak(.{ .address = 0x0E });
    const session: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 100 };
    var api_session: session_api.Session = .{ .live = session };
    var target: zig_run.Target = .{ .session = &api_session, .wall = legacyWall() };
    try expectReply(&target, "s", "T05thread:1;");
    try std.testing.expectEqual(@as(u32, 0x0A), cpu.regs.pc);
    try expectReply(&target, "vCont;c:1", "T05thread:1;");
    try std.testing.expectEqual(@as(u32, 0x0E), cpu.regs.pc);
    try expectReply(&target, "c", "T0bthread:1;");
    try expectReply(&target, "?", "T0bthread:1;");
}

test "an interrupt from the poll stops a continue with SIGINT" {
    var memory = ram();
    // 0x08 e7fe b . : a loop that never stops on its own
    memory.bytes[8] = 0xFE;
    memory.bytes[9] = 0xE7;
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    const session: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 50 };
    const Interrupt = struct {
        asked: u32 = 0,
        fn check(context: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.asked += 1;
            return self.asked == 3;
        }
    };
    var interrupt: Interrupt = .{};
    var api_session: session_api.Session = .{ .live = session };
    var target: zig_run.Target = .{ .session = &api_session, .poll = .{ .context = &interrupt, .check = Interrupt.check }, .wall = legacyWall() };
    try expectReply(&target, "c", "T02thread:1;");
    try std.testing.expectEqual(@as(u32, 3), interrupt.asked);
    try std.testing.expectEqual(@as(u32, 0x08), cpu.regs.pc);
}

test "a continue through the transport answers the same stop replies" {
    var memory = ram();
    // 0x08 e7fe b . : a loop that never stops on its own
    memory.bytes[8] = 0xFE;
    memory.bytes[9] = 0xE7;
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    const session: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 50 };
    const Interrupt = struct {
        asked: u32 = 0,
        fn check(context: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.asked += 1;
            return self.asked == 3;
        }
    };
    var interrupt: Interrupt = .{};
    var api_session: session_api.Session = .{ .live = session };
    var plane: transport.Transport = .{ .session = &api_session };
    const Wall = struct {
        ns: u64 = 0,
        fn now(context: *anyopaque) u64 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.ns += 1_000_000;
            return self.ns;
        }
    };
    var fake_wall: Wall = .{};
    var target: zig_run.Target = .{ .session = &api_session, .poll = .{ .context = &interrupt, .check = Interrupt.check }, .transport = &plane, .wall = .{ .context = &fake_wall, .nowFn = Wall.now } };
    try expectReply(&target, "c", "T02thread:1;");
    try std.testing.expectEqual(@as(u32, 3), interrupt.asked);
    try std.testing.expectEqual(@as(u32, 0x08), cpu.regs.pc);
    try std.testing.expectEqual(transport.Phase.halted, plane.report().phase);
}

test "reads stay quiet and core reads refuse while a transport job moves" {
    var memory = ram();
    // 0x08 e7fe b . : a loop that never stops on its own
    memory.bytes[8] = 0xFE;
    memory.bytes[9] = 0xE7;
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    const session: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 50 };
    var api_session: session_api.Session = .{ .live = session };
    var plane: transport.Transport = .{ .session = &api_session };
    const Wall = struct {
        ns: u64 = 0,
        fn now(context: *anyopaque) u64 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.ns += 1_000_000;
            return self.ns;
        }
    };
    var fake_wall: Wall = .{};
    const wall: transport.Wall = .{ .context = &fake_wall, .nowFn = Wall.now };
    const Poll = struct {
        asked: u32 = 0,
        fn hit(context: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.asked += 1;
            return self.asked == 3;
        }
    };
    var interrupt: Poll = .{};
    var target: zig_run.Target = .{ .session = &api_session, .transport = &plane, .wall = wall };
    const stub = dispatch.Dispatch{ .zig = &target };

    // Queue a continue and drive one slice, so the job is moving.
    const ticket = try plane.command(.{ .cont = .{} });
    var pumped: u32 = 0;
    while (plane.busy() == null and pumped < 4) : (pumped += 1) {
        _ = try plane.pump(wall, fake_wall.ns + 10_000_000);
    }
    try std.testing.expect(plane.busy() != null);

    // The stale stop stays unspoken and core reads refuse mid-run.
    try expectReply(&target, "?", "");
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("E00", try stub.answer("pf", &out));
    try std.testing.expectEqualStrings("E01", try stub.answer("m8,4", &out));

    // The run ends through its poll and reads answer from the stop again.
    target.last = try plane.finish(ticket, wall, .{ .context = &interrupt, .pollFn = Poll.hit });
    target.back = 0;
    try expectReply(&target, "?", "T02thread:1;");
    try std.testing.expectEqualStrings("08000000", try stub.answer("pf", &out));
}

test "Dispatch with a Zig session reads the Zig core's registers and memory" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    const session: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 100 };
    var api_session: session_api.Session = .{ .live = session };
    var target: zig_run.Target = .{ .session = &api_session, .wall = legacyWall() };
    const stub = dispatch.Dispatch{ .zig = &target };
    var out: [512]u8 = undefined;
    try std.testing.expectEqualStrings("08000000", try stub.answer("pf", &out));
    try std.testing.expectEqualStrings("40000000", try stub.answer("pd", &out));
    try std.testing.expectEqualStrings("00bfaff3", try stub.answer("m8,4", &out));
    try std.testing.expectEqualStrings("T05thread:1;", try stub.answer("s", &out));
    try std.testing.expectEqualStrings("0a000000", try stub.answer("pf", &out));
    try std.testing.expectEqualStrings("OK", try stub.answer("Z0,e,2", &out));
    try std.testing.expectEqualStrings("T05thread:1;", try stub.answer("c", &out));
    try std.testing.expectEqualStrings("0e000000", try stub.answer("pf", &out));
}

test "the reverse packets walk the recorded window (RA8EMU-1170)" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = "tests/fixtures/dfu/dfu_bootloader.elf" });
    defer opened.deinit();
    const session = opened.session();
    var target: zig_run.Target = .{ .session = session, .wall = legacyWall() };

    var pcs: [4]u32 = undefined;
    for (0..4) |i| {
        _ = try session.run(.cpu0, .step);
        pcs[i] = session.live.core.cpu.regs.pc;
    }

    // A reverse step lands where the previous stop was, then one further back.
    try expectReply(&target, "bs", "T05thread:1;");
    try std.testing.expectEqual(pcs[2], session.live.core.cpu.regs.pc);
    try expectReply(&target, "bs", "T05thread:1;");
    try std.testing.expectEqual(pcs[1], session.live.core.cpu.regs.pc);

    // Reverse-continue with no breakpoints or faults behind stops at the
    // window's oldest frame.
    try expectReply(&target, "bc", "T05thread:1;");
    try std.testing.expectEqual(pcs[0], session.live.core.cpu.regs.pc);

    // Nothing recorded behind the oldest: the error says so.
    try expectReply(&target, "bs", "E00");
    try expectReply(&target, "bc", "E00");
}

test "reverse-continue stops at a breakpoint in the recorded window (RA8EMU-1170)" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = "tests/fixtures/dfu/dfu_bootloader.elf" });
    defer opened.deinit();
    const session = opened.session();
    var target: zig_run.Target = .{ .session = session, .wall = legacyWall() };

    var pcs: [4]u32 = undefined;
    for (0..4) |i| {
        _ = try session.run(.cpu0, .step);
        pcs[i] = session.live.core.cpu.regs.pc;
    }

    // A break at the second recorded stop: reverse-continue from the newest
    // lands there, not at the window's oldest.
    _ = try session.setBreakpoint(.cpu0, .{ .address = pcs[1] });
    try expectReply(&target, "bc", "T05thread:1;");
    try std.testing.expectEqual(pcs[1], session.live.core.cpu.regs.pc);
}

test "GDB register and memory writes route through Session choke point" {
    const gpa = std.testing.allocator;
    var opened = try ra8.session.harness.open(gpa, std.testing.io, .{ .elf_path = "tests/fixtures/dfu/dfu_bootloader.elf" });
    defer opened.deinit();
    const session = opened.session();
    var target: zig_run.Target = .{ .session = session, .wall = legacyWall() };
    const stub = dispatch.Dispatch{ .zig = &target };
    var out: [512]u8 = undefined;

    var graph = try ra8.session.history_branch.BranchGraph.init(gpa);
    defer graph.deinit();
    var router = ra8.session.history_fork_router.ForkRouter.init(gpa, &graph);
    defer router.deinit();
    session.fork_router = &router;

    var end = graph.get(0).?.recorded_end;
    end.r = 10;
    try graph.insertNode(.{
        .id = 0,
        .parent = 0,
        .fork_at = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired },
        .reason = .base,
        .recorded_end = end,
    });

    // 1. GDB register write in the past requires confirmation and is refused with E00
    try std.testing.expectEqualStrings("E00", try stub.answer("P3=78563412", &out));
    try std.testing.expect(session.forkPending() != null);

    // Confirm the fork: executes fork, advances active branch, and applies register write
    try session.confirmFork();
    try std.testing.expect(session.forkPending() == null);
    try std.testing.expectEqual(@as(u32, 1), router.active_line);

    // Reading r3 now returns the value applied upon confirmation
    try std.testing.expectEqualStrings("78563412", try stub.answer("p3", &out));
}
