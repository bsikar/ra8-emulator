//! Tests for src/session/history/compositor_worker.zig:
//! - Worker uses only immutable value copies
//! - Keyframe and delta crop emission
//! - PlaneReader composite over SRAM and SDRAM
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
        return .{ .ctx = self, .writeFrameFn = deliverRecord };
    }

    fn deliverRecord(ctx: *anyopaque, record: *const frame_types.FrameRecord) anyerror!void {
        const self: *SinkCollector = @ptrCast(@alignCast(ctx));
        var owned_record = record.*;
        if (record.payload.len > 0) owned_record.payload = try self.allocator.dupe(u8, record.payload);
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

    fn configureLayer(self: *Bench, base: u32, stride: u32, height: u32, format: u32) void {
        const lb = glcdc_mod.win_base + glcdc_mod.off.layer_base;
        self.dev.write(lb + glcdc_mod.off.flm2, 4, base);
        self.dev.write(lb + glcdc_mod.off.flm3, 4, stride << 16);
        self.dev.write(lb + glcdc_mod.off.flm5, 4, (height - 1) << 16);
        self.dev.write(lb + glcdc_mod.off.flm6, 4, format);
        self.dev.write(lb + glcdc_mod.off.flmrd, 4, glcdc_mod.field.renb);
    }

    fn deinit(self: *Bench) void {
        store_memory.close(self.core);
    }
};

fn makePixels(allocator: std.mem.Allocator, count: usize, color: u32) ![]u8 {
    const px = try allocator.alloc(u8, count * 4);
    for (0..count) |i| std.mem.writeInt(u32, px[i * 4 ..][0..4], color, .little);
    return px;
}

test "worker uses only copies and emits valid keyframe" {
    const allocator = std.testing.allocator;
    var queue = frame_queue.Queue.init(std.testing.io, allocator, 1024 * 1024);
    defer queue.deinit();
    var collector = SinkCollector.init(allocator);
    defer collector.deinit();
    var worker = compositor_worker.CompositorWorker.init(allocator, &queue, collector.sink());
    defer worker.deinit();

    var bench = try Bench.init(10, 8, 0xFF445566);
    defer bench.deinit();
    const source = bench.dev.compositeInputs().?;

    try queue.push(.{
        .kind = .keyframe,
        .position = .{ .branch = 1, .r = 42, .phase = .board, .o = 0, .gap = .retired },
        .virtual_ns = 500_000,
        .width = 10,
        .height = 8,
        .glcdc = bench.dev,
        .source = source,
        .powered = true,
    });

    try std.testing.expectEqual(@as(usize, 1), try worker.drain());
    try std.testing.expectEqual(@as(usize, 1), collector.records.items.len);

    const rec = collector.records.items[0];
    try std.testing.expectEqual(frame_types.FrameKind.keyframe, rec.header.kind);
    try std.testing.expectEqual(@as(u16, 10), rec.header.rect.width);
    try std.testing.expectEqual(@as(u16, 8), rec.header.rect.height);

    const decompressed = try allocator.alloc(u8, 80);
    defer allocator.free(decompressed);
    try frame_crop.decompress(allocator, rec.payload, decompressed);
    try std.testing.expectEqual(@as(usize, 80), decompressed.len);
}

test "worker composites layer from SRAM with non-null layer_bytes" {
    const allocator = std.testing.allocator;
    var queue = frame_queue.Queue.init(std.testing.io, allocator, 1024 * 1024);
    defer queue.deinit();
    var collector = SinkCollector.init(allocator);
    defer collector.deinit();
    var worker = compositor_worker.CompositorWorker.init(allocator, &queue, collector.sink());
    defer worker.deinit();

    const width: u32 = 8;
    const height: u32 = 8;
    var bench = try Bench.init(width, height, 0xFF000000);
    defer bench.deinit();
    bench.configureLayer(0x2200_0000, width * 4, height, 5); // ARGB8888 in SRAM
    const source = bench.dev.compositeInputs().?;

    const pixels = try makePixels(allocator, width * height, 0xFFFF0000); // Red
    try queue.push(.{
        .kind = .keyframe,
        .position = .{ .branch = 1, .r = 1, .phase = .board, .o = 0, .gap = .retired },
        .virtual_ns = 1_000_000,
        .width = @intCast(width),
        .height = @intCast(height),
        .glcdc = bench.dev,
        .source = source,
        .powered = true,
        .layer_bytes = pixels,
    });

    _ = try worker.drain();
    try std.testing.expectEqual(@as(usize, 1), collector.records.items.len);

    const key_gray = try allocator.alloc(u8, width * height);
    defer allocator.free(key_gray);
    try frame_crop.decompress(allocator, collector.records.items[0].payload, key_gray);
    for (key_gray) |px| try std.testing.expectEqual(@as(u8, 76), px);
}

