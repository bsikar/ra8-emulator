//! The counter `--stop-sym NAME N` names, for a Zig run (RA8EMU-603).
//!
//! Resolved against the image's symbol table the way the Unicorn path in
//! src/main.zig resolves it, so both runs stop on the same word. The
//! counter is read at each boundary by zig_run.Clock.done.
const std = @import("std");
const elf = @import("../../core/elf.zig");
const symbols = @import("../../debug/symbols.zig");
const Stop = @import("../../core/stop.zig").Stop;
const cli = @import("cli.zig");

/// The watched counter, or null. A name the image does not carry is
/// reported and the run goes to its instruction budget instead: a missing
/// symbol is the suite's verdict to make, not a reason to refuse the run.
pub fn resolve(image: elf.Image, options: cli.Options) ?Stop {
    const name = options.stop_symbol orelse return null;
    const address = symbols.addressOf(image, name) orelse {
        std.debug.print("--stop-sym {s} not found in symbol table\n", .{name});
        return null;
    };
    return .{ .address = address, .reaches = options.stop_at };
}
