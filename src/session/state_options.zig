//! What a run saves and restores (RA8EMU-696, RA8EMU-769, ADR 0004 D20): the
//! whole run written once its budget is spent, read back right after reset, or
//! written part way at a virtual time. The command line fills it in
//! (src/interfaces/cli/state_args.zig); the run clock reads it via `file_ops`.
const file_ops = @import("file_ops.zig");

/// Where a part-way snapshot is written, and whether it has been yet.
pub const At = struct { ns: u64, path: []const u8, written: bool = false };

pub const Options = struct {
    save: ?[]const u8 = null,
    load: ?[]const u8 = null,
    at: ?At = null,
    /// Host-backed file callbacks (ADR 0004 D20). Null refuses state file I/O.
    files: ?file_ops.Ops = null,

    pub fn wanted(self: Options) bool {
        return self.save != null or self.load != null or self.at != null;
    }
};
