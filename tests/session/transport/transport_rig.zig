//! Shared test bridge and fixtures for transport tests: FakeWall,
//! TestBridge, countFixture, counter_addr, and test image paths.

const std = @import("std");
const ra8 = @import("ra8");
const transport = ra8.session.transport;
const fakes = @import("../history_fakes.zig");
const seek_engine_mod = ra8.session.history_seek_engine;
const seek_facts_mod = ra8.session.history_seek_facts;
const touched_pages = ra8.session.history_touched_pages;

pub const history_elf = "tests/fixtures/dfu/dfu_bootloader.elf";
pub const image_path = "tests/fixtures/display/ra8_ui.elf";

/// A wall the test drives: one millisecond per read, so a pump loop makes
/// progress and terminates on its own bound.
pub const FakeWall = struct {
    now_ns: u64 = 0,
    fn now(context: *anyopaque) u64 {
        const self: *FakeWall = @ptrCast(@alignCast(context));
        self.now_ns += 1_000_000;
        return self.now_ns;
    }
    pub fn wall(self: *FakeWall) transport.Wall {
        return .{ .context = self, .nowFn = now };
    }
};

/// The guest counter the count fixture increments, above the code at +0x6000.
pub const counter_addr = ra8.chip.core.memmap.sram_base + 0x6100;

/// The loop fixture's `b .` becomes a counting loop: `ldr r0,[r1]; adds
/// r0,#1; str r0,[r1]; b` back, so every iteration writes guest memory and
/// retires four instructions, four cycles apart.
pub fn countFixture(opened: *ra8.session.harness.Harness) !void {
    try loopFixture(opened);
    const at = ra8.chip.core.memmap.sram_base + 0x6000;
    try opened.guest().write(at, &.{ 0x08, 0x68, 0x40, 0x1C, 0x08, 0x60, 0xFB, 0xE7 });
    try opened.guest().writeWord(counter_addr, 0);
    const cpu = opened.primaryCpu();
    cpu.regs.low[0] = 0;
    cpu.regs.low[1] = counter_addr;
}

pub fn loopFixture(opened: *ra8.session.harness.Harness) !void {
    opened.state.edge.idle_skip = false;
    opened.state.edge.timebase.per_chunk = 64;
    opened.session().live.boundary.?.chunk = 64;
    const at = ra8.chip.core.memmap.sram_base + 0x6000;
    try opened.guest().write(at, &.{ 0xfe, 0xe7 });
    opened.primaryCpu().regs.pc = at;
    opened.primaryCpu().regs.primask = 1;
    opened.primaryCpu().waiting = null;
}

/// The bridge the backward tests bind: facts gathered from the in-memory log
/// the recorder committed, restores from the in-memory object space, and
/// the live cursor's position from the boundary grid. The bridge owns one
/// gathered facts at a time; the next gather frees the last.
pub const TestBridge = struct {
    gpa: std.mem.Allocator,
    opened: *ra8.session.harness.Harness,
    sink: *fakes.Sink,
    objects: *fakes.Objects,
    prior: ?seek_facts_mod.Facts = null,
    touched_scratch: std.ArrayList(*touched_pages.Touched) = .empty,

    pub fn bridge(self: *TestBridge) transport.Bridge {
        return .{ .context = self, .facts = facts, .restore = restore, .logBytes = logBytes };
    }

    fn logBytes(context: *anyopaque) anyerror![]const u8 {
        const self: *TestBridge = @ptrCast(@alignCast(context));
        return self.sink.bytes.items;
    }

    fn facts(context: *anyopaque) anyerror!seek_engine_mod.Facts {
        const self: *TestBridge = @ptrCast(@alignCast(context));
        if (self.prior) |old| self.gpa.free(old.checkpoints);
        for (self.touched_scratch.items) |t| {
            t.deinit();
            self.gpa.destroy(t);
        }
        self.touched_scratch.clearRetainingCapacity();
        const gathered = try seek_facts_mod.gather(self.gpa, self.sink.bytes.items);
        self.prior = gathered;
        for (gathered.checkpoints) |*c| {
            const t_name = touched_pages.objectName(c.object);
            if (self.objects.get(&t_name)) |saved| {
                if (touched_pages.Touched.decodeSlice(self.gpa, saved)) |t| {
                    const ptr = try self.gpa.create(touched_pages.Touched);
                    ptr.* = t;
                    try self.touched_scratch.append(self.gpa, ptr);
                    c.touched = ptr;
                } else |_| {}
            }
        }
        const win_facts: ?seek_engine_mod.WindowFacts = if (self.opened.session().window) |w| .{
            .start = w.start() orelse .{},
            .end = w.end() orelse .{},
            .at = if (self.opened.session().grid) |g| g.at else .{},
            .line = w.line,
            .slots = w.count(),
        } else null;
        if (self.opened.session().grid) |grid| return .{ .current = grid.at, .checkpoints = gathered.checkpoints, .window = win_facts };
        return .{ .current = .{}, .checkpoints = gathered.checkpoints, .window = win_facts };
    }

    fn restore(context: *anyopaque, object: []const u8) anyerror!void {
        const self: *TestBridge = @ptrCast(@alignCast(context));
        const saved = self.objects.get(object) orelse return error.MissingObject;
        try self.opened.history().restoreBytes(saved);
    }

    pub fn deinit(self: *TestBridge) void {
        if (self.prior) |old| self.gpa.free(old.checkpoints);
        for (self.touched_scratch.items) |t| {
            t.deinit();
            self.gpa.destroy(t);
        }
        self.touched_scratch.deinit(self.gpa);
    }
};
