//! Tests for src/interfaces/rpc/frame_pipeline.zig (milestone M7):
//! the application frame pipeline wiring tap, worker and two-tier cache with host backing.
const std = @import("std");
const ra8 = @import("ra8");
const store_board = @import("../cli/store_board.zig");

const Board = ra8.board.board.Board;
const history = ra8.host.history;
const frame_pipeline = ra8.rpc.frame_pipeline;
const served_setup = ra8.rpc.served_setup;
const glcdc = ra8.chip.periph.glcdc;
const tcon = ra8.chip.periph.glcdc.tcon;
const glcdc_sys = ra8.chip.periph.glcdc.sys;
const pdctr = ra8.chip.periph.pdctr;
const prcr = ra8.chip.periph.prcr;
const session_display = ra8.session.display;
const frame_tap = ra8.session.history_frame_tap;

fn setupDisplay(board: *Board, initial_color: u32) void {
    board.protection.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
    board.domains.graphics.write(pdctr.Domain.graphics.base(), 1, 0);
    board.display.write(glcdc.win_base + tcon.off.sthb1, 4, 2);
    board.display.write(glcdc.win_base + tcon.off.stvb1, 4, 1);
    board.display.write(glcdc.win_base + glcdc.off.bg_en, 4, glcdc.field.bg_en);
    board.display.write(glcdc.win_base + glcdc_sys.off.panel_clk, 4, glcdc_sys.clock.enable);
    board.display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, initial_color);
}

fn waitCacheCount(io: std.Io, cache: anytype, target: usize) !void {
    var attempts: usize = 0;
    while (cache.count() < target and attempts < 2000) : (attempts += 1) {
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "frame pipeline captures keyframe and delta, and lookup retrieves exact pixels" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var base = try history.base.Base.openConfigured(gpa, io, root, .cache, .{});
    defer base.close();
    var session = try history.session.Session.create(&base, .{});
    defer _ = session.close(null, .move) catch {};
    const store = history.storage.Store.from(&session);

    var fake_store = try store_board.Store.init(null);
    defer fake_store.deinit();
    var board = Board.init(gpa);
    defer board.deinit();
    try store_board.attach(&board, .{ .store = &fake_store });
    setupDisplay(&board, 0xFF11_2233);

    var grid: ra8.chip.core.scheduler.State = .{ .at = .{ .branch = 0, .r = 1, .phase = .board, .o = 0, .gap = .retired } };

    var pipeline = try frame_pipeline.FramePipeline.init(
        gpa,
        io,
        &board,
        null,
        &grid,
        0,
        store,
        1024 * 1024 * 1024,
        100 * 1024 * 1024,
        frame_tap.Clock.fromIo(&io),
    );
    defer pipeline.deinit();
    pipeline.setIntervalNs(0);

    // Boundary 1: keyframe
    board.time.base.advance(100);
    const guest: store_board.Guest = .{ .store = &fake_store };
    try board.tick(guest, 1);
    try waitCacheCount(io, &pipeline.cache, 1);
    try std.testing.expectEqual(@as(usize, 1), pipeline.cache.count());

    // Boundary 2: delta with color change
    grid.at.r = 2;
    board.display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, 0xFF44_5566);
    board.time.base.advance(100);
    try board.tick(guest, 1);
    try waitCacheCount(io, &pipeline.cache, 2);
    try std.testing.expectEqual(@as(usize, 2), pipeline.cache.count());

    // Lookup earlier position (round 1)
    const pos1 = ra8.session.history_frame_types.Position{ .branch = 0, .r = 1, .phase = .board, .o = 0, .gap = .retired };
    const hit1 = try pipeline.cache.lookup(gpa, pos1);
    switch (hit1) {
        .frame => |f| {
            defer gpa.free(f.pixels);
            try std.testing.expectEqual(@as(u32, 2), f.width);
            try std.testing.expectEqual(@as(u32, 1), f.height);
            const expected_gray = session_display.grayscale(0xFF11_2233);
            try std.testing.expectEqualSlices(u8, &.{ expected_gray, expected_gray }, f.pixels);
        },
        else => return error.TestExpectedFrame,
    }

    // Lookup current position (round 2)
    const pos2 = ra8.session.history_frame_types.Position{ .branch = 0, .r = 2, .phase = .board, .o = 0, .gap = .retired };
    const hit2 = try pipeline.cache.lookup(gpa, pos2);
    switch (hit2) {
        .frame => |f| {
            defer gpa.free(f.pixels);
            try std.testing.expectEqual(@as(u32, 2), f.width);
            try std.testing.expectEqual(@as(u32, 1), f.height);
            const expected_gray = session_display.grayscale(0xFF44_5566);
            try std.testing.expectEqualSlices(u8, &.{ expected_gray, expected_gray }, f.pixels);
        },
        else => return error.TestExpectedFrame,
    }
}

