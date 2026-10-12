//! The shell's settings page (RA8EMU-963): one panel over the shell with the
//! theme rows, opened from File > Settings (Cmd+, on macOS, Ctrl+, else-
//! where) and closed with Escape, a row pick or a press outside it. Picking
//! a row applies the theme at once (RA8EMU-961, RA8EMU-962) and remembers it
//! across launches in a one-line file under SDL's per-user pref path. A
//! missing, unreadable or corrupt save reads as System, so a first launch
//! and a broken save both follow the OS.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const widget = @import("ra8_widget");
const font = @import("ra8_render").font;
const platform = @import("../platform.zig");
const colors = @import("../ui/colors.zig");
const shell_theme = @import("theme.zig");
const codes = @import("../ui/hex_entry.zig").codes;

const Rect = draw_list.Rect;
const Theme = colors.Theme;
const Choice = colors.Choice;
const Themes = shell_theme.Themes;

/// The saved choice's file name, inside the app's per-user directory.
pub const file_name = "theme";

const pad: i32 = 8;
const mark: i32 = 6;
const gap: i32 = 10;
pub const row_h: i32 = font.cell_h + 8;

const rows = [_]Choice{ .system, .light, .dark };
const labels = [_][]const u8{ "System", "Light", "Dark" };

/// The saved theme choice: one line of text in the app's per-user directory.
pub const Store = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    /// The app's per-user directory (SDL's pref path), or null when the
    /// platform gives none: a shell without one keeps this run's choice
    /// only.
    dir: ?[]const u8 = null,

    /// The saved choice, or System when nothing usable is saved.
    pub fn load(self: *const Store) Choice {
        const bytes = self.read() orelse return .system;
        defer self.allocator.free(bytes);
        return parse(bytes);
    }

    /// Saves the choice. A failure keeps the shell on the chosen theme and
    /// only means the next launch starts from the default again.
    pub fn save(self: *const Store, choice: Choice) void {
        const dir = self.dir orelse return;
        var buf: [1024]u8 = undefined;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = joined(dir, &buf), .data = text(choice) }) catch return;
    }

    fn read(self: *const Store) ?[]u8 {
        const dir = self.dir orelse return null;
        var buf: [1024]u8 = undefined;
        return std.Io.Dir.cwd().readFileAlloc(self.io, joined(dir, &buf), self.allocator, .limited(16)) catch null;
    }
};

/// The choice as the file's one line of text.
fn text(choice: Choice) []const u8 {
    return switch (choice) {
        .dark => "dark",
        .light => "light",
        .system => "system",
    };
}

/// A saved value as a choice: anything else is a corrupt save, not a crash.
fn parse(bytes: []const u8) Choice {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "dark")) return .dark;
    if (std.mem.eql(u8, trimmed, "light")) return .light;
    if (std.mem.eql(u8, trimmed, "system")) return .system;
    return .system;
}

fn joined(dir: []const u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/" ++ file_name, .{dir}) catch file_name;
}

/// The page over the shell. While it is up it takes every press and key;
/// the loop hands them over before anything else sees them.
pub const Page = struct {
    store: ?*const Store = null,
    /// The page is up over the shell.
    open: bool = false,

    /// Opens the page (File > Settings).
    pub fn ask(self: *Page) void {
        self.open = true;
    }

    /// While the page is up, Escape closes it and every other key is kept;
    /// a closed page takes nothing. Returns whether the key was the page's.
    pub fn key(self: *Page, event: platform.Event) bool {
        if (!self.open) return false;
        switch (event) {
            .key => |pressed| if (pressed.down and pressed.code == codes.escape) {
                self.open = false;
            },
            else => {},
        }
        return true;
    }

    /// A left press while the page is up: a row applies its choice, closes
    /// the page and remembers it; a press outside the panel closes the
    /// page; a press on the panel's padding is kept. Returns whether the
    /// press was the page's.
    pub fn press(self: *Page, themes: *Themes, width: i32, height: i32, x: i32, y: i32) bool {
        if (!self.open) return false;
        const panel = panelOf(width, height);
        if (!panel.contains(x, y)) {
            self.open = false;
            return true;
        }
        const picked = hit(panel, x, y) orelse return true;
        themes.choose(picked);
        if (self.store) |store| store.save(picked);
        self.open = false;
        return true;
    }

    /// Paints the panel over the shell through the handed Paint table
    /// (RA8EMU-1157): the title, then one row per theme choice, the active
    /// choice marked.
    pub fn draw(self: *const Page, table: *const widget.types.Paint, themes: *const Themes, theme: *const Theme, width: i32, height: i32) !void {
        if (!self.open) return;
        const panel = panelOf(width, height);
        fillArea(table, panel, word(theme.surface));
        border(table, panel, theme.border);
        const title = Rect{ .x = panel.x + pad, .y = panel.y + pad, .w = panel.w - 2 * pad, .h = row_h };
        drawText(table, title.x, title.y + draw_list.centre(title.h, font.glyph_h), "Settings", word(theme.muted), word(theme.surface));
        const active = themes.choice();
        for (rows, 0..) |picked, index| {
            const area = rowArea(panel, index);
            if (picked == active) fillArea(table, area, word(theme.band));
            const top = area.y + draw_list.centre(area.h, font.glyph_h);
            const color = if (picked == active) theme.highlight else theme.ink;
            drawText(table, area.x + mark + gap, top, labels[index], word(color), word(theme.surface));
            if (picked == active) fillArea(table, .{ .x = area.x, .y = top + @divFloor(font.glyph_h - mark, 2), .w = mark, .h = mark }, word(theme.highlight));
        }
    }
};

