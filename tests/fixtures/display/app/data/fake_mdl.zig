//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! An MDL catalogue with fixed contents, standing in for the network.

const mdl = @import("mdl.zig");

pub const chapter = struct {
    pub const first_page: u16 = 7;
    pub const pages: u16 = 18;
    pub const total_chapters: u16 = 214;
    pub const total_sources: u16 = 14;
    /// Sources past the ones listed here that are switched on.
    pub const unlisted_on: u16 = 5;
};

const latest_works = [_]mdl.Work{
    .{ .title = "Lantern Harbor", .meta = "Ch. 91 - 3 src" },
    .{ .title = "Paper Moon Courier", .meta = "Ch. 17 - 1 src" },
    .{ .title = "Iron Orchard", .meta = "Ch. 140 - 2 src" },
    .{ .title = "Tidewatch", .meta = "Ch. 63 - 4 src" },
    .{ .title = "Glass Kiln Diaries", .meta = "Ch. 8 - 1 src" },
    .{ .title = "North Signal", .meta = "Ch. 205 - 2 src" },
    .{ .title = "Hollow Bell", .meta = "Ch. 33 - 3 src" },
    .{ .title = "Saltwind Academy", .meta = "Ch. 49 - 2 src" },
};

const popular_works = [_]mdl.Work{
    .{ .title = "The Ninth Ferry", .meta = "Ch. 214 - 3 src" },
    .{ .title = "Quiet Gears", .meta = "Ch. 88 - 2 src" },
    .{ .title = "North Signal", .meta = "Ch. 205 - 2 src" },
    .{ .title = "Iron Orchard", .meta = "Ch. 140 - 2 src" },
    .{ .title = "Tidewatch", .meta = "Ch. 63 - 4 src" },
    .{ .title = "Lantern Harbor", .meta = "Ch. 91 - 3 src" },
    .{ .title = "Saltwind Academy", .meta = "Ch. 49 - 2 src" },
    .{ .title = "Hollow Bell", .meta = "Ch. 33 - 3 src" },
};

const library_works = [_]mdl.Work{
    .{ .title = "The Ninth Ferry", .meta = "3 on device", .on_device = true },
    .{ .title = "Quiet Gears", .meta = "22 on device", .on_device = true },
    .{ .title = "Iron Orchard", .meta = "1 on device", .on_device = true },
    .{ .title = "Saltwind Academy", .meta = "Needs Wi-Fi" },
    .{ .title = "Lantern Harbor", .meta = "Needs Wi-Fi" },
    .{ .title = "Tidewatch", .meta = "Needs Wi-Fi" },
    .{ .title = "Hollow Bell", .meta = "Needs Wi-Fi" },
};

const search_hits = [_]mdl.Hit{
    .{ .title = "The Ninth Ferry", .by = "Author A - English", .availability = "3 sources - 214 chapters - in Library" },
    .{ .title = "The Ninth Ferry (Colored Edition)", .by = "Author A - English", .availability = "1 source - 60 chapters" },
    .{ .title = "Ferry to Nowhere", .by = "Author B - English", .availability = "2 sources - 37 chapters" },
    .{ .title = "Ferry to No Where", .by = "Author unknown - English", .availability = "1 source - 35 chapters - may match the work above" },
};

const chapter_rows = [_]mdl.Chapter{
    .{ .label = "Chapter 214", .status = "2 sources - not on device" },
    .{ .label = "Chapter 213", .status = "3 sources - downloading from Source A" },
    .{ .label = "Chapter 212", .status = "2 sources - on device from Source A" },
    .{ .label = "Chapter 211.5 - Extra", .status = "1 source - not on device" },
    .{ .label = "Chapter 211", .status = "3 sources - on device from Source B" },
    .{ .label = "Chapter 210", .status = "2 sources - download failed" },
};

const chapter_sources = [_]mdl.ChapterSource{
    .{ .label = "Source A", .info = "English - group: Harbor Scans - 18 pages declared - 16 days ago", .local = "On this device: 18 of 18 pages, verified", .primary = "Read", .secondary = "Download again" },
    .{ .label = "Source B", .info = "English - group unknown - page count not declared - 15 days ago", .local = "Not on this device", .primary = "Stream", .secondary = "Download" },
};

