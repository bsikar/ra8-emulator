//! What a run saves and restores (RA8EMU-696, RA8EMU-769): the whole run
//! written once its budget is spent, read back right after reset, or written
//! part way at a virtual time. The command line fills it in
//! (src/interfaces/cli/state_args.zig); the run clock reads it.

const std = @import("std");

/// Where a part-way snapshot is written, and whether it has been yet.
pub const At = struct { ns: u64, path: []const u8, written: bool = false };

pub const Options = struct {
    save: ?[]const u8 = null,
    load: ?[]const u8 = null,
    at: ?At = null,
    /// The host directory every session file read and write opens against.
    /// The application sets its own workspace directory here; null falls
    /// back to the process cwd for host tests.
    root: ?std.Io.Dir = null,

    pub fn wanted(self: Options) bool {
        return self.save != null or self.load != null or self.at != null;
    }

    /// The directory host file access resolves through, never the process
    /// global `cwd()` called directly at an open site.
    pub fn host(self: Options) std.Io.Dir {
        return self.root orelse std.Io.Dir.cwd();
    }
};