fn labelWidth(label: []const u8) i32 {
    return @intCast(font.textWidth(label.len));
}

/// The panel's place, centred horizontally and a third down the window.
pub fn panelOf(width: i32, height: i32) Rect {
    var w = labelWidth("Settings");
    const row_w = mark + gap + labelWidth("System");
    if (row_w > w) w = row_w;
    const h: i32 = pad + row_h + pad + @as(i32, @intCast(rows.len)) * row_h + pad;
    return .{
        .x = @max(0, @divFloor(width - w - 2 * pad, 2)),
        .y = @max(0, @divFloor(height - h, 3)),
        .w = w + 2 * pad,
        .h = h,
    };
}

pub fn rowArea(panel: Rect, index: usize) Rect {
    const top = panel.y + pad + row_h + pad + @as(i32, @intCast(index)) * row_h;
    return .{ .x = panel.x + pad, .y = top, .w = panel.w - 2 * pad, .h = row_h };
}

/// The row at (`x`, `y`), or null when the point is the title or padding.
fn hit(panel: Rect, x: i32, y: i32) ?Choice {
    for (rows, 0..) |picked, index| {
        if (rowArea(panel, index).contains(x, y)) return picked;
    }
    return null;
}

fn border(table: *const widget.types.Paint, panel: Rect, color: draw_list.Color) void {
    fillArea(table, .{ .x = panel.x, .y = panel.y, .w = panel.w, .h = 1 }, word(color));
    fillArea(table, .{ .x = panel.x, .y = panel.y + panel.h - 1, .w = panel.w, .h = 1 }, word(color));
    fillArea(table, .{ .x = panel.x, .y = panel.y, .w = 1, .h = panel.h }, word(color));
    fillArea(table, .{ .x = panel.x + panel.w - 1, .y = panel.y, .w = 1, .h = panel.h }, word(color));
}

/// `area` filled with `color` through the shared Paint table (RA8EMU-1157).
fn fillArea(table: *const widget.types.Paint, area: Rect, color: u32) void {
    table.fill_rect.?(table.user, area.x, area.y, area.w, area.h, color);
}

/// One line of text as the firmware's label widget (RA8EMU-1157), the pane
/// pattern: pad 0, left-aligned, rect = the text's own cell.
fn drawText(table: *const widget.types.Paint, x: i32, y: i32, label: []const u8, fg: u32, bg: u32) void {
    var buffer: [64]u8 = undefined;
    const n = @min(label.len, buffer.len - 1);
    @memcpy(buffer[0..n], label[0..n]);
    buffer[n] = 0;
    var descriptor = widget.label.Label{
        .paint = table,
        .text = buffer[0..n :0].ptr,
        .fg = fg,
        .bg = bg,
        .pad = 0,
        .alignment = .left,
        .face = .sans,
    };
    var w: widget.types.Widget = undefined;
    _ = widget.label.ra8_widget_label_init(&w, &descriptor);
    w.rect = .{
        .x = x,
        .y = y,
        .w = @intCast(font.textWidth(label.len)),
        .h = @intCast(font.cell_h),
    };
    w.vt.?.render.?(&w);
}

/// `color` as the widget's 0x00RRGGBB colour word (RA8EMU-1157).
fn word(color: draw_list.Color) u32 {
    return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
}
