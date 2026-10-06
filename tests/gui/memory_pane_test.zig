//! Covers src/gui/memory_pane.zig (RA8EMU-746): a row's columns line up,
//! the pane rasterises to a pinned golden frame, unreadable bytes draw only
//! muted "??" and '?', a pane too narrow draws nothing and rows stop at what
//! was captured, a capture from a real session rasterises to a pinned golden
//! frame, and capture reads each core across the end of mapped memory.
const std = @import("std");
const ra8 = @import("ra8");

const bus = ra8.core.cpu.bus;
const Cpu = ra8.core.cpu.cpu.Cpu;
const Machine = ra8.core.stop_machine.Machine;
const zig_session = ra8.core.step_hook.zig_session;
const api = ra8.core.session_api;
const draw_list = ra8.gui.draw_list;
const raster = ra8.gui.raster;
const font = ra8.gui.font;
const pane = ra8.gui.memory_pane;

const Rect = draw_list.Rect;
/// Exactly one row wide and four rows deep.
const area = Rect{ .x = 0, .y = 0, .w = pane.min_w, .h = 2 * pane.pad + 4 * pane.row_h };

/// Four rows of mixed printable and unprintable bytes; the last row's top
/// half cannot be read.
fn sample() pane.Snapshot {
    var snapshot: pane.Snapshot = .{ .base = 0x2000_0100, .count = 4 };
    for (0..4 * pane.per_row) |index| {
        snapshot.bytes[index] = @intCast((index * 7 + 0x20) & 0xFF);
        snapshot.readable[index] = index < 3 * pane.per_row + 8;
    }
    return snapshot;
}

const Scene = struct {
    list: draw_list.DrawList,
    frame: raster.Framebuffer,

    fn init() !Scene {
        const w: u32 = @intCast(area.w);
        const h: u32 = @intCast(area.h);
        return .{ .list = draw_list.DrawList.init(std.testing.allocator, w, h), .frame = try raster.Framebuffer.init(std.testing.allocator, w, h) };
    }

    fn deinit(self: *Scene) void {
        self.list.deinit();
        self.frame.deinit(std.testing.allocator);
    }

    fn render(self: *Scene, snapshot: *const pane.Snapshot) !void {
        try pane.draw(&self.list, area, snapshot);
        raster.draw(&self.frame, &self.list, font.atlas);
    }

    fn digest(self: *const Scene) u64 {
        return std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(self.frame.pixels));
    }

    /// Glyphs drawn in `color`.
    fn glyphs(self: *const Scene, color: draw_list.Color) usize {
        var count: usize = 0;
        for (self.list.commands.items) |command| {
            if (command.shape == .glyph and std.meta.eql(command.shape.glyph.color, color)) count += 1;
        }
        return count;
    }
};

test "a row is an address, sixteen hex bytes with a gap after the eighth, then ASCII" {
    try std.testing.expectEqual(@as(usize, 76), pane.row_len);
    try std.testing.expectEqual(pane.hex_at + 21, pane.hexColumn(7));
    try std.testing.expectEqual(pane.hex_at + 25, pane.hexColumn(8));
    try std.testing.expectEqual(pane.ascii_at, pane.hexColumn(15) + 4);
    try std.testing.expectEqual(@as(usize, 4), pane.rows(area));
    try std.testing.expectEqual(pane.pad + 2 + 3 * pane.row_h, pane.rowOrigin(area, 3).y);
}

test "the pane rasterises to the pinned golden frame" {
    var scene = try Scene.init();
    defer scene.deinit();
    const snapshot = sample();
    try scene.render(&snapshot);
    try std.testing.expectEqual(@as(u64, 13435636883611702039), scene.digest());
}

test "unreadable bytes draw only muted question marks" {
    var scene = try Scene.init();
    defer scene.deinit();
    var snapshot: pane.Snapshot = .{ .base = 0, .count = 1 };
    @memset(snapshot.bytes[0..pane.per_row], 'A');
    @memset(snapshot.readable[0..12], true);
    try scene.render(&snapshot);
    try std.testing.expectEqual(@as(usize, 12 * 3), scene.glyphs(pane.ink));
    try std.testing.expectEqual(@as(usize, 8 + 4 * 3), scene.glyphs(pane.muted));
}

