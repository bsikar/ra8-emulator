//! The RA8EMU-227 stress check: does a UI reading board snapshots at
//! 240 Hz slow the emulator down? A writer does a fixed amount of work per
//! frame and publishes a panel-sized snapshot through board_snapshot's
//! Handoff, timed once with no reader and once with a reader thread taking
//! latest() at `reader_hz` and touching every pixel. Each side keeps its
//! best of `trials` runs, and the step fails when the loaded writer is
//! more than `limit_percent` slower. Build it with -Doptimize=ReleaseFast:
//! a Debug copy loop says nothing about the real run.
const std = @import("std");
const ra8 = @import("ra8");
const snapshot = ra8.gui.board_snapshot;

pub const Config = struct {
    frames: u32 = 2_000,
    work_per_frame: u32 = 200_000,
    width: u32 = 480,
    height: u32 = 272,
    reader_hz: u32 = 240,
    trials: u32 = 5,
    limit_percent: f64 = 2.0,
};

pub const Run = struct { elapsed_ns: u64, publishes: u32, reads: u32, checksum: u64 };

const Reader = struct {
    io: std.Io,
    handoff: *snapshot.Handoff,
    period_ns: u64,
    done: std.atomic.Value(bool) = .init(false),
    reads: u32 = 0,
    sum: u64 = 0,

    fn loop(self: *Reader) std.Io.Cancelable!void {
        while (!self.done.load(.acquire)) {
            if (self.handoff.latest()) |board| {
                self.reads += 1;
                for (board.panel) |pixel| self.sum +%= pixel;
            }
            try self.io.sleep(.fromNanoseconds(self.period_ns), .awake);
        }
    }
};

/// Stands in for an emulated frame: `work` rounds of a xorshift whose
/// result paints the panel, so nothing can be folded away.
fn emulate(state: *u64, panel: []u32, work: u32) void {
    var x = state.*;
    for (0..work) |_| {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
    }
    for (panel, 0..) |*pixel, i| pixel.* = @truncate(x +% i);
    state.* = x;
}

/// One timed writer run, with a reader when `reader` is set.
pub fn once(allocator: std.mem.Allocator, io: std.Io, config: Config, reader: bool) !Run {
    var handoff = snapshot.Handoff.init(allocator);
    defer handoff.deinit();
    const panel = try allocator.alloc(u32, @as(usize, config.width) * config.height);
    defer allocator.free(panel);
    var watcher = Reader{ .io = io, .handoff = &handoff, .period_ns = std.time.ns_per_s / @max(config.reader_hz, 1) };
    const thread = if (reader) try std.Thread.spawn(.{}, Reader.loop, .{&watcher}) else null;
    var state: u64 = 0x9E3779B97F4A7C15;
    const start = std.Io.Timestamp.now(io, .awake);
    for (0..config.frames) |_| {
        emulate(&state, panel, config.work_per_frame);
        _ = try handoff.publish(.{ .panel = panel, .width = config.width, .height = config.height, .leds = &.{} });
    }
    const elapsed: u64 = @intCast(start.untilNow(io, .awake).toNanoseconds());
    watcher.done.store(true, .release);
    if (thread) |t| t.join();
    return .{ .elapsed_ns = elapsed, .publishes = config.frames, .reads = watcher.reads, .checksum = state +% watcher.sum };
}

/// The best of `trials` runs: the least the box's noise added.
pub fn best(allocator: std.mem.Allocator, io: std.Io, config: Config, reader: bool) !Run {
    var fastest = try once(allocator, io, config, reader);
    for (1..config.trials) |_| {
        const next = try once(allocator, io, config, reader);
        if (next.elapsed_ns < fastest.elapsed_ns) fastest = next;
    }
    return fastest;
}

/// How much slower `loaded` ran than `base`, in percent; negative when faster.
pub fn slowdown(base: Run, loaded: Run) f64 {
    const b: f64 = @floatFromInt(@max(base.elapsed_ns, 1));
    const l: f64 = @floatFromInt(loaded.elapsed_ns);
    return (l - b) / b * 100.0;
}

pub fn main(init: std.process.Init) !u8 {
    const config = Config{};
    const base = try best(init.gpa, init.io, config, false);
    const loaded = try best(init.gpa, init.io, config, true);
    const percent = slowdown(base, loaded);
    const bytes = @as(usize, config.width) * config.height * @sizeOf(u32);
    std.debug.print("handoff: {d} frames of {d} bytes; no reader {d} ms, {d} Hz reader {d} ms ({d} reads), slowdown {d:.2}% (limit {d:.1}%)\n", .{
        config.frames,    bytes,                                  base.elapsed_ns / std.time.ns_per_ms,
        config.reader_hz, loaded.elapsed_ns / std.time.ns_per_ms, loaded.reads,
        percent,          config.limit_percent,
    });
    return if (percent <= config.limit_percent) 0 else 1;
}
