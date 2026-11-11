//! Qualification tests for RA8EMU-1234 Item 3 (F02 / F13): RAM budget tiers,
//! recording overhead, reverse-window and seek latencies, storage growth, and
//! zero-residue ephemeral cleanup.
const std = @import("std");
const builtin = @import("builtin");
const rig = @import("history_metrics_rig.zig");
const budget_rig = @import("history_budget_rig.zig");

const is_fast = builtin.mode == .fast;
const ns_per_ms: u64 = 1_000_000;
const ns_per_s: u64 = 1_000_000_000;

test "RAM budget tiers 1024 512 256 and 128 MiB stay within budget plus 50 MiB with baseline reported separately" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tiers = [_]u64{ 1024, 512, 256, 128 };
    const rounds: u64 = if (is_fast) 65 else 1;
    for (tiers) |tier_mib| {
        const rep = try budget_rig.measureRamTier(gpa, io, tier_mib, rounds);
        try std.testing.expect(rep.partition_total_bytes <= tier_mib * rig.mib);
        try std.testing.expect(rep.held_history_bytes <= tier_mib * rig.mib);
        if (is_fast) {
            std.debug.print(
                "[metric] ram_budget tier_mib={d} baseline_rss_mib={d:.2} process_rss_mib={d:.2} held_mib={d:.2} cap_plus_50_mib={d}\n",
                .{
                    rep.tier_mib,
                    @as(f64, @floatFromInt(rep.baseline_rss_bytes)) / @as(f64, @floatFromInt(rig.mib)),
                    @as(f64, @floatFromInt(rep.process_rss_bytes)) / @as(f64, @floatFromInt(rig.mib)),
                    @as(f64, @floatFromInt(rep.held_history_bytes)) / @as(f64, @floatFromInt(rig.mib)),
                    rep.tier_mib + 50,
                },
            );
            try std.testing.expect(rep.process_rss_bytes <= (tier_mib + 50) * rig.mib);
        }
    }
}

test "recording overhead stays at or below 10 percent with exact machine output and frame parity" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const rounds: u64 = if (is_fast) 320 else 64;
    const budget: u64 = if (is_fast) 128_000 else 32_000;
    const pairs: usize = if (is_fast) 3 else 1;

    const res = try rig.measureOverhead(gpa, io, rounds, budget, pairs);
    try std.testing.expect(res.rounds >= rounds);
    try std.testing.expect(res.checkpoints >= 2);
    if (is_fast) {
        std.debug.print(
            "[metric] overhead_summary pairs={d} rounds={d} cps={d} median_off_ms={d:.3} median_on_ms={d:.3} disk_pct={d:.2} ram_pct={d:.2}\n",
            .{
                res.pairs,
                res.rounds,
                res.checkpoints,
                @as(f64, @floatFromInt(res.median_off_ns)) / 1e6,
                @as(f64, @floatFromInt(res.median_on_ns)) / 1e6,
                res.median_pct,
                res.ram_pct,
            },
        );
        try std.testing.expect(res.median_pct <= 10.0);
        try std.testing.expect(res.ram_pct <= 10.0);
    }
}

test "reverse window undo nearby seek hot checkpoint stage2 seek first reverse frame and pause meet latency budgets" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const lat = try rig.measureLatencies(gpa, io, is_fast);
    if (is_fast) {
        std.debug.print(
            "[metric] latencies undo_ms={d:.3} nearby_seek_ms={d:.3} hot_cp_ms={d:.3} stage2_seek_ms={d:.3} first_rev_frame_ms={d:.3} pause_ms={d:.3}\n",
            .{
                @as(f64, @floatFromInt(lat.window_undo_ns)) / 1e6,
                @as(f64, @floatFromInt(lat.nearby_seek_ns)) / 1e6,
                @as(f64, @floatFromInt(lat.hot_checkpoint_ns)) / 1e6,
                @as(f64, @floatFromInt(lat.stage2_seek_ns)) / 1e6,
                @as(f64, @floatFromInt(lat.first_reverse_frame_ns)) / 1e6,
                @as(f64, @floatFromInt(lat.pause_ns)) / 1e6,
            },
        );
        try std.testing.expect(lat.window_undo_ns < 5 * ns_per_ms);
        try std.testing.expect(lat.nearby_seek_ns < 5 * ns_per_ms);
        try std.testing.expect(lat.hot_checkpoint_ns < 50 * ns_per_ms);
        try std.testing.expect(lat.stage2_seek_ns < 1 * ns_per_s);
        try std.testing.expect(lat.first_reverse_frame_ns < 250 * ns_per_ms);
        try std.testing.expect(lat.pause_ns <= 150 * ns_per_ms);
    }
}

test "storage growth breakdown across compute poll MVE display and dual IPC leaves zero ephemeral sessions after close" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Case = struct {
        label: []const u8,
        elf: []const u8,
        second: ?[]const u8 = null,
    };
    const cases = [_]Case{
        .{ .label = "compute", .elf = rig.compute_image },
        .{ .label = "poll", .elf = rig.poll_image },
        .{ .label = "mve", .elf = rig.mve_image },
        .{ .label = "display", .elf = rig.ui_image },
        .{ .label = "dual_ipc", .elf = rig.dual_image, .second = rig.dual_second },
    };
    const rounds: u64 = if (is_fast) 128 else 16;
    for (cases) |c| {
        const bd = try budget_rig.measureWorkloadStorage(gpa, io, c.label, c.elf, c.second, rounds);
        try std.testing.expect(bd.total() > 0);
        try std.testing.expect(bd.log_bytes > 0);
        if (std.mem.eql(u8, c.label, "display")) try std.testing.expect(bd.frame_bytes > 0);
        try std.testing.expectEqual(@as(u64, 0), bd.ephemeral_left_bytes);
        if (is_fast) {
            const per_round = @as(f64, @floatFromInt(bd.total())) / @as(f64, @floatFromInt(@max(bd.rounds, 1)));
            const mib_per_vs = if (bd.virtual_ns > 0)
                (@as(f64, @floatFromInt(bd.total())) / @as(f64, @floatFromInt(rig.mib))) / (@as(f64, @floatFromInt(bd.virtual_ns)) / 1e9)
            else
                0.0;
            std.debug.print(
                "[metric] storage workload={s} rounds={d} total_kb={d:.1} log_b={d} pack_b={d} loose_b={d} frame_b={d} b_per_round={d:.1} mib_per_vs={d:.2} ephemeral_left={d}\n",
                .{
                    bd.name,
                    bd.rounds,
                    @as(f64, @floatFromInt(bd.total())) / 1024.0,
                    bd.log_bytes,
                    bd.pack_bytes,
                    bd.loose_bytes,
                    bd.frame_bytes,
                    per_round,
                    mib_per_vs,
                    bd.ephemeral_left_bytes,
                },
            );
        }
    }
}
