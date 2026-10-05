//! The `--save-state` / `--load-state` hook on a Zig run (RA8EMU-696): the
//! run file (src/snapshot/run.zig: board, CPU0's store, the core), the two
//! SysTick bases the run keeps beside the board (src/snapshot/systick.zig)
//! and what the run owed its clocks (src/snapshot/stretch.zig, RA8EMU-700).
//!
//! A run with `--cpu1` is refused: the second core lives in its own driver
//! and its state is not in the file yet.
const std = @import("std");
const boot = @import("../../core/cpu/boot.zig");
const Cpu = @import("../../core/cpu/cpu.zig").Cpu;
const Store = @import("../../core/cpu/memory/store.zig").Store;
const run_file = @import("../../snapshot/run.zig");
const systick = @import("../../snapshot/systick.zig");
const stretch = @import("../../snapshot/stretch.zig");
const Clock = @import("zig_run.zig").Clock;

/// The largest file a load reads.
const max_bytes = 1 << 30;

pub const Error = error{SecondCoreNotSaved};

/// The hook for `clock`'s run, or null when neither flag was given.
pub fn hook(clock: *Clock) ?boot.Snapshot {
    if (!clock.state.wanted()) return null;
    return .{
        .context = clock,
        .loadFn = if (clock.state.load != null) load else null,
        .saveFn = if (clock.state.save != null) save else null,
    };
}

fn load(context: *anyopaque, core: *Cpu) anyerror!u32 {
    const clock: *Clock = @ptrCast(@alignCast(context));
    const store = try storeOf(clock);
    const allocator = std.heap.page_allocator;
    const bytes = try std.fs.cwd().readFileAlloc(allocator, clock.state.load.?, max_bytes);
    defer allocator.free(bytes);
    try run_file.load(bytes, store, &.{core}, clock.board);
    try systick.load(.{ clock.timebase, &clock.ns_timebase }, bytes);
    return stretch.load(bytes);
}

fn save(context: *anyopaque, core: *const Cpu, owed: u32) anyerror!void {
    const clock: *Clock = @ptrCast(@alignCast(context));
    const store = try storeOf(clock);
    var out = try std.fs.cwd().createFile(clock.state.save.?, .{});
    defer out.close();
    var buffered = std.io.bufferedWriter(out.writer());
    try run_file.save(buffered.writer(), store, &.{core}, clock.board);
    try systick.save(.{ clock.timebase, &clock.ns_timebase }, buffered.writer());
    try stretch.save(owed, buffered.writer());
    try buffered.flush();
}

fn storeOf(clock: *const Clock) Error!*Store {
    if (clock.cpu1 != null) return Error.SecondCoreNotSaved;
    return switch (clock.memory) {
        .store => |store| store,
    };
}
