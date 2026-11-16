//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! The look of the UI in one place: panel size, colours, the fixed heights
//! the design gives each band, and which face, weight and size each text
//! role uses. Screens name a role; only this file knows what it resolves to,
//! so a new text capability in ra8_widget changes one table and no screen.

const rw = @import("ra8_widget");

pub const Face = rw.paint.Face;
pub const Weight = rw.paint.Weight;
pub const Size = rw.paint.TextSize;
pub const Alignment = rw.types.Alignment;

/// The e-ink panel, in pixels.
pub const panel = struct {
    pub const width: i32 = 1072;
    pub const height: i32 = 1448;
};

/// Greyscale colours as 0xRRGGBB, the form the paint struct takes.
pub const color = struct {
    pub const ink: u32 = 0x000000;
    pub const paper: u32 = 0xFFFFFF;
    pub const cover: u32 = 0xD9D9D9;
    pub const muted: u32 = 0x555555;
};

/// Band heights and insets, straight from the design artboards.
pub const metric = struct {
    pub const sys_bar: i16 = 72;
    pub const header: i16 = 88;
    pub const header_gap: i16 = 16;
    pub const rule: i16 = 2;
    pub const heavy_rule: i16 = 4;
    pub const hair: i16 = 1;
    pub const margin: i16 = 56;
    pub const row: i16 = 88;
    pub const tall_row: i16 = 120;
    pub const control: i16 = 88;
    pub const pager: i16 = 88;
    pub const tabs: i16 = 120;
    pub const now_playing: i16 = 72;
    pub const section: i16 = 56;
    pub const text_pad: i16 = 4;
    pub const toggle_box: u16 = 56;
    /// Line boxes of the display roles below, in pixels.
    pub const title_line: i16 = 104;
    pub const heading_line: i16 = 60;
    pub const clock_line: i16 = 184;
};

/// One resolved text style.
pub const Text = struct {
    face: Face = .sans,
    weight: Weight = .regular,
    size: Size = .size_5,
    fg: u32 = color.ink,
    bg: u32 = color.paper,
    alignment: Alignment = .left,
    pad: i16 = 0,

    pub fn with(self: Text, alignment: Alignment) Text {
        var copy = self;
        copy.alignment = alignment;
        return copy;
    }

    pub fn on(self: Text, fg: u32, bg: u32) Text {
        var copy = self;
        copy.fg = fg;
        copy.bg = bg;
        return copy;
    }

    pub fn padded(self: Text, pad: i16) Text {
        var copy = self;
        copy.pad = pad;
        return copy;
    }
};

/// The text roles the design uses. Titles, headings and the clock are
/// ra8_widget's native display sizes. The design's 24 to 30 px interface
/// text has no native size yet, so it sits at the largest reading size.
pub const text = struct {
    /// What a widget's own text draws at: rows, tabs, pager, buttons.
    pub const ui_size: Size = .size_5;
    pub const title: Text = .{ .face = .serif, .weight = .bold, .size = .title_68 };
    pub const heading: Text = .{ .face = .serif, .weight = .bold, .size = .body_38 };
    pub const clock: Text = .{ .face = .serif, .weight = .bold, .size = .clock_120 };
    pub const section: Text = .{ .face = .sans, .weight = .bold, .size = .size_4 };
    pub const body: Text = .{ .face = .sans, .size = .size_5 };
    pub const strong: Text = .{ .face = .sans, .weight = .bold, .size = .size_5 };
    pub const note: Text = .{ .face = .sans, .size = .size_4 };
    pub const placeholder: Text = .{ .face = .sans, .size = .size_4, .fg = color.muted, .bg = color.cover, .alignment = .center };
};
