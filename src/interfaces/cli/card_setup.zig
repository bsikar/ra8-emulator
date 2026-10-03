//! Fit the CLI's SD card options onto the board's card.
const std = @import("std");
const Board = @import("../../board/board.zig").Board;
const sd_format = @import("../../periph/sd/sd_format.zig");
const sd_advice = @import("../../periph/sd/sd_format_advice.zig");
const sd_image = @import("../../periph/sd/sd_image.zig");

/// Size and format the card, or import a raw host image when requested.
pub fn prepare(
    board: *Board,
    trace_sd: bool,
    sd_path: ?[]const u8,
    sd_size_mb: ?u32,
    sd_new: ?sd_format.Kind,
    sd_label: []const u8,
) !void {
    board.sd.trace = trace_sd;
    if (sd_path) |path| {
        if (sd_new != null or sd_size_mb != null) return error.ConflictingCardOptions;
        const bytes = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, std.math.maxInt(usize)) catch |err| {
            std.debug.print("cannot read SD image {s}: {s}\n", .{ path, @errorName(err) });
            return err;
        };
        defer std.heap.page_allocator.free(bytes);
        board.sd.img.loadBytes(bytes) catch |err| {
            std.debug.print("SD image {s}: {s}\n", .{ path, @errorName(err) });
            return err;
        };
        return;
    }
    if (sd_size_mb) |megabytes| {
        const blocks = megabytes *| (1024 * 1024 / sd_image.geometry.block_bytes);
        if (!board.sd.img.resize(blocks)) {
            std.debug.print("--sd-size {d}: not a card size this model can state exactly\n", .{megabytes});
            return error.BadCardSize;
        }
    }
    const kind = sd_new orelse return;
    board.sd_volume = sd_format.apply(&board.sd.img, kind, sd_label) catch |err| {
        std.debug.print("--sd-new {s}: {s}\n", .{ kind.text(), @errorName(err) });
        sd_advice.printRemedy(kind, err);
        return err;
    };
}
