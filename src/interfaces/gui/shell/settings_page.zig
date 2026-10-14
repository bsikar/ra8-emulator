//! The shell's settings page (RA8EMU-963): one panel over the shell, opened
//! from File > Settings (Cmd+, on macOS, Ctrl+, elsewhere) and closed with
//! Escape or a press outside it. Each row is one setting with its choices
//! side by side: the theme (RA8EMU-961, RA8EMU-962), then the display's
//! vsync, frame rate limit and frame counter (display_settings.zig). A press
//! on a choice applies it at once and remembers it across launches in a
//! small file under SDL's per-user pref path. A missing, unreadable or
//! corrupt save reads as the defaults, so a first launch and a broken save
//! both follow the OS and the display.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const widget = @import("ra8_widget");
const font = @import("ra8_render").font;
const platform = @import("../platform.zig");
const colors = @import("../ui/colors.zig");
const shell_theme = @import("theme.zig");
const display_settings = @import("../display_settings.zig");
const codes = @import("../ui/hex_entry.zig").codes;

const geom = @import("../geom.zig");
const Rect = geom.Rect;
const Theme = colors.Theme;
const Choice = colors.Choice;
const Themes = shell_theme.Themes;
const Display = display_settings.Display;

/// The saved theme's file name, inside the app's per-user directory.
pub const file_name = "theme";
/// The saved display choices' file name, beside it.
pub const display_file_name = "display";

const pad: i32 = 8;
const gap: i32 = 10;
/// The space either side of a choice's text inside its cell.
const inset: i32 = 6;
pub const row_h: i32 = font.cell_h + 8;

/// The page's rows, top to bottom.
pub const Row = enum(u8) { theme, vsync, limit, counter };

const Spec = struct { label: []const u8, choices: []const []const u8 };
const on_off = [_][]const u8{ "On", "Off" };
const specs = [_]Spec{
    .{ .label = "Theme", .choices = &.{ "System", "Light", "Dark" } },
    .{ .label = "VSync", .choices = &on_off },
    .{ .label = "Frame rate limit", .choices = &display_settings.Limit.labels },
    .{ .label = "FPS counter", .choices = &on_off },
};
const themes_in_order = [_]Choice{ .system, .light, .dark };

/// The saved choices: a small text file each in the app's per-user directory.
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
        self.put(file_name, text(choice));
    }

    /// The saved display choices, or the defaults for whatever is not saved.
    pub fn loadDisplay(self: *const Store) Display {
        const bytes = self.get(display_file_name, 256) orelse return .{};
        defer self.allocator.free(bytes);
        return Display.parse(bytes);
    }

    pub fn saveDisplay(self: *const Store, display: Display) void {
        var buf: [64]u8 = undefined;
        self.put(display_file_name, display.write(&buf));
    }

    fn read(self: *const Store) ?[]u8 {
        return self.get(file_name, 16);
    }

    fn get(self: *const Store, name: []const u8, most: usize) ?[]u8 {
        const dir = self.dir orelse return null;
        var buf: [1024]u8 = undefined;
        return std.Io.Dir.cwd().readFileAlloc(self.io, joined(dir, name, &buf), self.allocator, .limited(most)) catch null;
    }

    fn put(self: *const Store, name: []const u8, data: []const u8) void {
        const dir = self.dir orelse return;
        var buf: [1024]u8 = undefined;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = joined(dir, name, &buf), .data = data }) catch return;
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

fn joined(dir: []const u8, name: []const u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch name;
}

