//! The shell's board pick (RA8EMU-1152): a Board menu choice composes a
//! profile from the shipped board's text with the chosen panel, saves the
//! choice for the next launch, and hands the composed text to the
//! launcher's apply function, which reopens the session with the loaded
//! ELF kept and the machine paused at reset. The launcher wires apply in;
//! a pick without one only saves.
const std = @import("std");
const platform = @import("../platform.zig");
const menu = @import("../menu.zig");
const board_profiles = @import("board_profiles.zig");
const board_store = @import("board_store.zig");

/// Largest profile file the OS picker's choice reads, as the run's own
/// profile text is small.
pub const max_profile: usize = 64 * 1024;

pub const Pick = struct {
    allocator: std.mem.Allocator,
    /// Where the choice persists; null keeps choices for this launch only.
    store: ?*board_store.Store = null,
    /// The launcher's rebuild (main's local wiring): reopens the session
    /// with `profile`, the loaded ELF kept, paused at reset.
    context: ?*anyopaque = null,
    applyFn: ?*const fn (context: *anyopaque, profile: []const u8) anyerror!void = null,
    /// The choice in force, the saved one when the shell opened.
    chosen: board_store.Choice = .{},
    /// The composed profile text the choice made, alive until the next
    /// pick: the session's parsed profile may hold its slices.
    composed: ?[]u8 = null,
    /// The OS profile picker was asked for; the next frame puts it up.
    asked: bool = false,
    /// The io the picked file reads through.
    io: std.Io = undefined,
    /// A choice rebuilt the session; the drive loop reloads the image
    /// once the rebuilt one greets, then clears this.
    reload: bool = false,

    /// The Board menu's Open Profile item.
    pub fn ask(self: *Pick) void {
        self.asked = true;
    }

    /// One Board menu choice: compose, save and rebuild.
    pub fn choose(self: *Pick, choice: menu.Choice) void {
        var chosen = self.chosen;
        switch (choice.kind) {
            .board => {
                if (!chosen.setBoard(choice.stem)) return;
                chosen.panel_len = 0;
            },
            .panel => if (!chosen.setPanel(choice.stem)) return,
        }
        const profile = compose(self.allocator, chosen.panel()) orelse return;
        if (self.composed) |old| self.allocator.free(old);
        self.composed = profile;
        self.chosen = chosen;
        if (self.store) |store| store.save(chosen);
        self.hand(profile);
    }

    /// Once a frame: put the OS profile picker up if it was asked for.
    pub fn frame(self: *Pick, window: platform.Platform) void {
        if (self.asked) {
            self.asked = false;
            _ = window.openProfile();
        }
    }

    /// The path the OS picker sent back: a custom board profile, applied
    /// as its own text. A file that cannot be read is ignored.
    pub fn picked(self: *Pick, path: []const u8) void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(max_profile)) catch return;
        defer self.allocator.free(bytes);
        const copy = self.allocator.dupe(u8, bytes) catch return;
        if (self.composed) |old| self.allocator.free(old);
        self.composed = copy;
        self.hand(copy);
    }

    /// Hands `profile` to the launcher's apply; a rebuild that succeeded
    /// asks the drive loop to reload the image (RA8EMU-1152).
    fn hand(self: *Pick, profile: []const u8) void {
        const context = self.context orelse return;
        const apply = self.applyFn orelse return;
        apply(context, profile) catch return;
        self.reload = true;
    }
};

/// The shipped board's text with the chosen panel line: the board's own
/// line when the stem is empty, the line dropped when it is "none", the
/// value replaced otherwise. Returns null only when out of memory.
pub fn compose(allocator: std.mem.Allocator, panel_stem: []const u8) ?[]u8 {
    const board_text = board_profiles.board_text;
    var len: usize = 0;
    var lines = std.mem.splitScalar(u8, board_text, '\n');
    while (lines.next()) |line| {
        if (dropped(line, panel_stem)) continue;
        if (std.mem.startsWith(u8, line, "panel=") and panel_stem.len > 0) {
            len += "panel=".len + panel_stem.len + 1;
        } else {
            len += line.len + 1;
        }
    }
    const out = allocator.alloc(u8, len) catch return null;
    var w: usize = 0;
    lines.reset();
    while (lines.next()) |line| {
        if (dropped(line, panel_stem)) continue;
        if (std.mem.startsWith(u8, line, "panel=") and panel_stem.len > 0) {
            const written = std.fmt.bufPrint(out[w..], "panel={s}\n", .{panel_stem}) catch unreachable;
            w += written.len;
        } else {
            @memcpy(out[w .. w + line.len], line);
            out[w + line.len] = '\n';
            w += line.len + 1;
        }
    }
    return out;
}

/// Whether a board line drops under the choice: only the panel line can,
/// and only when the choice names no panel at all.
fn dropped(line: []const u8, panel_stem: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "panel=")) return false;
    if (panel_stem.len == 0) return false;
    return std.mem.eql(u8, panel_stem, "none");
}
