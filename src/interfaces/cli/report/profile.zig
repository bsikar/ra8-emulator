//! Sorted per-function instruction and cycle counts.
const std = @import("std");
const elf = @import("../../../core/elf.zig");
const profile = @import("../../../debug/profile.zig");
const symbols = @import("../../../debug/symbols.zig");
const Writer = @import("../report.zig").Writer;

pub fn write(out: Writer, io: std.Io, image: elf.Image, table: profile.Table, path: ?[]const u8) !void {
    try print(out, image, table);
    if (path) |destination| {
        const file = try std.Io.Dir.cwd().createFile(io, destination, .{});
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try folded(&writer.interface, image, table);
        try writer.interface.flush();
    }
}

pub fn print(out: Writer, image: elf.Image, table: profile.Table) !void {
    var rows: [profile.limits.functions]profile.Site = undefined;
    const ranked = table.ranked(&rows);
    const shown = @min(ranked.len, profile.limits.listed);
    for (ranked[0..shown]) |site| {
        const found = symbols.inside(image, site.address) orelse continue;
        try out.print("profile: {s} {d} cycle(s), {d} instruction(s)\n", .{ found.name, site.cycles, site.instructions });
    }
    if (table.missed != 0) try out.print("profile: {d} instruction(s) outside sized functions or beyond table capacity\n", .{table.missed});
}

/// Folded format accepts a single frame when the emulator has no call stack
/// source; consumers can still compare where total execution accumulated.
pub fn folded(out: anytype, image: elf.Image, table: profile.Table) !void {
    var rows: [profile.limits.functions]profile.Site = undefined;
    for (table.ranked(&rows)) |site| {
        const found = symbols.inside(image, site.address) orelse continue;
        try out.print("{s} {d}\n", .{ found.name, site.cycles });
    }
}
