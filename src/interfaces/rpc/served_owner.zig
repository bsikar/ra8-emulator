//! Construct the machine over the already selected host history and startup images.
const std = @import("std");

const harness = @import("ra8_session").harness;
const history_bind = @import("history_bind.zig");
const history_budget = @import("ra8_host").history.budget;
const history_ram = @import("history_ram.zig");
const history_resources = @import("ra8_host").history.resources;
const host = @import("ra8_host");
const served_initial = @import("served_initial.zig");
const session = @import("ra8_session");
const setup = @import("served_setup.zig");

pub fn open(
    allocator: std.mem.Allocator,
    io: std.Io,
    elf_path: []const u8,
    initial: *served_initial.Images,
    profile: ?[]const u8,
    bind: ?*history_bind.Bind,
    ram: ?*history_ram.RamHistory,
    history_opts: ?setup.HistoryOpts,
) !harness.Harness {
    return harness.open(allocator, io, .{
        .elf_path = elf_path,
        .elf_bytes = initial.firstBytes(),
        .board_profile = profile,
        .history_storage = if (bind) |b| b.storage else if (ram) |r| r.storage else null,
        .history_objects = if (bind) |b| b.objects else if (ram) |r| r.object_space else null,
        .history_disk = if (bind) |b| b.disk else if (ram) |r| r.budget else null,
        .history_checkpoint_cap = if (bind) |b| b.checkpoint_cap else 0,
        .checkpoint_every = if (history_opts) |opts| opts.checkpoint_every else 64,
        .files = host.session_files.cwd(session.file_ops.Ops),
    });
}

/// The reverse window's byte budget: the window share of the RAM budget, the
/// 128 MiB floor's share when the host's RAM cannot be measured.
pub fn windowBytes(opts: setup.HistoryOpts) !usize {
    const ram = history_resources.ramBudget(opts.ram_budget) catch |err| switch (err) {
        error.MeasurementUnavailable => history_budget.bytes.floor,
        else => return err,
    };
    return @intCast((try history_budget.partition(ram)).window);
}
