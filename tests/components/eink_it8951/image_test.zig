//! The e-ink planes: allocated at the panel geometry on first use and
//! clipping writes outside it.
const std = @import("std");
const ra8 = @import("ra8");
const eink = ra8.components.eink;
const proto = ra8.components.eink.wire;

fn word(panel: *eink.Panel, value: u16) void {
    _ = panel.exchange(@intCast(value >> 8));
    _ = panel.exchange(@intCast(value & 0xFF));
}

fn command(panel: *eink.Panel, code: proto.Command) void {
    word(panel, proto.preamble.command);
    word(panel, @backingInt(code));
}

fn data(panel: *eink.Panel, value: u16) void {
    word(panel, proto.preamble.write);
    word(panel, value);
}

fn openLoad(panel: *eink.Panel, width: u16, height: u16) void {
    command(panel, .load_area);
    data(panel, 0x0030);
    data(panel, 0);
    data(panel, 0);
    data(panel, width);
    data(panel, height);
}

fn refresh(panel: *eink.Panel, width: u16, height: u16, mode: u16) void {
    command(panel, .display_area);
    data(panel, 0);
    data(panel, 0);
    data(panel, width);
    data(panel, height);
    data(panel, mode);
}

test "the image plane clips writes outside the default 1072x1448 panel" {
    var panel = eink.Panel.init();
    panel.planes.allocator = std.testing.allocator;
    defer panel.deinit();
    try std.testing.expect(panel.planes.ready());
    panel.planes.image.set(1071, 1447, 0x55);
    panel.planes.image.set(1072, 0, 0xAA);
    panel.planes.image.set(0, 1448, 0xAA);
    try std.testing.expectEqual(@as(u8, 0x55), panel.planes.image.pixel(1071, 1447));
    try std.testing.expectEqual(@as(u8, 0), panel.planes.image.pixel(1072, 0));
    try std.testing.expectEqual(@as(usize, 1072 * 1448), panel.planes.glass.pixels.len);
}

test "a resized panel allocates and clips at its own geometry" {
    var panel = eink.Panel.init();
    panel.planes.allocator = std.testing.allocator;
    defer panel.deinit();
    panel.planes.resize(try proto.Geometry.parse("16x8"));
    try std.testing.expect(panel.planes.ready());
    panel.planes.image.set(15, 7, 9);
    panel.planes.image.set(16, 0, 9);
    try std.testing.expectEqual(@as(u8, 9), panel.planes.image.pixel(15, 7));
    try std.testing.expectEqual(@as(usize, 128), panel.planes.image.pixels.len);
    panel.planes.resize(.{});
    try std.testing.expectEqual(@as(usize, 0), panel.planes.image.pixels.len);
}

test "DU and both A2 LUT modes quantize to black and white over the blank glass" {
    const modes = [_]u16{ proto.waveform.du, proto.waveform.a2_m641, proto.waveform.a2_generic };
    for (modes) |mode| {
        var panel = eink.Panel.init();
        defer panel.deinit();
        openLoad(&panel, 4, 1);
        data(&panel, 0x407F);
        data(&panel, 0x80FF);
        refresh(&panel, 4, 1, mode);
        // The glass starts black, so the white pair flips and keeps an
        // eighth of the old black as residue (RA8EMU-559).
        const expected = [_]u8{ 0, 0, 0xE0, 0xE0 };
        for (expected, 0..) |value, x| {
            try std.testing.expectEqual(value, panel.planes.glass.pixel(@intCast(x), 0));
        }
    }
}

test "GC16 refresh preserves sixteen distinct grey levels" {
    var panel = eink.Panel.init();
    defer panel.deinit();
    openLoad(&panel, 16, 1);
    for (0..8) |pair| {
        const low: u16 = @intCast(pair * 2 * 17);
        const high: u16 = @intCast((pair * 2 + 1) * 17);
        data(&panel, low | (high << 8));
    }
    refresh(&panel, 16, 1, proto.waveform.gc16);
    for (0..16) |index| {
        try std.testing.expectEqual(@as(u8, @intCast(index * 17)), panel.planes.glass.pixel(@intCast(index), 0));
    }
}

