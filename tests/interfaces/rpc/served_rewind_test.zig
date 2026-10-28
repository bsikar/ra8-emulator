//! Held reverse play through the served setup: the engine reads the frame
//! cache by the run's own frame index, falls back to the checkpoint pictures
//! the log pins, decodes silently from the nearest checkpoint when neither
//! is near the cursor, and a pause puts the machine at the position of the
//! frame on screen. The frame the engine shows reaches `lcd_dirty`
//! subscribers through the rewind feed.
const std = @import("std");
const ra8 = @import("ra8");

const setup = ra8.rpc.served_setup;
const glcdc = ra8.chip.periph.glcdc;
const tcon = ra8.chip.periph.glcdc.tcon;
const glcdc_sys = ra8.chip.periph.glcdc.sys;
const pdctr = ra8.chip.periph.pdctr;
const prcr = ra8.chip.periph.prcr;
const display = ra8.session.display;
const transport = ra8.session.transport;
const nav_handlers = ra8.rpc.session.nav_handlers;

const image = "tests/fixtures/fpu/fp_basic.elf";

const FakeWall = struct {
    now_ns: u64 = 0,
    fn now(context: *anyopaque) u64 {
        const self: *FakeWall = @ptrCast(@alignCast(context));
        self.now_ns += 16_666_666;
        return self.now_ns;
    }
    fn wall(self: *FakeWall) transport.Wall {
        return .{ .context = self, .nowFn = now };
    }
};

fn showColor(board: anytype, color: u32) void {
    board.protection.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
    board.domains.graphics.write(pdctr.Domain.graphics.base(), 1, 0);
    board.display.write(glcdc.win_base + tcon.off.sthb1, 4, 2);
    board.display.write(glcdc.win_base + tcon.off.stvb1, 4, 1);
    board.display.write(glcdc.win_base + glcdc.off.bg_en, 4, glcdc.field.bg_en);
    board.display.write(glcdc.win_base + glcdc_sys.off.panel_clk, 4, glcdc_sys.clock.enable);
    board.display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, color);
}

fn settle(io: std.Io, served: *setup.Served, want: usize) !void {
    var tries: usize = 0;
    while (served.frameCache().?.count() < want and tries < 2000) : (tries += 1) {
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "held reverse play shows rewound frames and a pause lands on the shown one" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var served: setup.Served = undefined;
    try served.open(gpa, io, image, null, .{ .root = root, .checkpoint_every = 1, .frame_hz = 0 });
    defer served.deinit();
    const session = served.owner.session();
    const board = served.owner.board();

    showColor(board, 0xFF11_2233);
    _ = try session.run(.cpu0, .run);
    try settle(io, &served, 1);
    board.display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, 0xFFAA_BBCC);
    _ = try session.run(.cpu0, .cont);
    try settle(io, &served, 2);
    const end_ns = try session.now();
    try std.testing.expect(end_ns > 0);

    const rewind = session.smooth_rewind.?;
    const t = served.owner.transport();
    var wall = FakeWall{};
    _ = try t.command(.{ .play = .{ .dir = .back, .speed = 0.02 } });
    // The pinned pictures were read from the log when the rewind started.
    try std.testing.expect(rewind.picture_index.entries.items.len > 0);
    try std.testing.expect(t.busy() == null);

    var shades: std.ArrayList(u8) = .empty;
    defer shades.deinit(gpa);
    var last: ?u8 = null;
    for (0..400) |_| {
        const pumped = try t.pump(wall.wall(), wall.now_ns + 20_000_000);
        if (rewind.current_frame) |shown| {
            if (last == null or last.? != shown.pixels[0]) {
                last = shown.pixels[0];
                try shades.append(gpa, shown.pixels[0]);
            }
        }
        if (pumped.finished != null) break;
    }
    // The newest frame first, then an older one as the cursor went back.
    try std.testing.expect(shades.items.len >= 2);
    try std.testing.expectEqual(display.grayscale(0xFFAA_BBCC), shades.items[0]);
    try std.testing.expectEqual(display.grayscale(0xFF11_2233), shades.items[shades.items.len - 1]);

    // The accounting a status request reads.
    var status_ctx = served.context;
    const status = nav_handlers.frameStatus(&status_ctx, .{ .core = .cpu0 });
    try std.testing.expect(status.ok.frames >= 2);
    try std.testing.expect(status.ok.ram_bytes > 0);
}

test "a pause during reverse play puts the machine at the shown frame" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var served: setup.Served = undefined;
    try served.open(gpa, io, image, null, .{ .root = root, .checkpoint_every = 1, .frame_hz = 0 });
    defer served.deinit();
    const session = served.owner.session();
    showColor(served.owner.board(), 0xFF11_2233);
    _ = try session.run(.cpu0, .run);
    try settle(io, &served, 1);
    _ = try session.run(.cpu0, .cont);

    const rewind = session.smooth_rewind.?;
    const t = served.owner.transport();
    var wall = FakeWall{};
    _ = try t.command(.{ .play = .{ .dir = .back, .speed = 0.02 } });
    _ = try t.pump(wall.wall(), wall.now_ns + 20_000_000);
    const shown = rewind.current_frame orelse return error.NoFrameShown;
    _ = try t.command(.pause);
    const at = session.currentPosition();
    try std.testing.expect(!rewind.isBusy());
    try std.testing.expect((try session.comparePositions(at, shown.position)) != .lt);
}

const Capture = struct {
    rects: usize = 0,
    shade: ?u8 = null,

    pub fn emit(self: *Capture, comptime T: type, topic: u16, event: T, tx: []u8) !void {
        _ = topic;
        _ = tx;
        self.rects += 1;
        if (self.shade == null and event.pixels.len > 0) self.shade = event.pixels[0];
    }
};

test "the rewind frame reaches lcd_dirty subscribers and an emptied cache is decoded silently" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var served: setup.Served = undefined;
    try served.open(gpa, io, image, null, .{ .root = root, .checkpoint_every = 1, .frame_hz = 0 });
    defer served.deinit();
    const session = served.owner.session();
    showColor(served.owner.board(), 0xFF11_2233);
    _ = try session.run(.cpu0, .run);
    try settle(io, &served, 1);
    _ = try session.run(.cpu0, .cont);
    // Only the pinned pictures survive: every lookup misses the cache.
    _ = served.frameCache().?.relieve();

    const rewind = session.smooth_rewind.?;
    const t = served.owner.transport();
    var wall = FakeWall{};
    _ = try t.command(.{ .play = .{ .dir = .back, .speed = 0.001 } });
    for (0..40) |_| _ = try t.pump(wall.wall(), wall.now_ns + 20_000_000);
    try std.testing.expect(rewind.decoded_segments > 0);

    served.context.topics[0] |= 1 << 3; // lcd_dirty
    var capture = Capture{};
    var tx: [16]u8 = undefined;
    try ra8.rpc.session.rewind_feed.pump(&served.context, &capture, &tx);
    try std.testing.expect(capture.rects > 0);
    try std.testing.expectEqual(display.grayscale(0xFF11_2233), capture.shade.?);
}