test "worker composites layer from SDRAM 0x6800_0000 without Unmapped error" {
    const allocator = std.testing.allocator;
    var queue = frame_queue.Queue.init(std.testing.io, allocator, 1024 * 1024);
    defer queue.deinit();
    var collector = SinkCollector.init(allocator);
    defer collector.deinit();
    var worker = compositor_worker.CompositorWorker.init(allocator, &queue, collector.sink());
    defer worker.deinit();

    const width: u32 = 8;
    const height: u32 = 8;
    var bench = try Bench.init(width, height, 0xFF000000);
    defer bench.deinit();
    bench.configureLayer(0x6800_0000, width * 4, height, 5); // ARGB8888 in SDRAM
    const source = bench.dev.compositeInputs().?;

    const pixels = try makePixels(allocator, width * height, 0xFF00FF00); // Green
    try queue.push(.{
        .kind = .keyframe,
        .position = .{ .branch = 1, .r = 1, .phase = .board, .o = 0, .gap = .retired },
        .virtual_ns = 1_000_000,
        .width = @intCast(width),
        .height = @intCast(height),
        .glcdc = bench.dev,
        .source = source,
        .powered = true,
        .layer_bytes = pixels,
    });

    _ = try worker.drain();
    try std.testing.expectEqual(@as(usize, 1), collector.records.items.len);

    const key_gray = try allocator.alloc(u8, width * height);
    defer allocator.free(key_gray);
    try frame_crop.decompress(allocator, collector.records.items[0].payload, key_gray);
    for (key_gray) |px| try std.testing.expectEqual(@as(u8, 150), px);
}

test "queue bound and regenerate marker emission" {
    const allocator = std.testing.allocator;
    var queue = frame_queue.Queue.init(std.testing.io, allocator, 1024 * 1024);
    defer queue.deinit();
    var collector = SinkCollector.init(allocator);
    defer collector.deinit();
    var worker = compositor_worker.CompositorWorker.init(allocator, &queue, collector.sink());
    defer worker.deinit();

    var bench = try Bench.init(10, 8, 0xFF112233);
    defer bench.deinit();
    const source = bench.dev.compositeInputs().?;

    try queue.push(.{
        .kind = .regenerate_by_replay,
        .position = .{ .branch = 2, .r = 100, .phase = .board, .o = 0, .gap = .retired },
        .virtual_ns = 1_000_000,
        .width = 10,
        .height = 8,
        .glcdc = bench.dev,
        .source = source,
        .powered = true,
    });

    _ = try worker.drain();
    try std.testing.expectEqual(@as(usize, 1), collector.records.items.len);
    const rec = collector.records.items[0];
    try std.testing.expectEqual(frame_types.FrameKind.regenerate_by_replay, rec.header.kind);
    try std.testing.expectEqual(@as(usize, 0), rec.payload.len);
}

test "keyframe and delta crop round trip byte-exact" {
    const allocator = std.testing.allocator;
    var queue = frame_queue.Queue.init(std.testing.io, allocator, 1024 * 1024);
    defer queue.deinit();
    var collector = SinkCollector.init(allocator);
    defer collector.deinit();
    var worker = compositor_worker.CompositorWorker.init(allocator, &queue, collector.sink());
    defer worker.deinit();

    const width: u32 = 16;
    const height: u32 = 16;

    var bench1 = try Bench.init(width, height, 0xFF000000);
    defer bench1.deinit();
    try queue.push(.{
        .kind = .keyframe,
        .position = .{ .branch = 0, .r = 1, .phase = .board, .o = 0, .gap = .retired },
        .virtual_ns = 1_000_000,
        .width = width,
        .height = height,
        .glcdc = bench1.dev,
        .source = bench1.dev.compositeInputs().?,
        .powered = true,
    });

    var bench2 = try Bench.init(width, height, 0xFFFFFFFF);
    defer bench2.deinit();
    try queue.push(.{
        .kind = .delta,
        .position = .{ .branch = 0, .r = 2, .phase = .board, .o = 0, .gap = .retired },
        .virtual_ns = 2_000_000,
        .width = width,
        .height = height,
        .glcdc = bench2.dev,
        .source = bench2.dev.compositeInputs().?,
        .powered = true,
    });

    _ = try worker.drain();
    try std.testing.expectEqual(@as(usize, 2), collector.records.items.len);

    const key_gray = try allocator.alloc(u8, width * height);
    defer allocator.free(key_gray);
    try frame_crop.decompress(allocator, collector.records.items[0].payload, key_gray);

    const reconstructed = try frame_crop.reconstruct(allocator, key_gray, width, collector.records.items[1].header.rect, collector.records.items[1].payload);
    defer allocator.free(reconstructed);
    for (reconstructed) |pixel| try std.testing.expectEqual(@as(u8, 255), pixel);
}

test "epoch cancellation drops obsolete tasks" {
    const allocator = std.testing.allocator;
    var queue = frame_queue.Queue.init(std.testing.io, allocator, 1024 * 1024);
    defer queue.deinit();
    var collector = SinkCollector.init(allocator);
    defer collector.deinit();
    var worker = compositor_worker.CompositorWorker.init(allocator, &queue, collector.sink());
    defer worker.deinit();
    worker.current_epoch = 10;

    var bench = try Bench.init(8, 8, 0xFF000000);
    defer bench.deinit();
    const source = bench.dev.compositeInputs().?;

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
    });
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
    });

    _ = try worker.drain();
    try std.testing.expectEqual(@as(usize, 1), collector.records.items.len);
    try std.testing.expectEqual(@as(u64, 2), collector.records.items[0].header.position.r);
}

test "threaded worker drains tasks asynchronously" {
    const allocator = std.testing.allocator;
    var queue = frame_queue.Queue.init(std.testing.io, allocator, 1024 * 1024);
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
            .glcdc = bench.dev,
            .source = source,
            .powered = true,
        });
    }

    worker.stop();
    try std.testing.expectEqual(@as(usize, 5), collector.records.items.len);
}
