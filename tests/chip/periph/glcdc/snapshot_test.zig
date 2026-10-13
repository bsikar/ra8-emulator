//! RA8EMU-668: the GLCDC saved busy and loaded into a fresh one matches
//! byte for byte and keeps the fresh controller's domain and vsync hook.
const std = @import("std");
const ra8 = @import("ra8");
const glcdc = ra8.chip.periph.glcdc;
const pdctr = ra8.chip.periph.pdctr;
const prcr = ra8.chip.periph.prcr;
const file = ra8.snapshot.file;
const display = ra8.chip.periph.glcdc.snapshot;

const Stand = struct { display: glcdc.Glcdc };

fn guard() prcr.Prcr {
    var unit = prcr.Prcr.init();
    unit.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
    return unit;
}

fn busy(domain: *const pdctr.Pdctr) Stand {
    var board: Stand = .{ .display = glcdc.Glcdc.init(domain) };
    board.display.registers[3] = 0xDEAD_BEEF;
    board.display.palettes[1].store(0, 7, 0xFF11_2233);
    board.display.palettes[1].selected = 1;
    board.display.blends[0].base_colour = 0x0055_AA00;
    board.display.output.commits = 4;
    board.display.output.gamma_on = true;
    board.display.timing.h_active = 1024;
    board.display.system.frames = 60;
    board.display.starts = 2;
    return board;
}

fn saved(board: *const Stand, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try display.save(board, &list.writer);
}

var frames: u32 = 0;
fn onFrame(context: *anyopaque, when_ns: u64) void {
    _ = context;
    _ = when_ns;
    frames += 1;
}

test "a busy controller round-trips and the fresh one keeps its wiring" {
    const lock = guard();
    var domain = pdctr.Pdctr.init(&lock, .graphics);
    var other = pdctr.Pdctr.init(&lock, .graphics);
    var board = busy(&domain);
    board.display.output.vsync = .{ .sink = .{ .context = &domain, .frame = onFrame } };
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var fresh: Stand = .{ .display = glcdc.Glcdc.init(&other) };
    fresh.display.output.vsync = .{ .sink = .{ .context = &other, .frame = onFrame } };
    try display.load(&fresh, list.written());
    try std.testing.expect(fresh.display.domain == &other);
    try std.testing.expect(fresh.display.output.vsync != null);
    try std.testing.expectEqual(@as(u32, 0xFF11_2233), fresh.display.palettes[1].planes[0][7]);
    try std.testing.expectEqual(@as(u32, 1024), fresh.display.timing.h_active);
    var again = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer again.deinit();
    try saved(&fresh, &again);
    try std.testing.expectEqualSlices(u8, list.written(), again.written());
}

test "a palette plane or filled count out of range is BadValue and nothing changes" {
    const lock = guard();
    var domain = pdctr.Pdctr.init(&lock, .graphics);
    var board = busy(&domain);
    board.display.palettes[0].selected = 2;
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var fresh: Stand = .{ .display = glcdc.Glcdc.init(&domain) };
    try std.testing.expectError(error.BadValue, display.load(&fresh, list.written()));
    board.display.palettes[0].selected = 0;
    board.display.palettes[0].filled[1] = 257;
    list.clearRetainingCapacity();
    try saved(&board, &list);
    try std.testing.expectError(error.BadValue, display.load(&fresh, list.written()));
    try std.testing.expectEqual(@as(u32, 0), fresh.display.starts);
}

test "a missing section or a cut payload leaves the controller untouched" {
    const lock = guard();
    var domain = pdctr.Pdctr.init(&lock, .graphics);
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try file.writeHeader(&list.writer);
    var fresh: Stand = .{ .display = glcdc.Glcdc.init(&domain) };
    fresh.display.latches = 9;
    try std.testing.expectError(error.Missing, display.load(&fresh, list.written()));
    const board = busy(&domain);
    list.clearRetainingCapacity();
    try saved(&board, &list);
    try std.testing.expect(std.meta.isError(display.load(&fresh, list.written()[0 .. list.written().len - 1])));
    try std.testing.expectEqual(@as(u32, 9), fresh.display.latches);
}

