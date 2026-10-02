//! How a stop is placed in the program: an address with its symbol, the
//! instruction there, and the call chain above it (RA8EMU-114).
//!
//! These read the core only through core_view, so the Unicorn session
//! (src/debug/session.zig) and the Zig-core one print the same lines for
//! the same stop.
const elf = @import("../core/elf.zig");
const core_view = @import("core_view.zig");
const dwarf_line = @import("dwarf_line.zig");
const session_source = @import("session_source.zig");
const session_view = @import("session_view.zig");
const symbols = @import("symbols.zig");
const unwind = @import("unwind.zig");

/// An address as eight hex digits, with `<symbol+offset>` when the image
/// has a function covering it.
pub fn where(image: ?elf.Image, address: u32, out: anytype) !void {
    try out.print("0x{X:0>8}", .{address});
    const found = symbols.inside(image orelse return, address) orelse return;
    if (found.offset == 0) return out.print(" <{s}>", .{found.name});
    try out.print(" <{s}+{d}>", .{ found.name, found.offset });
}

/// An address, its symbol, and the instruction there.
pub fn line(view: core_view.View, image: ?elf.Image, address: u32, out: anytype) !void {
    try where(image, address, out);
    try out.print(": ", .{});
    _ = try session_view.instruction(out, view, address);
    try out.print("\n", .{});
}

/// The call chain, walked with the image's .debug_frame, each frame with
/// its source line when the image has one. Without CFI for the stop it is
/// the pc and lr.
pub fn backtrace(view: core_view.View, image: ?elf.Image, out: anytype) !void {
    var frames: [unwind.limits.frames]unwind.Frame = undefined;
    const frame = if (image) |found| dwarf_line.section(found, ".debug_frame") else &.{};
    const psp = try view.register(.psp);
    var count = unwind.walk(frame, try unwind.registersOf(view), psp, view, &frames);
    if (count < 2) {
        frames[1] = .{ .pc = try view.register(.lr) & ~@as(u32, 1) };
        count = 2;
    }
    const sections = session_source.of(image);
    var number: usize = 0;
    for (frames[0..count], 0..) |found, index| {
        // An exception sits between a handler and what it interrupted;
        // gdb shows it as a frame of its own, so the numbers match.
        if (index > 0 and found.exact) {
            try out.print("#{d} <signal handler called>\n", .{number});
            number += 1;
        }
        try out.print("#{d} ", .{number});
        number += 1;
        try where(image, found.pc, out);
        try session_source.at(out, sections, if (found.exact) found.pc else found.pc -% 1);
        try out.print("\n", .{});
    }
}