const job_rows = [_]mdl.Job{
    .{ .title = "The Ninth Ferry", .what = "Chapter 213 - Source A", .state = "Downloading, about 40%", .action = "Cancel" },
    .{ .title = "The Ninth Ferry", .what = "Chapter 214 - Source A", .state = "Queued", .action = "Cancel" },
    .{ .title = "The Ninth Ferry", .what = "Chapter 210 - Source A", .state = "Failed: page 9 is not an image", .action = "Retry" },
    .{ .title = "The Ninth Ferry", .what = "Chapter 212 - Source A", .state = "Complete, 18 pages, verified", .action = "Open" },
    .{ .title = "The Ninth Ferry", .what = "Chapter 209 - Source B", .state = "Complete, 21 pages, not verifiable", .action = "Open" },
};

const source_rows = [_]mdl.Source{
    .{ .label = "Source A", .info = "Paged, long-strip - search, latest, popular", .health = "Answering" },
    .{ .label = "Source B", .info = "Paged - search, latest", .health = "Answering" },
    .{ .label = "Source C", .info = "Paged - search only", .health = "Answering" },
    .{ .label = "Source D", .info = "Paged - search only", .health = "No response today" },
    .{ .label = "Source E", .info = "Long-strip - search, latest", .health = "Answering" },
    .{ .label = "Source F", .info = "Paged - search, popular", .health = "Answering" },
    .{ .label = "Source G", .info = "Long-strip - search only", .health = "Answering" },
    .{ .label = "Source H", .info = "Paged - search, latest", .health = "Answering" },
};

pub const Fake = struct {
    page: u16 = chapter.first_page,
    enabled: [source_rows.len]bool = .{ true, true, true, true, false, true, true, true },

    pub fn service(self: *Fake) mdl.Mdl {
        return .{ .ctx = self, .ops = &.{
            .latest = latest,
            .library = library,
            .hits = hits,
            .work = work,
            .chapters = chapters,
            .chapterSources = chapterSources,
            .jobs = jobs,
            .sources = sources,
            .sourceEnabled = sourceEnabled,
            .setSourceEnabled = setSourceEnabled,
            .sourceCount = sourceCount,
            .turn = turn,
        } };
    }

    fn from(ctx: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ctx));
    }

    fn latest(_: *anyopaque, popular: bool) []const mdl.Work {
        return if (popular) &popular_works else &latest_works;
    }

    fn library(_: *anyopaque) []const mdl.Work {
        return &library_works;
    }

    fn hits(_: *anyopaque) []const mdl.Hit {
        return &search_hits;
    }

    fn work(ctx: *anyopaque) mdl.Summary {
        return .{
            .title = "The Ninth Ferry",
            .author = "Author A - English",
            .counts = "214 chapters - 3 sources - 3 on device",
            .chapter_count = chapter.total_chapters,
            .resume_label = "Continue Ch. 212",
            .page = from(ctx).page,
            .pages = chapter.pages,
        };
    }

    fn chapters(_: *anyopaque) []const mdl.Chapter {
        return &chapter_rows;
    }

    fn chapterSources(_: *anyopaque) []const mdl.ChapterSource {
        return &chapter_sources;
    }

    fn jobs(_: *anyopaque) []const mdl.Job {
        return &job_rows;
    }

    fn sources(_: *anyopaque) []const mdl.Source {
        return &source_rows;
    }

    fn sourceEnabled(ctx: *anyopaque, index: usize) bool {
        return from(ctx).enabled[index];
    }

    fn setSourceEnabled(ctx: *anyopaque, index: usize, enabled: bool) void {
        from(ctx).enabled[index] = enabled;
    }

    fn sourceCount(ctx: *anyopaque) mdl.SourceCount {
        var on: u16 = chapter.unlisted_on;
        for (from(ctx).enabled) |enabled| on += @intFromBool(enabled);
        return .{ .on = on, .total = chapter.total_sources };
    }

    fn turn(ctx: *anyopaque, delta: i32) void {
        const self = from(ctx);
        const next = @as(i32, self.page) + delta;
        self.page = @intCast(@max(1, @min(next, @as(i32, chapter.pages))));
    }
};