fn scanFrame(context: *anyopaque, _: u64) void {
    const unit: *glcdc.Glcdc = @ptrCast(@alignCast(context));
    _ = unit.scanOut();
}
fn setFrame(board: *Stand, guest: ra8.chip.core.cpu.memory.guest.Guest) void {
    board.display.memory = guest;
    board.display.registers[glcdc.off.bg_en / 4] = 1;
    board.display.timing.h_active = 2;
    board.display.timing.v_active = 2;
    board.display.timing.sized = true;
    board.display.system.panel_clk = glcdc.sys.clock.enable;
    board.display.system.detect = glcdc.sys.state.vpos;
    board.display.output.vsync = .{ .sink = .{ .context = &board.display, .frame = scanFrame }, .period_ns = 100, .next_ns = 100 };
}
test "vsync restore continues real scan status and next boundary against reference" {
    const lock = guard();
    var domain = pdctr.Pdctr.init(&lock, .graphics);
    domain.write(pdctr.Domain.graphics.base(), 1, 0);
    var store = try ra8.chip.core.cpu.memory.store.Store.init(null);
    defer store.deinit();
    const guest: ra8.chip.core.cpu.memory.guest.Guest = .{ .store = &store };
    var live: Stand = .{ .display = glcdc.Glcdc.init(&domain) };
    var reference: Stand = .{ .display = glcdc.Glcdc.init(&domain) };
    var fresh: Stand = .{ .display = glcdc.Glcdc.init(&domain) };
    setFrame(&live, guest);
    setFrame(&reference, guest);
    setFrame(&fresh, guest);
    live.display.output.vsync.?.tick(99);
    reference.display.output.vsync.?.tick(99);
    var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bytes.deinit();
    try saved(&live, &bytes);
    live.display.output.vsync.?.tick(450);
    fresh.display.output.vsync.?.next_ns = 900;
    try display.load(&live, bytes.written());
    try display.load(&fresh, bytes.written());
    try std.testing.expect(live.display.output.vsync.?.sink.context == @as(*anyopaque, @ptrCast(&live.display)));
    try std.testing.expect(fresh.display.output.vsync.?.sink.context == @as(*anyopaque, @ptrCast(&fresh.display)));
    try std.testing.expect(fresh.display.output.vsync.?.sink.frame == scanFrame);
    for ([_]u64{ 99, 100, 350, 399, 400 }) |now| {
        reference.display.output.vsync.?.tick(now);
        live.display.output.vsync.?.tick(now);
        fresh.display.output.vsync.?.tick(now);
        for ([_]*Stand{ &live, &fresh }) |target| {
            try std.testing.expectEqual(reference.display.system.frames, target.display.system.frames);
            try std.testing.expectEqual(reference.display.system.status, target.display.system.status);
            try std.testing.expectEqual(reference.display.system.detections, target.display.system.detections);
            try std.testing.expectEqual(reference.display.output.vsync.?.next_ns, target.display.output.vsync.?.next_ns);
            try std.testing.expectEqual(reference.display.output.vsync.?.boundaries, target.display.output.vsync.?.boundaries);
            try std.testing.expectEqual(reference.display.output.vsync.?.swallowed, target.display.output.vsync.?.swallowed);
        }
    }
    try std.testing.expectEqual(@as(u32, 3), live.display.system.frames);
    try std.testing.expectEqual(@as(u32, glcdc.sys.state.vpos), live.display.system.status);
}
test "vsync malformed configuration and phase refuse before controller install" {
    const lock = guard();
    var domain = pdctr.Pdctr.init(&lock, .graphics);
    var live = busy(&domain);
    live.display.output.vsync = .{ .sink = .{ .context = &domain, .frame = onFrame } };
    var target = live;
    target.display.starts = 19;
    for (0..6) |trial| {
        var source = live;
        if (trial == 0) source.display.output.vsync.?.period_ns = 0;
        if (trial == 1) source.display.output.vsync.?.period_ns += 1;
        if (trial == 2) {
            source.display.output.vsync.?.next_ns = 0;
            source.display.output.vsync.?.boundaries = 1;
        }
        if (trial == 3) source.display.output.vsync.?.swallowed = 1;
        if (trial == 4) source.display.output.vsync.?.boundaries = 2;
        if (trial == 5) {
            source.display.output.vsync.?.boundaries = 1;
            source.display.output.vsync.?.swallowed = 1;
        }
        var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer bytes.deinit();
        try saved(&source, &bytes);
        try std.testing.expectError(error.BadValue, display.load(&target, bytes.written()));
        try std.testing.expectEqual(@as(u32, 19), target.display.starts);
        try std.testing.expect(target.display.output.vsync.?.sink.context == @as(*anyopaque, @ptrCast(&domain)));
    }
    live.display.output.vsync.?.next_ns = 0;
    var zero = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer zero.deinit();
    try saved(&live, &zero);
    try display.load(&target, zero.written());
    try std.testing.expectEqual(@as(u64, 0), target.display.output.vsync.?.next_ns);
}
