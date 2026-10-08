//! Register edits from the shell's registers leaves (RA8EMU-946). A press
//! on a drawn value opens a hex field over it; Enter sends write_register
//! (0x0106) over the session link for that cell's register, where a q lane
//! writes the S register it aliases (registers_pane.valueIndex), and Escape
//! cancels. An accepted write makes the leaf's batch due, so the new value
//! shows from a real read-back and is never painted ahead of it; a refused
//! one keeps the last values and the leaf shows a note under them.
const std = @import("std");
const proto = @import("../interfaces/rpc/session_rpc.zig");
const session_link = @import("session_link.zig");
const registers_pane = @import("registers_pane.zig");
const hex_entry = @import("hex_entry.zig");
const font = @import("font.zig");
const draw_list = @import("draw_list.zig");
const platform = @import("platform.zig");
const pane_layout = @import("pane_layout.zig");
const shell_frame = @import("shell_frame.zig");
const shell_registers = @import("shell_registers.zig");

const Rect = draw_list.Rect;

pub const refused_note = "the session refused the write";

/// The first cell of the MVE group; a core without MVE draws none from here.
const mve_first = registers_pane.groups[registers_pane.groups.len - 1].first;

/// The cell (below registers_pane.cells) whose value text holds (`x`, `y`)
/// in a leaf drawn in `area`, or null. A folded group, or the MVE group on
/// a core without it, has no cells to hit.
pub fn cellAt(area: Rect, fold: registers_pane.Fold, mve: bool, x: i32, y: i32) ?usize {
    const last = if (mve) registers_pane.cells else mve_first;
    const w: i32 = @intCast(font.textWidth(8));
    for (0..last) |cell| {
        const rect = registers_pane.cellRect(area, fold, cell) orelse continue;
        const at = registers_pane.valueOrigin(rect);
        if (x >= at.x and x < at.x + w and y >= rect.y and y < rect.y + rect.h) return cell;
    }
    return null;
}

/// The wire register a write to `cell` names.
pub fn registerOf(cell: usize) proto.Register {
    return shell_registers.wire[registers_pane.valueIndex(cell)];
}

pub const Open = struct {
    core: proto.Core,
    cell: usize,
    field: hex_entry.Field = hex_entry.Field.init(8),
};

const Asked = struct { id: u32, core: proto.Core };

pub const Editor = struct {
    open: ?Open = null,
    /// The write in flight, whose answer re-reads or refuses.
    asked: ?Asked = null,
    /// Per core, whether its last write was refused.
    refused: [2]bool = .{ false, false },

    /// A left press: open a field on the value it lands on in a registers
    /// leaf with values, or let an open field go. Returns whether it opened.
    pub fn press(self: *Editor, pair: *const shell_registers.Pair, layout: *const pane_layout.Layout, solved: *const pane_layout.Solved, x: i32, y: i32) bool {
        self.open = null;
        for (solved.panes.items) |placed| {
            const pane = layout.pane(placed.index) orelse continue;
            if (pane.kind != .registers) continue;
            const model = pair.of(pane.core);
            const now = model.now orelse continue;
            const cell = cellAt(shell_frame.bodyOf(placed.area), model.fold, now.mve, x, y) orelse continue;
            self.open = .{ .core = model.core, .cell = cell };
            self.refused[@backingInt(model.core)] = false;
            return true;
        }
        return false;
    }

    /// Feed typing to the open field; Enter sends the write. Returns
    /// whether the event was taken.
    pub fn handle(self: *Editor, link: *session_link.Link, event: platform.Event) bool {
        const open = &(self.open orelse return false);
        switch (event) {
            .text => |text| open.field.typed(text.slice()),
            .key => |key| {
                if (!key.down) return true;
                switch (open.field.key(key.code)) {
                    .typing => {},
                    .cancel => self.open = null,
                    .commit => |value| self.commit(link, value),
                }
            },
            else => return false,
        }
        return true;
    }

    /// An answer to the write in flight: ok makes its leaf read again, err
    /// shows the note. Returns whether it was the write's answer.
    pub fn observe(self: *Editor, pair: *shell_registers.Pair, arrival: session_link.Arrival) bool {
        const asked = self.asked orelse return false;
        const response = switch (arrival) {
            .response => |response| response,
            .event => return false,
        };
        if (response.id != asked.id) return false;
        self.asked = null;
        switch (response.result) {
            .ok => pair.cores[@backingInt(asked.core)].want = true,
            .err => self.refused[@backingInt(asked.core)] = true,
        }
        return true;
    }

    /// The note under `core`'s values, or null.
    pub fn note(self: *const Editor, core: proto.Core) ?[]const u8 {
        return if (self.refused[@backingInt(core)]) refused_note else null;
    }

    /// Draw `core`'s open field over its value and its note, in a leaf
    /// drawn in `body` with `fold`.
    pub fn draw(self: *const Editor, list: *draw_list.DrawList, body: Rect, fold: registers_pane.Fold, core: proto.Core) !void {
        if (self.open) |open| if (open.core == core) {
            if (registers_pane.cellRect(body, fold, open.cell)) |rect| {
                const at = registers_pane.valueOrigin(rect);
                try hex_entry.draw(list, at.x, at.y, &open.field);
            }
        };
        const text = self.note(core) orelse return;
        const band: Rect = .{ .x = body.x, .y = body.y + body.h - registers_pane.row_h, .w = body.w, .h = registers_pane.row_h };
        try list.fill(band, registers_pane.background);
        try font.draw(list, band.x + registers_pane.pad, band.y + 2, text, registers_pane.muted);
    }

    fn commit(self: *Editor, link: *session_link.Link, value: u32) void {
        const open = self.open.?;
        self.open = null;
        const args: proto.WriteRegister = .{ .core = open.core, .register = registerOf(open.cell), .value = value };
        const id = link.send(proto.WriteRegister, .write_register, args) catch {
            self.refused[@backingInt(open.core)] = true;
            return;
        };
        self.asked = .{ .id = id, .core = open.core };
    }
};