/// The page over the shell. While it is up it takes every press and key;
/// the loop hands them over before anything else sees them.
pub const Page = struct {
    store: ?*const Store = null,
    /// The page is up over the shell.
    open: bool = false,
    /// The display rows' choices, which the drive loop paces the window by.
    display: Display = .{},

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

    /// A left press while the page is up: a choice is applied and
    /// remembered, and the page stays up for the next one; a press outside
    /// the panel closes the page; a press anywhere else on the panel is
    /// kept. Returns whether the press was the page's.
    pub fn press(self: *Page, themes: *Themes, width: i32, height: i32, x: i32, y: i32) bool {
        if (!self.open) return false;
        const panel = panelOf(width, height);
        if (!geom.contains(panel, x, y)) {
            self.open = false;
            return true;
        }
        const picked = hit(panel, x, y) orelse return true;
        self.apply(themes, picked.row, picked.choice);
        return true;
    }

    /// Take choice `index` of `row`, and save it.
    pub fn apply(self: *Page, themes: *Themes, row: Row, index: usize) void {
        switch (row) {
            .theme => {
                themes.choose(themes_in_order[index]);
                if (self.store) |store| store.save(themes_in_order[index]);
                return;
            },
            .vsync => self.display.vsync = index == 0,
            .limit => self.display.limit = @fromBackingInt(@intCast(index)),
            .counter => self.display.counter = index == 0,
        }
        if (self.store) |store| store.saveDisplay(self.display);
    }

    /// Which of `row`'s choices is in force.
    pub fn chosen(self: *const Page, themes: *const Themes, row: Row) usize {
        return switch (row) {
            .theme => std.mem.indexOfScalar(Choice, &themes_in_order, themes.choice()).?,
            .vsync => @intFromBool(!self.display.vsync),
            .limit => @backingInt(self.display.limit),
            .counter => @intFromBool(!self.display.counter),
        };
    }

    /// Paints the panel over the shell through the handed Paint table
    /// (RA8EMU-1157): the title, then one row per setting, its name and
    /// its choices with the one in force marked.
    pub fn draw(self: *const Page, table: *const widget.types.Paint, themes: *const Themes, theme: *const Theme, width: i32, height: i32) !void {
        if (!self.open) return;
        const panel = panelOf(width, height);
        fillArea(table, panel, word(theme.surface));
        border(table, panel, theme.border);
        const title = Rect{ .x = panel.x + pad, .y = panel.y + pad, .w = panel.w - 2 * pad, .h = row_h };
        drawText(table, title.x, title.y + draw_list.centre(title.h, font.glyph_h), "Settings", word(theme.muted), word(theme.surface));
        for (specs, 0..) |spec, row| {
            const area = rowArea(panel, row);
            const top = area.y + draw_list.centre(area.h, font.glyph_h);
            drawText(table, area.x, top, spec.label, word(theme.ink), word(theme.surface));
            const active = self.chosen(themes, @fromBackingInt(@intCast(row)));
            for (spec.choices, 0..) |label, index| {
                const cell = choiceArea(panel, row, index);
                if (index == active) fillArea(table, cell, word(theme.band));
                const color = if (index == active) theme.highlight else theme.ink;
                drawText(table, cell.x + inset, top, label, word(color), word(if (index == active) theme.band else theme.surface));
            }
        }
    }
};

fn labelWidth(label: []const u8) i32 {
    return @intCast(font.textWidth(label.len));
}

/// The widest setting name: the choices start one gap past it.
fn nameWidth() i32 {
    var widest: i32 = 0;
    for (specs) |spec| widest = @max(widest, labelWidth(spec.label));
    return widest;
}

/// How wide `spec`'s choices are, laid side by side.
fn choicesWidth(spec: Spec) i32 {
    var total: i32 = 0;
    for (spec.choices) |label| total += labelWidth(label) + 2 * inset;
    return total;
}

/// The panel's place, centred horizontally and a third down the window.
pub fn panelOf(width: i32, height: i32) Rect {
    var widest: i32 = 0;
    for (specs) |spec| widest = @max(widest, choicesWidth(spec));
    const w = nameWidth() + gap + widest;
    const h: i32 = pad + row_h + pad + @as(i32, @intCast(specs.len)) * row_h + pad;
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

/// The cell of choice `index` in row `row`.
pub fn choiceArea(panel: Rect, row: usize, index: usize) Rect {
    const area = rowArea(panel, row);
    var x = area.x + nameWidth() + gap;
    for (specs[row].choices[0..index]) |label| x += labelWidth(label) + 2 * inset;
    return .{ .x = x, .y = area.y + 2, .w = labelWidth(specs[row].choices[index]) + 2 * inset, .h = area.h - 4 };
}

const Picked = struct { row: Row, choice: usize };

/// The choice at (`x`, `y`), or null when the point is a name, the title
/// or padding.
fn hit(panel: Rect, x: i32, y: i32) ?Picked {
    for (specs, 0..) |spec, row| {
        for (0..spec.choices.len) |index| {
            if (geom.contains(choiceArea(panel, row, index), x, y)) return .{ .row = @fromBackingInt(@intCast(row)), .choice = index };
        }
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
