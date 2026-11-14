//! Disassembly annotation: the names a firmware image puts on its addresses.
//!
//! The core's spellers print what the instruction encoding says: "b #0x8000100"
//! is exact and says nothing about who owns 0x8000100. The image does: its
//! symbol table carries the names, and this turns the immediates a line
//! already prints into names, appended after the text a reader can still
//! see. A branch into the middle of a function, a load from a named global,
//! both come back named; an address the table does not carry leaves the line
//! alone (RA8EMU-1247).
//!
//! The lookup is the same search-not-an-index walk the symbol reader uses:
//! an image carries a few thousand symbols, a disassembly pane asks for one
//! per line, and nothing here needs an allocator. Every name is a slice into
//! the image's own bytes, valid as long as the image is.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const text = @import("ra8_chip").core.cpu.text.text;
const symbols = @import("symbols.zig");
const dwarf = @import("dwarf/dwarf.zig");

/// The name the image puts on `address`, or null when none matches. An
/// exact symbol wins whichever kind it is: a branch target needs a
/// function, a load target needs a global, and the table already knows
/// which is which.
pub fn symbolAt(image: elf.Image, address: u32) ?[]const u8 {
    var walk = symbols.Walk.init(image);
    while (walk.next()) |named| {
        if (named.value == address) return named.name;
    }
    return null;
}

/// Append the name of the address `into` already prints, if the image
/// carries one.
///
/// The candidate is the last "#0x" immediate in the text, read as
/// hexadecimal to the end of the digits: a branch prints its target there,
/// and so does a load from an absolute address. A line with no such
/// immediate, or an immediate the table does not name, is returned
/// untouched, so an unannotated line and a failed lookup look the same.
pub fn line(image: elf.Image, into: *text.Text) void {
    const slice = into.slice();
    const mark = std.mem.lastIndexOf(u8, slice, "#0x") orelse return;
    const digits = mark + "#0x".len;
    var end: usize = digits;
    while (end < slice.len and std.ascii.isHex(slice[end])) : (end += 1) {}
    if (end == digits or end - digits > 8) return;
    const address = std.fmt.parseInt(u32, slice[digits..end], 16) catch return;
    if (symbolAt(image, address)) |name| {
        into.put(" ; {s}", .{name});
        return;
    }
    // No exact symbol: a covering function symbol still names the address,
    // relatively. Zero-sized symbols never reach here, so the offset is
    // always real.
    if (symbols.inside(image, address)) |site| {
        into.put(" ; {s}+0x{x}", .{ site.name, site.offset });
        return;
    }
    // No symbol names it: a local with fixed storage still can. A
    // DW_OP_addr location is absolute, so the walk matches it directly;
    // an image without debug sections answers null at once.
    if (dwarf.locals.atAddress(dwarf.locals.ofImage(image), address) catch null) |name| {
        into.put(" ; {s}", .{name});
    }
}
