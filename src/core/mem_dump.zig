//! Read words out of the machine's memory at a place the command line named.
//!
//! `--dump-sym` answers "what is in this global", which is enough when the
//! thing worth reading is a global. It is not enough for the geometry a
//! filesystem computes its sector numbers from: that sits inside a struct
//! the firmware reached through a pointer, at an address that changes run
//! to run. A place (see `place.zig`) says how to get there, and this file
//! goes and reads it.
//!
//! Nothing that fails here is silent. A name the image does not carry, a
//! pointer that will not load, and a word that will not read each say so,
//! because a zero printed in their place would read like a real value and
//! this exists to settle exactly the questions a wrong value confuses.
const std = @import("std");
const elf = @import("elf.zig");
const engine = @import("engine.zig");
const place = @import("place.zig");
const symbols = @import("symbols.zig");

/// Print the dump, or nothing at all when no place was asked for.
pub fn print(
    out: anytype,
    core: engine.Engine,
    image: elf.Image,
    spec: ?[]const u8,
    asked: ?u32,
) !void {
    const named = spec orelse return;
    const at = resolve(core, image, named) catch |err| {
        try out.print("  dump-mem      : {s} <{s}>\n", .{ named, @errorName(err) });
        return;
    };
    const total = place.words(asked);
    try out.print("  dump-mem      : {s} @0x{X:0>8}\n", .{ named, at });
    for (0..total) |step| {
        const index: u32 = @intCast(step);
        if (place.startsLine(index)) try out.print("                  +0x{X:0>4}", .{index * 4});
        if (core.readWord(at +% index * 4)) |value| {
            try out.print(" 0x{X:0>8}", .{value});
        } else |_| {
            try out.print(" <unreadable>", .{});
        }
        if (place.endsLine(index, total)) try out.print("\n", .{});
    }
}

/// The address a place resolves to: its symbol or its literal, then one
/// optional dereference, then its offset. The order matters: the offset is
/// into the struct the pointer found, not into the pointer.
pub fn resolve(core: engine.Engine, image: elf.Image, spec: []const u8) !u32 {
    const want = try place.parse(spec);
    var base = want.address;
    if (want.name) |name| base = symbols.addressOf(image, name) orelse return error.Unresolved;
    if (want.deref) base = try core.readWord(base);
    return want.apply(base);
}
