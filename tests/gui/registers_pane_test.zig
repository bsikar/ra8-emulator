//! Covers src/gui/registers_pane.zig (RA8EMU-741, groups RA8EMU-945):
//! headers and cells run down a column and then across, a folded group
//! keeps only its header, the pane rasterises to pinned golden frames open
//! and with the system group folded, a changed register is the only text
//! drawn in the changed colour, a pane too small for one cell draws
//! nothing, and capture reads CPU0 and CPU1 separately through a real
//! session.
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
const pane = ra8.gui.registers_pane;

const Rect = draw_list.Rect;
/// Eight rows down, four columns across: room for both headers and all 26
/// registers.
const area = Rect{ .x = 0, .y = 0, .w = 2 * pane.pad + 4 * 120, .h = 2 * pane.pad + 8 * pane.row_h };
const system_folded: pane.Fold = .{ false, true };

fn sample() pane.Snapshot {
    var snapshot: pane.Snapshot = .{};
    for (&snapshot.values, 0..) |*value, index| value.* = 0x1000_0000 + @as(u32, @intCast(index)) * 0x0101;
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

    fn render(self: *Scene, now: pane.Snapshot, before: ?pane.Snapshot, fold: pane.Fold) !void {
        try pane.draw(&self.list, area, now, before, fold);
        raster.draw(&self.frame, &self.list, font.atlas);
    }

    fn digest(self: *const Scene) u64 {
        return std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(self.frame.pixels));
    }
};

test "headers and cells run down a column and then across" {
    try std.testing.expectEqual(@as(usize, 8), pane.rows(area));
    try std.testing.expectEqual(@as(usize, 4), pane.columns(area));
    const core = pane.headerRect(area, pane.open, 0).?;
    try std.testing.expectEqual(pane.pad, core.x);
    try std.testing.expectEqual(pane.pad, core.y);
    const first = pane.cellRect(area, pane.open, 0).?;
    try std.testing.expectEqual(pane.pad, first.x);
    try std.testing.expectEqual(pane.pad + pane.row_h, first.y);
    const eighth = pane.cellRect(area, pane.open, 7).?;
    try std.testing.expectEqual(pane.pad + 120, eighth.x);
    try std.testing.expectEqual(pane.pad, eighth.y);
    const system = pane.headerRect(area, pane.open, 1).?;
    try std.testing.expectEqual(pane.pad + 2 * 120, system.x);
    try std.testing.expectEqual(pane.pad + 3 * pane.row_h, system.y);
    const last = pane.cellRect(area, pane.open, 25).?;
    try std.testing.expectEqual(pane.pad + 3 * 120, last.x);
    try std.testing.expectEqual(pane.pad + 3 * pane.row_h, last.y);
    try std.testing.expectEqual(@as(?Rect, null), pane.cellRect(area, pane.open, 26));
}

test "a folded group keeps only its header, and the next group moves up" {
    try std.testing.expectEqual(@as(?Rect, null), pane.cellRect(area, system_folded, 18));
    try std.testing.expectEqual(pane.headerRect(area, pane.open, 1), pane.headerRect(area, system_folded, 1));
    const core_folded: pane.Fold = .{ true, false };
    try std.testing.expectEqual(@as(?Rect, null), pane.cellRect(area, core_folded, 0));
    try std.testing.expectEqual(pane.pad + pane.row_h, pane.headerRect(area, core_folded, 1).?.y);
    try std.testing.expectEqual(pane.pad + 2 * pane.row_h, pane.cellRect(area, core_folded, 18).?.y);
}

test "a press finds a group header and nothing on a cell" {
    const header = pane.headerRect(area, pane.open, 1).?;
    try std.testing.expectEqual(@as(?usize, 1), pane.headerAt(area, pane.open, header.x + 1, header.y + 1));
    const cell = pane.cellRect(area, pane.open, 0).?;
    try std.testing.expectEqual(@as(?usize, null), pane.headerAt(area, pane.open, cell.x + 1, cell.y + 1));
}

test "the pane rasterises to the pinned golden frame with every group open" {
    var scene = try Scene.init();
    defer scene.deinit();
    try scene.render(sample(), sample(), pane.open);
    try std.testing.expectEqual(@as(u64, 7508780865518467467), scene.digest());
}

test "the pane rasterises to the pinned golden frame with the system group folded" {
    var scene = try Scene.init();
    defer scene.deinit();
    try scene.render(sample(), sample(), system_folded);
    try std.testing.expectEqual(@as(u64, 5341974659234707467), scene.digest());
}

test "a changed register is the only text in the changed colour" {
    var scene = try Scene.init();
    defer scene.deinit();
    var now = sample();
    now.values[1] +%= 1;
    now.values[19] +%= 2;
    try scene.render(now, sample(), pane.open);
    var moved: usize = 0;
    for (scene.list.commands.items) |command| {
        if (command.shape == .glyph and std.meta.eql(command.shape.glyph.color, pane.changed)) moved += 1;
    }
    try std.testing.expectEqual(@as(usize, 16), moved);
    for (0..scene.frame.height) |y| {
        for (0..scene.frame.width) |x| {
            if (!std.meta.eql(scene.frame.at(@intCast(x), @intCast(y)), pane.changed)) continue;
            try std.testing.expect(inValue(1, x, y) or inValue(19, x, y));
        }
    }
}

fn inValue(index: usize, x: usize, y: usize) bool {
    const at = pane.valueOrigin(pane.cellRect(area, pane.open, index).?);
    const span = Rect{ .x = at.x, .y = at.y, .w = @intCast(font.textWidth(8)), .h = font.glyph_h };
    return span.contains(@intCast(x), @intCast(y));
}

test "no earlier snapshot marks nothing, and a pane too small draws nothing" {
    var scene = try Scene.init();
    defer scene.deinit();
    try scene.render(sample(), null, pane.open);
    for (scene.frame.pixels) |pixel| try std.testing.expect(!std.meta.eql(pixel, pane.changed));
    scene.list.clear();
    try pane.draw(&scene.list, .{ .x = 0, .y = 0, .w = 60, .h = 200 }, sample(), null, pane.open);
    try std.testing.expectEqual(@as(usize, 0), scene.list.commands.items.len);
}

/// A RAM image holding a vector table: initial sp 0x40, reset at 0x08.
const Ram = struct {
    bytes: [256]u8 = @splat(0),

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

test "capture reads each core's registers through the session" {
    var memory0 = Ram.init();
    var memory1 = Ram.init();
    var cpu0: Cpu = .{ .bus = memory0.view() };
    var cpu1: Cpu = .{ .bus = memory1.view() };
    try cpu0.reset(0);
    try cpu1.reset(0);
    var machine0 = Machine{};
    var machine1 = Machine{};
    var live: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu0 }, .machine = &machine0, .budget = 100 };
    live.other = .{ .core = .{ .cpu = &cpu1 }, .machine = &machine1, .budget = 100, .index = 1 };
    var session: api.Session = .{ .live = live };
    try session.setRegister(.cpu0, .r0, 0xCAFE_0000);
    try session.setRegister(.cpu1, .r0, 0x0000_BEEF);
    const zero = try pane.capture(&session, .cpu0);
    const one = try pane.capture(&session, .cpu1);
    try std.testing.expectEqual(@as(u32, 0xCAFE_0000), zero.values[0]);
    try std.testing.expectEqual(@as(u32, 0x0000_BEEF), one.values[0]);
    try std.testing.expectEqual(@as(u32, 0x40), zero.values[13]);
    try std.testing.expect(one.changedAt(zero, 0));
    try std.testing.expect(!one.changedAt(zero, 13));
}
