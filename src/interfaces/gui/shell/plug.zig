//! The shell's plug picker (RA8EMU-802): a text field (RA8EMU-803) along the
//! foot of the devices leaf. Type `MODEL@ENDPOINT[=MODE]` (the session's part
//! spec, RA8EMU-749) and press Enter: the shell sends plug for cpu0, and once
//! the session answers the device list is asked for again (RA8EMU-801 does
//! the same after unplug), so a fitted part shows up as a row. A refusal
//! leaves a note above the field and keeps the text for fixing. One plug is
//! in flight at a time. There is one field; with two devices leaves it sits
//! in the last one drawn.
const proto = @import("ra8_rpc").session.rpc;
const session_link = @import("../session_link.zig");
const Theme = @import("../ui/colors.zig").Theme;
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const widget = @import("ra8_widget");
const platform = @import("../platform.zig");
const shell_frame = @import("../ui/shell/frame.zig");
const shell_field = @import("../ui/shell/field.zig");
const shell_devices = @import("devices.zig");

const geom = @import("../geom.zig");
const Rect = geom.Rect;

pub const placeholder = "plug MODEL@ENDPOINT, then Enter";
pub const refusal = "the session would not plug that part";

pub const Plug = struct {
    field: shell_field.Field = .{},
    /// The plug ask in flight.
    asking: ?u32 = null,
    refused: bool = false,

    /// Set the field up in place; the picker must not move afterwards.
    pub fn init(self: *Plug) !void {
        try self.field.init(placeholder);
    }

    /// Feed a window event to the field. Returns whether it was taken.
    pub fn handle(self: *Plug, event: platform.Event) bool {
        return self.field.handle(event);
    }

    /// A left press: focus the field inside it, let it go outside.
    pub fn press(self: *Plug, x: i32, y: i32) bool {
        return self.field.press(x, y);
    }

    /// Send plug once Enter submitted a spec. False when nothing was sent.
    pub fn attach(self: *Plug, link: *session_link.Link) bool {
        if (!self.field.takeSubmit()) return false;
        const text = self.field.value();
        if (text.len == 0 or self.asking != null or link.state != .connected) return false;
        self.asking = link.send(proto.PartSpec, .plug, .{ .core = .cpu0, .text = text }) catch return false;
        self.refused = false;
        return true;
    }

    /// Note the answer to our plug. Returns true when it was ours, so the
    /// device list can be asked for again.
    pub fn observe(self: *Plug, arrival: session_link.Arrival) bool {
        const response = switch (arrival) {
            .response => |response| response,
            .event => return false,
        };
        if (self.asking == null or self.asking != response.id) return false;
        self.asking = null;
        self.refused = response.result == .err;
        if (!self.refused) self.field.clear();
        return true;
    }
};

/// The field's rect along the foot of a devices leaf `body`.
pub fn fieldRect(body: Rect) Rect {
    const w = @max(body.w - 2 * shell_frame.pad, 0);
    return .{ .x = body.x + shell_frame.pad, .y = body.y + body.h - shell_frame.pad - shell_field.height, .w = w, .h = shell_field.height };
}

/// The part of `body` left for the rows, above the field and its note.
pub fn rowsRect(body: Rect) Rect {
    const taken = shell_field.height + 2 * shell_frame.pad + shell_devices.row_h;
    return .{ .x = body.x, .y = body.y, .w = body.w, .h = @max(body.h - taken, 0) };
}

/// Draw a devices leaf with the picker: the rows (or the list's note) above,
/// the refusal note, then the field at the foot.
pub fn draw(table: *const widget.types.Paint, theme: *const Theme, body: Rect, devices: *const shell_devices.Devices, plug: *Plug) !void {
    if (body.h < shell_field.height + 2 * shell_frame.pad) return;
    const rows = rowsRect(body);
    const room = body.w - 2 * shell_frame.pad;
    if (devices.note()) |note| {
        if (room > 0 and rows.h >= font.glyph_h + shell_frame.pad) drawText(table, rows.x + shell_frame.pad, rows.y + shell_frame.pad, font.fit(note, @intCast(room)), word(theme.muted), word(theme.background));
    } else try shell_devices.draw(table, theme, rows, devices);
    const field = fieldRect(body);
    if (plug.refused and room > 0) drawText(table, field.x, field.y - shell_devices.row_h, font.fit(refusal, @intCast(room)), word(theme.muted), word(theme.background));
    try plug.field.draw(table, theme, field);
}
fn drawText(table: *const widget.types.Paint, x: i32, y: i32, text: []const u8, fg: u32, bg: u32) void {
    var buffer: [64]u8 = undefined;
    const n = @min(text.len, buffer.len - 1);
    @memcpy(buffer[0..n], text[0..n]);
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
        .w = @intCast(font.textWidth(text.len)),
        .h = @intCast(font.cell_h),
    };
    w.vt.?.render.?(&w);
}

/// `color` as the widget's 0x00RRGGBB colour word.
fn word(color: draw_list.Color) u32 {
    return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
}
