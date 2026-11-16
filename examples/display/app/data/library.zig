//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! What the UI asks the bookshelf for: the book being read, what was opened
//! recently, everything on the shelf, and the text of one page.

pub const Kind = enum { book, comic, audio };

pub const Entry = struct {
    title: [:0]const u8,
    meta: [:0]const u8,
    kind: Kind,
    on_device: bool = true,
};

pub const Reading = struct {
    title: [:0]const u8,
    author: [:0]const u8,
    chapter: [:0]const u8,
    chapter_title: [:0]const u8,
    page: u16,
    pages: u16,
    chapter_pages_left: u16,
    percent: u16,
};

/// The text of one page: an optional chapter opening, then paragraphs.
pub const Page = struct {
    opens_chapter: bool,
    paragraphs: []const [:0]const u8,
};

pub const Library = struct {
    ctx: *anyopaque,
    ops: *const Ops,

    pub const Ops = struct {
        reading: *const fn (ctx: *anyopaque) Reading,
        recent: *const fn (ctx: *anyopaque) []const Entry,
        shelf: *const fn (ctx: *anyopaque) []const Entry,
        page: *const fn (ctx: *anyopaque, number: u16) Page,
        turn: *const fn (ctx: *anyopaque, delta: i32) void,
    };

    pub fn reading(self: Library) Reading {
        return self.ops.reading(self.ctx);
    }
    pub fn recent(self: Library) []const Entry {
        return self.ops.recent(self.ctx);
    }
    pub fn shelf(self: Library) []const Entry {
        return self.ops.shelf(self.ctx);
    }
    pub fn page(self: Library, number: u16) Page {
        return self.ops.page(self.ctx, number);
    }
    /// Move the reading position by `delta` pages, clamped to the book.
    pub fn turn(self: Library, delta: i32) void {
        self.ops.turn(self.ctx, delta);
    }
};
