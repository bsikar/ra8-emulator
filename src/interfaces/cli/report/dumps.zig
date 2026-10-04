//! Everything a command-line flag asked to be printed once the run is over.
//!
//! These are the reader's own questions, not the board's account of itself:
//! a named global read out of RAM, one card block as hex. The core
//! registers go out through report/json_regs.zig. They come after the block reports and
//! they answer to a flag, so a run that passed none of those flags prints
//! nothing from this file at all.
//!
//! Its own file rather than four more functions in src/main.zig, which is
//! wiring: this is output, it is the only part of the output that a flag
//! rather than the board decides, and src/board is where the words about a
//! run live.
const std = @import("std");
const Guest = @import("../../../core/cpu/memory/guest.zig").Guest;
const elf = @import("../../../core/elf.zig");
const cli = @import("../cli.zig");
const symbols = @import("../../../debug/symbols.zig");
const sd_dump = @import("../../../periph/sd/sd_dump.zig");
const sd_image = @import("../../../periph/sd/sd_image.zig");

/// Read each `--dump-sym` global out of RAM and print it.
///
/// The shape of the line is load-bearing: the firmware's own
/// emulator-in-the-loop suite parses it with a regex over
/// "dump-sym : <name> @0x<addr> = <decimal> ", so the name, the address,
/// the decimal value and something after it all have to be there. A symbol
/// the image does not carry, or an address that will not read, says so
/// plainly instead of printing a number nothing measured.
pub fn dumpSymbols(out: anytype, core: Guest, image: elf.Image, options: cli.Options) !void {
    if (options.dumps().len == 0) return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var images: [2]elf.Image = .{ image, undefined };
    var count: usize = 1;
    if (try nonSecure(arena.allocator(), options)) |second| {
        images[1] = second;
        count = 2;
    }
    for (options.dumps()) |name| {
        const address = symbols.addressInAny(images[0..count], name) orelse {
            try out.print("  dump-sym      : {s} <unresolved>\n", .{name});
            continue;
        };
        const value = core.readWord(address) catch {
            try out.print("  dump-sym      : {s} @0x{X:0>8} <unreadable>\n", .{ name, address });
            continue;
        };
        try out.print(
            "  dump-sym      : {s} @0x{X:0>8} = {d} (0x{X:0>8})\n",
            .{ name, address, value, value },
        );
    }
}

/// The `--ns` image again, for its symbol table: a global the Non-Secure
/// side keeps (a heartbeat the bench reads by memprobe) is named only there.
/// The run already loaded its segments; this reads the file once more and
/// nothing else, so a run without `--ns` reads nothing.
pub fn nonSecure(allocator: std.mem.Allocator, options: cli.Options) !?elf.Image {
    const path = options.ns_path orelse return null;
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 64 << 20);
    return try elf.Image.init(bytes);
}

/// One card block back as hex, when `--dump-sd` asked for it.
///
/// Rows of nothing but zeros are dropped: a block of a freshly formatted
/// volume is mostly zeros, and the few rows carrying a directory entry or a
/// boot field are the whole reason to look. The count of dropped rows is
/// printed so a reader can tell an elided block from a short one.
pub fn dumpBlock(out: anytype, board: anytype, options: cli.Options) !void {
    const index = options.dump_sd orelse return;
    var block: sd_image.Block = undefined;
    if (!board.sd.img.read(index, &block)) {
        try out.print("  dump-sd       : block {d} is not on this card\n", .{index});
        return;
    }
    try out.print("  dump-sd       : block {d} (0x{X})\n", .{ index, index });
    var offset: usize = 0;
    var dropped: usize = 0;
    while (offset < block.len) : (offset += sd_dump.row_bytes) {
        const end = @min(offset + sd_dump.row_bytes, block.len);
        const bytes = block[offset..end];
        if (sd_dump.blank(bytes)) {
            dropped += 1;
            continue;
        }
        var buf: sd_dump.Buffer = undefined;
        try out.print("{s}\n", .{sd_dump.row(&buf, offset, bytes)});
    }
    if (dropped > 0) try out.print("  dump-sd       : {d} zero row(s) not shown\n", .{dropped});
}