test "integration: served session with history open runs pipeline and earlier lookup returns right frame" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    const image_path = "tests/fixtures/fpu/fp_basic.elf";
    var served: served_setup.Served = undefined;
    try served.open(gpa, io, image_path, null, .{
        .root = root,
        .checkpoint_every = 64,
        .budget = 128 * 1024 * 1024,
    });
    defer served.deinit();

    const cache = served.frameCache() orelse return error.MissingFrameCache;
    try std.testing.expect(served.frames != null);
    served.frames.?.setIntervalNs(0);

    const board = served.owner.board();
    setupDisplay(board, 0xFFAABBCC);

    const guest = served.owner.guest();
    board.time.base.advance(1000);
    try board.tick(guest, 10);
    try waitCacheCount(io, cache, 1);
    try std.testing.expectEqual(@as(usize, 1), cache.count());

    // Advance position for next boundary
    const state_file: *ra8.session.harness.files.StateFile = @ptrCast(@alignCast(served.owner.stateFiles().context));
    state_file.files.edge.saved.at.r = 1;

    // Second boundary with new color
    board.display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, 0xFF223344);
    board.time.base.advance(1000);
    try board.tick(guest, 10);
    try waitCacheCount(io, cache, 2);
    try std.testing.expect(cache.count() >= 2);

    // Earlier position lookup (round 0)
    const pos1 = ra8.session.history_frame_types.Position{ .branch = 0, .r = 0, .phase = .board, .o = 0, .gap = .retired };
    const hit1 = try cache.lookup(gpa, pos1);
    switch (hit1) {
        .frame => |f| {
            defer gpa.free(f.pixels);
            const exp1 = session_display.grayscale(0xFFAABBCC);
            try std.testing.expectEqualSlices(u8, &.{ exp1, exp1 }, f.pixels);
        },
        else => return error.TestExpectedFrame,
    }

    // Current position lookup (round 1)
    const pos2 = ra8.session.history_frame_types.Position{ .branch = 0, .r = 1, .phase = .board, .o = 0, .gap = .retired };
    const hit2 = try cache.lookup(gpa, pos2);
    switch (hit2) {
        .frame => |f| {
            defer gpa.free(f.pixels);
            const exp2 = session_display.grayscale(0xFF223344);
            try std.testing.expectEqualSlices(u8, &.{ exp2, exp2 }, f.pixels);
        },
        else => return error.TestExpectedFrame,
    }
}

test "StorageBacking.createFn closes opened byte_file when allocator fails" {
    const Mock = struct {
        closed: bool = false,

        fn mockClose(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.closed = true;
        }

        const byte_file_vtable = history.storage.ByteFile.Vtable{
            .read = undefined,
            .write = undefined,
            .length = undefined,
            .truncate = undefined,
            .sync = undefined,
            .close = mockClose,
        };

        fn mockOpen(ctx: *anyopaque, _: history.layout.Space, _: []const u8, _: history.storage.Mode) anyerror!history.storage.ByteFile {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return .{
                .context = self,
                .vtable = &byte_file_vtable,
            };
        }

        const store_vtable = history.storage.Store.Vtable{
            .open = mockOpen,
            .remove = undefined,
            .rename = undefined,
            .list = undefined,
        };
    };

    var mock = Mock{};
    const store = history.storage.Store{
        .context = &mock,
        .vtable = &Mock.store_vtable,
    };

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var backing = frame_pipeline.StorageBacking{
        .allocator = failing.allocator(),
        .store = store,
    };

    const iface = backing.backing();
    try std.testing.expectError(error.OutOfMemory, iface.createFn(iface.context, "seg-0"));
    try std.testing.expect(mock.closed);
}
