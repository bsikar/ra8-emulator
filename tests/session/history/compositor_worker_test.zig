//! Tests for src/session/history/compositor_worker.zig:
//! - Worker uses only immutable value copies
//! - Keyframe and delta crop emission
//! - Delta crop reconstruction byte-exact
//! - Queue bound / regenerate marker propagation
//! - Epoch cancellation drops obsolete tasks
//! - Background worker thread execution
const std = @import("std");
const ra8 = @import("ra8");
const compositor_worker = ra8.session.history_compositor_worker;
const frame_queue = ra8.session.history_frame_queue;
const frame_types = ra8.session.history_frame_types;
const frame_crop = ra8.session.history_frame_crop;

const Glcdc = ra8.chip.periph.glcdc.Glcdc;
const pdctr = ra8.chip.periph.pdctr;
const prcr = ra8.chip.periph.prcr;
const tcon = ra8.chip.periph.glcdc.tcon;
const glcdc_mod = ra8.chip.periph.glcdc;
const store_memory = @import("../../chip/periph/store_memory.zig");

const SinkCollector = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayListUnmanaged(frame_types.FrameRecord) = .empty,

    fn init(allocator: std.mem.Allocator) SinkCollector {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *SinkCollector) void {
        for (self.records.items) |*rec| {
            if (rec.payload.len > 0) self.allocator.free(rec.payload);
        }
        self.records.deinit(self.allocator);
    }

    fn sink(self: *SinkCollector) frame_types.FrameSink {
        return .{
            .ctx = self,
            .writeFrameFn = deliverRecord,
        };
    }

    fn deliverRecord(ctx: *anyopaque, record: frame_types.FrameRecord) anyerror!void {
        const self: *SinkCollector = @ptrCast(@alignCast(ctx));
        var owned_record = record;
        if (record.payload.len > 0) {
            owned_record.payload = try self.allocator.dupe(u8, record.payload);
        }
        try self.records.append(self.allocator, owned_record);
    }
};

const Bench = struct {
    guard: prcr.Prcr,
    domain: pdctr.Pdctr,
    dev: Glcdc,
    core: store_memory.Guest,

    fn init(width: u32, height: u32, bg_color: u32) !Bench {
        var self: Bench = undefined;
        self.core = try store_memory.open();
        self.guard = prcr.Prcr.init();
        self.guard.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
        self.domain = pdctr.Pdctr.init(&self.guard, .graphics);
        self.domain.write(pdctr.Domain.graphics.base(), 1, 0);
        self.dev = Glcdc.init(&self.domain);
        self.dev.memory = self.core;
        self.dev.write(glcdc_mod.win_base + tcon.off.sthb1, 4, width);
        self.dev.write(glcdc_mod.win_base + tcon.off.stvb1, 4, height);
        self.dev.write(glcdc_mod.win_base + glcdc_mod.off.bg_en, 4, glcdc_mod.field.bg_en);
        self.dev.write(glcdc_mod.win_base + glcdc_mod.sys.off.panel_clk, 4, glcdc_mod.sys.clock.enable);
        self.dev.write(glcdc_mod.win_base + glcdc_mod.off.bg_bgc, 4, bg_color);
        return self;
    }

    fn deinit(self: *Bench) void {
        store_memory.close(self.core);
    }
};

