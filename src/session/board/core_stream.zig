//! The core sections alone, as they sit in a full save stream (section 2.5):
//! what a reverse window saves for a slot that touched no board state.
const std = @import("std");
const run_file = @import("ra8_board").snapshot.run;
const state = @import("state.zig");

/// Writes the cores' sections, the clock and grid sections, the second
/// core's, the debug units and the runtime section, in the order and with
/// the bytes the same sections have in `Files.writeTo`; no header, no
/// guest memory, no board. `identity` is `files.identity()`, which hashes
/// the images, so a caller that saves often keeps it.
pub fn write(files: *state.Files, identity: run_file.Identity, writer: *std.Io.Writer) !void {
    try files.single();
    const count: usize = if (files.pair != null) 2 else 1;
    const cores = files.coresOf();
    try run_file.saveCores(writer, cores[0..count], identity);
    try files.writeTail(writer);
}
