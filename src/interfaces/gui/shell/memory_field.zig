//! The memory leaf's address field (RA8EMU-934): a text field (RA8EMU-803)
//! along the foot of a memory leaf. Type a hex address or a symbol and press
//! Enter: the leaf pins there and re-reads its rows from that row, and an
//! empty field goes back to following the bound register. A name nothing
//! resolves leaves a note above the field and keeps the text for fixing.
//! One field; with two memory leaves it sits in the last one drawn.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const platform = @import("../platform.zig");
const shell_frame = @import("../ui/shell/frame.zig");
const shell_field = @import("../ui/shell/field.zig");
const shell_memory = @import("memory.zig");
const memory_pane = @import("../ui/memory_pane.zig");
const symbols = @import("ra8_session").symbols;
const Theme = @import("../ui/colors.zig").Theme;

const Rect = draw_list.Rect;

/// The image a typed symbol resolves against; the shell's own, per load.
pub const Image = symbols.Image;

pub const placeholder = "address or symbol, Enter pins";
pub const refusal = "no such address or symbol";

/// The address in `text`, or null when it is empty or names nothing: a hex
/// address (0x optional) or a name the image's symbols resolve.
pub fn parse(text: []const u8, image: ?Image) ?u32 {
    if (text.len == 0) return null;
    const hex = text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X');
    const digits = if (hex) text[2..] else text;
    if (std.fmt.parseInt(u32, digits, 16)) |address| return address else |_| {}
    return if (image) |img| symbols.addressOf(img, text) else null;
}

pub const Pin = struct {
    field: shell_field.Field = .{},
    /// The image a typed symbol resolves against; the shell sets it per load.
    image: ?Image = null,
    refused: bool = false,

    /// Set the field up in place; the pin must not move afterwards.
    pub fn init(self: *Pin) !void {
        try self.field.init(placeholder);
    }

    /// Feed a window event to the field. Returns whether it was taken.
    pub fn handle(self: *Pin, event: platform.Event) bool {
        return self.field.handle(event);
    }

    /// A left press: focus the field inside it, let it go outside.
    pub fn press(self: *Pin, x: i32, y: i32) bool {
        return self.field.press(x, y);
    }

    /// Enter submitted: pin the leaf to the typed address or symbol, or
    /// let it follow its register again when the field is empty. False
    /// when Enter was not pressed.
    pub fn submit(self: *Pin, pair: ?*shell_memory.Pair) bool {
        if (!self.field.takeSubmit()) return false;
        const text = self.field.value();
        const address = parse(text, self.image);
        if (address == null and text.len != 0) {
            self.refused = true;
            return true;
        }
        self.refused = false;
        if (pair) |pinned| pinned.pinTo(address);
        return true;
    }
};

/// The field's rect along the foot of a memory leaf `body`.
pub fn fieldRect(body: Rect) Rect {
    const w = @max(body.w - 2 * shell_frame.pad, 0);
    return .{ .x = body.x + shell_frame.pad, .y = body.y + body.h - shell_frame.pad - shell_field.height, .w = w, .h = shell_field.height };
}

/// The part of `body` left for the rows, above the field and its note.
pub fn rowsRect(body: Rect) Rect {
    const taken = shell_field.height + 2 * shell_frame.pad;
    return .{ .x = body.x, .y = body.y, .w = body.w, .h = @max(body.h - taken, 0) };
}

/// Draw a memory leaf with the field: the rows above, a refusal note, then
/// the field at the foot. A leaf too short for both keeps its rows whole.
pub fn draw(list: *draw_list.DrawList, theme: *const Theme, body: Rect, now: *const shell_memory.Snapshot, pin: *Pin) !void {
    if (body.h < shell_field.height + 2 * shell_frame.pad) return memory_pane.draw(list, theme, body, now);
    try memory_pane.draw(list, theme, rowsRect(body), now);
    const field = fieldRect(body);
    if (pin.refused) try font.draw(list, field.x, field.y - font.glyph_h - 2, font.fit(refusal, @intCast(@max(field.w, 0))), theme.muted);
    try pin.field.draw(list, theme, field);
}