test "worker uses only copies and emits valid keyframe" {
    const allocator = std.testing.allocator;
    var queue = frame_queue.Queue.init(allocator, 1024 * 1024);
    defer queue.deinit();

    var collector = SinkCollector.init(allocator);
    defer collector.deinit();

    var worker = compositor_worker.CompositorWorker.init(allocator, &queue, collector.sink());
    defer worker.deinit();

    var bench = try Bench.init(10, 8, 0xFF445566);
    defer bench.deinit();
    const source = bench.dev.compositeInputs().?;

    // Push task into queue
    const task = frame_queue.Task{
        .kind = .keyframe,
        .position = .{ .branch = 1, .r = 42, .phase = .board, .o = 0, .gap = .retired },
        .virtual_ns = 500_000,
        .width = 10,
        .height = 8,
        .epoch = 0,
        .glcdc = bench.dev,
        .source = source,
        .powered = true,
        .layer_bytes = null,
        .bytes_cost = 0,
    };
    try queue.push(task);

    // Drain synchronously
    const drained = try worker.drain();
    try std.testing.expectEqual(@as(usize, 1), drained);
    try std.testing.expectEqual(@as(usize, 1), collector.records.items.len);

    const rec = collector.records.items[0];
    try std.testing.expectEqual(frame_types.FrameKind.keyframe, rec.header.kind);
    try std.testing.expectEqual(@as(u16, 10), rec.header.rect.width);
    try std.testing.expectEqual(@as(u16, 8), rec.header.rect.height);
    try std.testing.expect(rec.payload.len > 0);
    try std.testing.expectEqual(frame_types.FrameHeader.computeCrc(rec.payload), rec.header.crc32c);

    // Decompress payload and check dimensions
    const decompressed = try allocator.alloc(u8, 80);
    defer allocator.free(decompressed);
    try frame_crop.decompress(allocator, rec.payload, decompressed);
    try std.testing.expectEqual(@as(usize, 80), decompressed.len);
}

test "queue bound and regenerate marker emission" {
    const allocator = std.testing.allocator;
    var queue = frame_queue.Queue.init(allocator, 1024 * 1024);
    defer queue.deinit();

    var collector = SinkCollector.init(allocator);
    defer collector.deinit();

    var worker = compositor_worker.CompositorWorker.init(allocator, &queue, collector.sink());
    defer worker.deinit();

    var bench = try Bench.init(10, 8, 0xFF112233);
    defer bench.deinit();
    const source = bench.dev.compositeInputs().?;

    const task = frame_queue.Task{
        .kind = .regenerate_by_replay,
        .position = .{ .branch = 2, .r = 100, .phase = .board, .o = 0, .gap = .retired },
        .virtual_ns = 1_000_000,
        .width = 10,
        .height = 8,
        .epoch = 0,
        .glcdc = bench.dev,
        .source = source,
        .powered = true,
        .layer_bytes = null,
        .bytes_cost = 0,
    };
    try queue.push(task);

    const drained = try worker.drain();
    try std.testing.expectEqual(@as(usize, 1), drained);
    try std.testing.expectEqual(@as(usize, 1), collector.records.items.len);

    const rec = collector.records.items[0];
    try std.testing.expectEqual(frame_types.FrameKind.regenerate_by_replay, rec.header.kind);
    try std.testing.expectEqual(@as(usize, 0), rec.payload.len);
    try std.testing.expectEqual(@as(u32, 0), rec.header.compressed_len);
    try std.testing.expectEqual(@as(u32, 0), rec.header.crc32c);
}

test "keyframe and delta crop round trip byte-exact" {
    const allocator = std.testing.allocator;
    var queue = frame_queue.Queue.init(allocator, 1024 * 1024);
    defer queue.deinit();

    var collector = SinkCollector.init(allocator);
    defer collector.deinit();

    var worker = compositor_worker.CompositorWorker.init(allocator, &queue, collector.sink());
    defer worker.deinit();

    const width: u32 = 16;
    const height: u32 = 16;

    // Frame 1: solid black background
    var bench1 = try Bench.init(width, height, 0xFF000000);
    defer bench1.deinit();
    const source1 = bench1.dev.compositeInputs().?;
    try queue.push(.{
        .kind = .keyframe,
        .position = .{ .branch = 0, .r = 1, .phase = .board, .o = 0, .gap = .retired },
        .virtual_ns = 1_000_000,
        .width = width,
        .height = height,
        .epoch = 0,
        .glcdc = bench1.dev,
        .source = source1,
        .powered = true,
        .layer_bytes = null,
        .bytes_cost = 0,
    });

    // Frame 2: solid white background (delta)
    var bench2 = try Bench.init(width, height, 0xFFFFFFFF);
    defer bench2.deinit();
    const source2 = bench2.dev.compositeInputs().?;
    try queue.push(.{
        .kind = .delta,
        .position = .{ .branch = 0, .r = 2, .phase = .board, .o = 0, .gap = .retired },
        .virtual_ns = 2_000_000,
        .width = width,
        .height = height,
        .epoch = 0,
        .glcdc = bench2.dev,
        .source = source2,
        .powered = true,
        .layer_bytes = null,
        .bytes_cost = 0,
    });

    _ = try worker.drain();
    try std.testing.expectEqual(@as(usize, 2), collector.records.items.len);

    const key_rec = collector.records.items[0];
    const delta_rec = collector.records.items[1];

    try std.testing.expectEqual(frame_types.FrameKind.keyframe, key_rec.header.kind);
    try std.testing.expectEqual(frame_types.FrameKind.delta, delta_rec.header.kind);

    // Decompress keyframe
    const key_gray = try allocator.alloc(u8, width * height);
    defer allocator.free(key_gray);
    try frame_crop.decompress(allocator, key_rec.payload, key_gray);

    // Reconstruct frame 2
    const reconstructed = try frame_crop.reconstruct(allocator, key_gray, width, delta_rec.header.rect, delta_rec.payload);
    defer allocator.free(reconstructed);

    // Frame 2 should be solid white (gray = 255)
    for (reconstructed) |pixel| {
        try std.testing.expectEqual(@as(u8, 255), pixel);
    }
}