test "INIT refresh clears its rectangle to white" {
    var panel = eink.Panel.init();
    defer panel.deinit();
    openLoad(&panel, 2, 1);
    data(&panel, 0x2412);
    refresh(&panel, 1, 1, proto.waveform.init);
    try std.testing.expectEqual(@as(u8, 0xFF), panel.planes.glass.pixel(0, 0));
    try std.testing.expectEqual(@as(u8, 0), panel.planes.glass.pixel(1, 0));
}

test "planes that cannot be allocated drop the write and count it" {
    var panel = eink.Panel.init();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    panel.planes.allocator = failing.allocator();
    defer panel.deinit();
    try std.testing.expect(!panel.planes.ready());
    try std.testing.expectEqual(@as(u32, 1), panel.planes.unplaced);
    try std.testing.expectEqual(@as(usize, 0), panel.planes.image.pixels.len);
}

const observer = ra8.chip.core.cpu.memory.observer;

/// A recording observer the tests attach to a plane or the planes (H6).
const Hook = struct {
    writes: [16]W = undefined,
    write_count: usize = 0,
    barriers: usize = 0,

    const W = struct { offset: u64 = 0, pre: u8 = 0 };

    const vtable = observer.Observer.VTable{ .bytes = bytes, .barrier = barrier };

    fn bytes(ctx: *anyopaque, write: observer.Write) void {
        const self: *Hook = @ptrCast(@alignCast(ctx));
        self.writes[self.write_count] = .{ .offset = write.offset, .pre = write.pre[0] };
        self.write_count += 1;
    }

    fn barrier(ctx: *anyopaque, event: observer.Barrier) void {
        const self: *Hook = @ptrCast(@alignCast(ctx));
        switch (event) {
            .component => |c| if (c.what == .resize) {
                self.barriers += 1;
            },
            else => unreachable,
        }
    }

    fn obs(self: *Hook) observer.Observer {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

test "a set records the pixel it changes, and nothing else" {
    var px: [16]u8 = @splat(0);
    var buf = eink.image.Buffer{ .width = 4, .height = 4, .pixels = &px };
    var hook = Hook{};
    buf.obs = hook.obs();

    buf.set(1, 2, 0x99);
    try std.testing.expectEqual(@as(usize, 1), hook.write_count);
    try std.testing.expectEqual(@as(u64, 2 * 4 + 1), hook.writes[0].offset);
    try std.testing.expectEqual(@as(u8, 0), hook.writes[0].pre);
    try std.testing.expectEqual(@as(u8, 0x99), buf.pixel(1, 2));

    // Same value again, and a write outside the plane: no records.
    buf.set(1, 2, 0x99);
    buf.set(9, 0, 0x11);
    try std.testing.expectEqual(@as(usize, 1), hook.write_count);
}

test "a refresh records the pixels the waveform leaves different" {
    var src_px: [16]u8 = @splat(0x00);
    var source = eink.image.Buffer{ .width = 4, .height = 4, .pixels = &src_px };
    var glass_px: [16]u8 = @splat(0xEE);
    var glass = eink.image.Buffer{ .width = 4, .height = 4, .pixels = &glass_px };
    var hook = Hook{};
    glass.obs = hook.obs();

    glass.refreshFrom(&source, 0, 0, 4, 4, proto.waveform.gc16);
    // Every driven pixel changed from 0xEE; each records its old level.
    try std.testing.expectEqual(@as(usize, 16), hook.write_count);
    try std.testing.expectEqual(@as(u64, 0), hook.writes[0].offset);
    try std.testing.expectEqual(@as(u8, 0xEE), hook.writes[0].pre);
    try std.testing.expectEqual(@as(u8, 0x00), glass.pixel(0, 0));
}

test "a resize raises a barrier and fresh planes inherit the observer" {
    var planes = eink.image.Planes{};
    defer planes.deinit();
    var hook = Hook{};
    planes.obs = hook.obs();

    planes.resize(.{ .width = 4, .height = 4 });
    try std.testing.expectEqual(@as(usize, 1), hook.barriers);
    try std.testing.expect(planes.ready());
    planes.image.set(0, 0, 0x42);
    try std.testing.expectEqual(@as(usize, 1), hook.write_count);
}
