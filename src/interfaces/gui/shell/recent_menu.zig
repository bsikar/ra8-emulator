//! The File menu's Open Recent items (RA8EMU-1153): the model's own items,
//! then one item per recently loaded image, newest first, each named for
//! the image's file. The shell syncs each frame, so a load that succeeds
//! reorders the drop-down; opening a numbered one joins the list again.
const std = @import("std");
const menu = @import("../menu.zig");
const shell_recents = @import("recents.zig");

pub const State = struct {
    /// The shell's recent list (RA8EMU-1153), set at construction; null
    /// when the shell keeps none.
    recents: ?*shell_recents.List = null,
    /// The File menu's items: the model's own, then the recents.
    items: [menu.file.len + shell_recents.max]menu.Item = undefined,
    /// The four menus, File's items synced from the list.
    menus: [4]menu.Menu = undefined,

    /// The menus with File's items current, laid out below the strip.
    pub fn sync(self: *State) []const menu.Menu {
        for (&menu.file, 0..) |*item, at| self.items[at] = item.*;
        var next: usize = menu.file.len;
        if (self.recents) |list| {
            for (0..list.len) |at| {
                const full = list.path(at) orelse continue;
                self.items[next] = .{
                    .label = std.fs.path.basename(full),
                    .action = .{ .recent = at },
                    .divided = next == menu.file.len,
                };
                next += 1;
            }
        }
        self.menus[0] = .{ .title = "File", .items = self.items[0..next] };
        self.menus[1] = .{ .title = "Run", .items = &menu.run };
        self.menus[2] = .{ .title = "View", .items = &menu.view };
        self.menus[3] = .{ .title = "Board", .items = &menu.board };
        return self.menus[0..];
    }
};