test "epoch cancellation drops obsolete tasks" {
    const allocator = std.testing.allocator;
    var queue = frame_queue.Queue.init(allocator, 1024 * 1024);
    defer queue.deinit();

    var collector = SinkCollector.init(allocator);
    defer collector.deinit();

    var worker = compositor_worker.CompositorWorker.init(allocator, &queue, collector.sink());
    defer worker.deinit();
    worker.current_epoch = 10;

    var bench = try Bench.init(8, 8, 0xFF000000);
    defer bench.deinit();
    const source = bench.dev.compositeInputs().?;

    // Task from old epoch 9: dropped
    try queue.push(.{
        .kind = .keyframe,
        .position = .{ .branch = 0, .r = 1, .phase = .board, .o = 0, .gap = .retired },
        .virtual_ns = 1_000_000,
        .width = 8,
        .height = 8,
        .epoch = 9,
        .glcdc = bench.dev,
        .source = source,
        .powered = true,
        .layer_bytes = null,
        .bytes_cost = 0,
    });

    // Task from current epoch 10: processed
    try queue.push(.{
        .kind = .keyframe,
        .position = .{ .branch = 0, .r = 2, .phase = .board, .o = 0, .gap = .retired },
        .virtual_ns = 2_000_000,
        .width = 8,
        .height = 8,
        .epoch = 10,
        .glcdc = bench.dev,
        .source = source,
        .powered = true,
        .layer_bytes = null,
        .bytes_cost = 0,
    });

    _ = try worker.drain();
    try std.testing.expectEqual(@as(usize, 1), collector.records.items.len);
    try std.testing.expectEqual(@as(u64, 2), collector.records.items[0].header.position.r);
}

test "threaded worker drains tasks asynchronously" {
    const allocator = std.testing.allocator;
    var queue = frame_queue.Queue.init(allocator, 1024 * 1024);
    defer queue.deinit();

    var collector = SinkCollector.init(allocator);
    defer collector.deinit();

    var worker = compositor_worker.CompositorWorker.init(allocator, &queue, collector.sink());
    defer worker.deinit();

    try worker.start();

    var bench = try Bench.init(10, 10, 0xFF223344);
    defer bench.deinit();
    const source = bench.dev.compositeInputs().?;

    for (0..5) |i| {
        try queue.push(.{
            .kind = .keyframe,
            .position = .{ .branch = 0, .r = @intCast(i), .phase = .board, .o = 0, .gap = .retired },
            .virtual_ns = @intCast(i * 1_000_000),
            .width = 10,
            .height = 10,
            .epoch = 0,
            .glcdc = bench.dev,
            .source = source,
            .powered = true,
            .layer_bytes = null,
            .bytes_cost = 0,
        });
    }

    worker.stop();

    try std.testing.expectEqual(@as(usize, 5), collector.records.items.len);
}
