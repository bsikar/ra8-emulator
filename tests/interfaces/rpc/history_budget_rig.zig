//! Qualification rig for RA8EMU-1234 Item 3 (F02 / F13): RAM budget tiers,
//! per-workload storage growth breakdown, and ephemeral residue verification.
const std = @import("std");
const ra8 = @import("ra8");
const metrics_rig = @import("history_metrics_rig.zig");

const setup = ra8.rpc.served_setup;
const history = ra8.host.history;

pub const RamTierReport = struct {
    tier_mib: u64,
    baseline_rss_bytes: u64,
    process_rss_bytes: u64,
    held_history_bytes: u64,
    partition_total_bytes: u64,
};

pub const StorageBreakdown = struct {
    name: []const u8,
    rounds: u64,
    virtual_ns: u64,
    log_bytes: u64,
    pack_bytes: u64,
    loose_bytes: u64,
    frame_bytes: u64,
    other_bytes: u64,
    ephemeral_left_bytes: u64,

    pub fn total(self: StorageBreakdown) u64 {
        return self.log_bytes + self.pack_bytes + self.loose_bytes + self.frame_bytes + self.other_bytes;
    }
};

fn sampleProcessRss() u64 {
    var sampler: ra8.host.metrics.Sampler = .{};
    sampler.refresh(ra8.host.metrics.interval_ns + 1);
    return if (sampler.current) |cur| cur.rss else 0;
}

pub fn measureRamTier(_: std.mem.Allocator, io: std.Io, tier_mib: u64, rounds: u64) !RamTierReport {
    const alloc = std.heap.c_allocator;
    const cap = tier_mib * metrics_rig.mib;
    const shares = try history.budget.partition(cap);
    var base_served: setup.Served = undefined;
    try base_served.open(alloc, io, metrics_rig.compute_image, null, null);
    const baseline_rss = sampleProcessRss();
    base_served.deinit();

    var served: setup.Served = undefined;
    try served.open(alloc, io, metrics_rig.ui_image, null, .{ .ram_budget = cap, .checkpoint_every = 64 });
    defer served.deinit();
    const session = served.owner.session();
    try session.setRunBudget(.cpu0, 16_000);
    var first = true;
    while (session.currentPosition().r < rounds) {
        _ = try session.run(.cpu0, if (first) .run else .cont);
        first = false;
    }
    try served.flushHistory();
    const step_ticket = try served.owner.transport().command(.{ .step = .{ .core = .cpu0, .count = 1, .dir = .back } });
    try metrics_rig.driveTicket(io, served.owner.transport(), step_ticket);

    const win_bytes: u64 = if (session.window) |w| w.heldBytes() else 0;
    const frame_bytes: u64 = if (served.frameCache()) |fc| fc.ram_used else 0;
    const ram_hist_bytes: u64 = if (served.ram_history) |rh| rh.used() else 0;
    return .{
        .tier_mib = tier_mib,
        .baseline_rss_bytes = baseline_rss,
        .process_rss_bytes = sampleProcessRss(),
        .held_history_bytes = win_bytes + frame_bytes + ram_hist_bytes,
        .partition_total_bytes = shares.total(),
    };
}

pub fn measureWorkloadStorage(
    gpa: std.mem.Allocator,
    io: std.Io,
    label: []const u8,
    elf_path: []const u8,
    second: ?[]const u8,
    rounds: u64,
) !StorageBreakdown {
    var temp = try metrics_rig.TempRoot.open(gpa, io, 0x301);
    defer temp.close(gpa, io);
    const root = temp.path;

    var breakdown: StorageBreakdown = .{
        .name = label,
        .rounds = 0,
        .virtual_ns = 0,
        .log_bytes = 0,
        .pack_bytes = 0,
        .loose_bytes = 0,
        .frame_bytes = 0,
        .other_bytes = 0,
        .ephemeral_left_bytes = 0,
    };
    {
        const is_display = std.mem.eql(u8, label, "display");
        var served: setup.Served = undefined;
        try served.openInitial(
            gpa,
            io,
            elf_path,
            null,
            .{ .root = root, .checkpoint_every = 64, .frame_hz = if (is_display) @as(?u32, 0) else null },
            if (second) |b| .{ .bytes = b } else null,
        );
        defer served.deinit();
        const session = served.owner.session();
        const board = served.owner.board();
        if (is_display) metrics_rig.showColor(board, 0xFF20_4060);
        try session.setRunBudget(.cpu0, if (is_display) 16_000 else 32_000);
        var first = true;
        var steps: usize = 0;
        while (session.currentPosition().r < rounds and steps < 512) : (steps += 1) {
            if (is_display and session.currentPosition().r == rounds / 2) {
                const glcdc = ra8.chip.periph.glcdc;
                board.display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, 0xFFAA_BBCC);
            }
            const ended = try session.run(.cpu0, if (first) .run else .cont);
            first = false;
            if (!is_display and ended != .count) break;
        }
        try served.flushHistory();
        if (is_display) {
            var tries: usize = 0;
            while (served.frameCache().?.count() < 1 and tries < 500) : (tries += 1) try io.sleep(.fromMilliseconds(1), .awake);
        }
        breakdown.rounds = session.currentPosition().r;
        breakdown.virtual_ns = session.now() catch 0;
        try tallySessionDir(gpa, io, served.history.?.session.dir, &breakdown);
        if (served.frameCache()) |fc| breakdown.frame_bytes += fc.ramBytes() + fc.diskBytes();
    }
    breakdown.ephemeral_left_bytes = try tallyEphemeralLeft(gpa, io, root);
    return breakdown;
}

fn tallySessionDir(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, out: *StorageBreakdown) !void {
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const stat = try dir.statFile(io, entry.path, .{});
        const sz: u64 = @intCast(stat.size);
        if (std.mem.startsWith(u8, entry.path, "log")) {
            out.log_bytes += sz;
        } else if (std.mem.startsWith(u8, entry.path, "frames")) {
            out.frame_bytes += sz;
        } else if (std.mem.startsWith(u8, entry.path, "objects")) {
            if (std.mem.endsWith(u8, entry.path, ".pack") or std.mem.endsWith(u8, entry.path, ".idx"))
                out.pack_bytes += sz
            else
                out.loose_bytes += sz;
        } else {
            out.other_bytes += sz;
        }
    }
}

fn tallyEphemeralLeft(gpa: std.mem.Allocator, io: std.Io, root: []const u8) !u64 {
    var base = try history.base.Base.existing(gpa, io, root, .cache);
    defer base.close();
    var it = try history.catalog.Iterator.init(&base);
    var total: u64 = 0;
    while (try it.next()) |entry| {
        if (entry.kind == .session) total += 1;
    }
    return total;
}
