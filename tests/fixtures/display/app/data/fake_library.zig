//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! A bookshelf with fixed contents, standing in for storage.

const library = @import("library.zig");

const Entry = library.Entry;

pub const book = struct {
    pub const first_page: u16 = 42;
    pub const pages: u16 = 310;
    pub const chapter_end: u16 = 51;
};

const recent_entries = [_]Entry{
    .{ .title = "The Ninth Ferry", .meta = "MDL - Ch. 212", .kind = .comic },
    .{ .title = "The Cartographer's Winter", .meta = "Audiobook - Ch. 6", .kind = .audio },
    .{ .title = "Salt Roads", .meta = "Book - 64%", .kind = .book },
    .{ .title = "Glass Harbour", .meta = "Album - 9 songs", .kind = .audio },
};

const shelf_entries = [_]Entry{
    .{ .title = "A Field Guide to Quiet Rivers", .meta = "Book - 13%", .kind = .book },
    .{ .title = "The Ninth Ferry", .meta = "MDL - 3 offline", .kind = .comic },
    .{ .title = "Salt Roads", .meta = "Book - 64%", .kind = .book },
    .{ .title = "Quiet Gears", .meta = "MDL - 22 offline", .kind = .comic },
    .{ .title = "The Glass Orchard", .meta = "Book - new", .kind = .book },
    .{ .title = "Notes on Small Weather", .meta = "Book - finished", .kind = .book },
    .{ .title = "Saltwind Academy", .meta = "MDL - needs Wi-Fi", .kind = .comic, .on_device = false },
    .{ .title = "An Atlas of Borrowed Rooms", .meta = "Book - 2%", .kind = .book },
    .{ .title = "The Lamplighter's Almanac", .meta = "Book - 40%", .kind = .book },
    .{ .title = "Iron Orchard", .meta = "MDL - 1 offline", .kind = .comic },
    .{ .title = "Low Tide Letters", .meta = "Book - new", .kind = .book },
    .{ .title = "Hollow Bell", .meta = "MDL - needs Wi-Fi", .kind = .comic, .on_device = false },
};

const opening = [_][:0]const u8{
    "By August the river had forgotten how to hurry. It lay in its bed like a long animal asleep, showing the pale stones of its spine wherever the gravel rose, and the herons walked across it as if it were a road they had always meant to take.",
    "I had been told that a quiet river is the easiest kind to read, and for a week I believed it. Then I noticed how much the stillness was hiding. A slow current writes in small letters. You have to kneel to see where it has turned a leaf, or pressed the sand into ribs, or left one dark thread of faster water running under the bank.",
    "So I began to keep a list. Not of fish or birds, which other people have counted better, but of the places where the water changed its",
};

const even = [_][:0]const u8{
    "mind. There were more of them than I expected. Below the ford the river split around a bar of shingle and could not decide which side it preferred, so that on Monday the left channel carried the leaves and by Thursday the right one did.",
    "The miller's daughter told me the bar had not been there when she was small. She said it the way you might mention a neighbour who had moved in without introducing himself, and she did not seem to hold it against the river.",
    "I wrote that down too, under a heading of its own, because a list that only records water is leaving out most of what a river is.",
};

const odd = [_][:0]const u8{
    "The second week I stopped carrying the notebook to the bank and carried a stick instead, cut to the length of my arm and notched every hand's breadth, so that I could say how deep a thing was without guessing.",
    "It is surprising how quickly a measurement changes what you see. A pool I had called deep was two notches. A riffle I had stepped over without a thought was moving faster than I could walk, and had been all along.",
    "By the end of that week the stick was the most honest thing I owned, and I had begun to distrust every adjective in the earlier pages.",
};

pub const Fake = struct {
    page: u16 = book.first_page,

    pub fn service(self: *Fake) library.Library {
        return .{ .ctx = self, .ops = &.{ .reading = reading, .recent = recent, .shelf = shelf, .page = pageText, .turn = turn } };
    }

    fn from(ctx: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ctx));
    }

    fn reading(ctx: *anyopaque) library.Reading {
        const self = from(ctx);
        return .{
            .title = "A Field Guide to Quiet Rivers",
            .author = "Author D",
            .chapter = "CHAPTER 4",
            .chapter_title = "The Ford at Low Water",
            .page = self.page,
            .pages = book.pages,
            .chapter_pages_left = book.chapter_end -| self.page,
            .percent = @intCast(@as(u32, self.page) * 100 / book.pages),
        };
    }

    fn recent(_: *anyopaque) []const Entry {
        return &recent_entries;
    }

    fn shelf(_: *anyopaque) []const Entry {
        return &shelf_entries;
    }

    fn pageText(_: *anyopaque, number: u16) library.Page {
        if (number == book.first_page) return .{ .opens_chapter = true, .paragraphs = &opening };
        return .{ .opens_chapter = false, .paragraphs = if (number % 2 == 0) &even else &odd };
    }

    fn turn(ctx: *anyopaque, delta: i32) void {
        const self = from(ctx);
        const next = @as(i32, self.page) + delta;
        self.page = @intCast(@max(1, @min(next, @as(i32, book.pages))));
    }
};
