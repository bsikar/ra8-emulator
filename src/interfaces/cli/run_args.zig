//! What a Zig run takes, gathered by zig_main.zig: zig_run.run's arguments
//! as one value, so the live window ra8_gui hands in (RA8EMU-1088) can run
//! the same run without the command line importing the GUI.
const std = @import("std");
const elf = @import("../../image/elf.zig");
const Guest = @import("../../chip/core/cpu/memory/guest.zig").Guest;
const Board = @import("../../board/board.zig").Board;
const clocks = @import("../../chip/periph/clocks.zig");
const profile = @import("../../session/profile.zig");
const Until = @import("../../chip/core/until.zig").Until;
const cli = @import("cli.zig");
const zig_run = @import("zig_run.zig");

/// zig_run.run's arguments, gathered by zig_main.
pub const Args = struct {
    io: std.Io,
    out: *std.Io.Writer,
    memory: Guest,
    board: *Board,
    timebase: *clocks.Clocks,
    image: elf.Image,
    options: cli.Options,
    vector_base: u32,
    profile_table: ?*profile.Table,
    until: ?*Until,
    ends: zig_run.Ends,
};