test "a pane too narrow draws nothing, and rows stop at what was captured" {
    var scene = try Scene.init();
    defer scene.deinit();
    var snapshot: pane.Snapshot = .{ .base = 0, .count = 2 };
    @memset(snapshot.bytes[0 .. 2 * pane.per_row], 'A');
    @memset(snapshot.readable[0 .. 2 * pane.per_row], true);
    try pane.draw(&scene.list, .{ .x = 0, .y = 0, .w = pane.min_w - 1, .h = area.h }, &snapshot);
    try std.testing.expectEqual(@as(usize, 0), scene.list.commands.items.len);
    try scene.render(&snapshot);
    try std.testing.expectEqual(@as(usize, 2 * (8 + 32 + 16)), scene.glyphs(pane.ink) + scene.glyphs(pane.muted));
}

/// A RAM image holding a vector table (initial sp 0x40, reset at 0x08);
/// everything past its 256 bytes is unmapped.
const Ram = struct {
    bytes: [256]u8 = [_]u8{0} ** 256,

    fn init() Ram {
        var memory: Ram = .{};
        @memcpy(memory.bytes[0..8], &[_]u8{ 0x40, 0, 0, 0, 0x09, 0, 0, 0 });
        return memory;
    }

    fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + into.len > self.bytes.len) return error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + bytes.len > self.bytes.len) return error.Unmapped;
        @memcpy(self.bytes[address..][0..bytes.len], bytes);
    }
};

/// Two cores, each on its own Ram, behind one session.
const Rig = struct {
    memory0: Ram,
    memory1: Ram,
    cpu0: Cpu,
    cpu1: Cpu,
    machine0: Machine,
    machine1: Machine,
    session: api.Session,

    fn init(self: *Rig) !void {
        self.memory0 = Ram.init();
        self.memory1 = Ram.init();
        self.cpu0 = .{ .bus = self.memory0.view() };
        self.cpu1 = .{ .bus = self.memory1.view() };
        try self.cpu0.reset(0);
        try self.cpu1.reset(0);
        self.machine0 = .{};
        self.machine1 = .{};
        var live: zig_session.ZigSession = .{ .core = .{ .cpu = &self.cpu0 }, .machine = &self.machine0, .budget = 100 };
        live.other = .{ .core = .{ .cpu = &self.cpu1 }, .machine = &self.machine1, .budget = 100, .index = 1 };
        self.session = .{ .live = live };
    }
};

test "a capture from a session's core rasterises to the pinned golden frame" {
    var rig: Rig = undefined;
    try rig.init();
    try rig.session.write(.cpu1, 0xE0, "RA8 memory pane!");
    const snapshot = try pane.capture(&rig.session, .cpu1, 0xE8, 4);
    var scene = try Scene.init();
    defer scene.deinit();
    try scene.render(&snapshot);
    try std.testing.expectEqual(@as(u64, 16333086650271298263), scene.digest());
}

test "capture reads each core through the session and marks unmapped bytes" {
    var rig: Rig = undefined;
    try rig.init();
    const session = &rig.session;
    try session.write(.cpu0, 0xE0, "RA8 memory pane!");
    try session.write(.cpu1, 0xE0, "second core here");
    const zero = try pane.capture(session, .cpu0, 0xE0, 3);
    const one = try pane.capture(session, .cpu1, 0xE0, 1);
    try std.testing.expectEqualStrings("RA8 memory pane!", zero.bytes[0..16]);
    try std.testing.expectEqualStrings("second core here", one.bytes[0..16]);
    for (zero.readable[0..32]) |readable| try std.testing.expect(readable);
    for (zero.readable[32..48]) |readable| try std.testing.expect(!readable);
    const straddle = try pane.capture(session, .cpu0, 0xF8, 2);
    for (straddle.readable[0..8]) |readable| try std.testing.expect(readable);
    for (straddle.readable[8..32]) |readable| try std.testing.expect(!readable);
    try std.testing.expectEqual(@as(u32, 0x108), straddle.rowAddress(1));
    const capped = try pane.capture(session, .cpu0, 0, pane.max_rows + 5);
    try std.testing.expectEqual(pane.max_rows, capped.count);
}
