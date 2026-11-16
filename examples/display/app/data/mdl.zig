//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! What the UI asks the MDL downloader for: works to explore, the user's
//! library, search hits, one work's chapters and their sources, the download
//! queue, and the source list with its on/off switches.

pub const Work = struct {
    title: [:0]const u8,
    meta: [:0]const u8,
    on_device: bool = false,
};

pub const Hit = struct {
    title: [:0]const u8,
    by: [:0]const u8,
    availability: [:0]const u8,
};

pub const Chapter = struct {
    label: [:0]const u8,
    status: [:0]const u8,
};

pub const ChapterSource = struct {
    label: [:0]const u8,
    info: [:0]const u8,
    local: [:0]const u8,
    primary: [:0]const u8,
    secondary: [:0]const u8,
};

pub const Job = struct {
    title: [:0]const u8,
    what: [:0]const u8,
    state: [:0]const u8,
    action: [:0]const u8,
};

pub const Source = struct {
    label: [:0]const u8,
    info: [:0]const u8,
    health: [:0]const u8,
};

/// How many sources exist and how many are switched on.
pub const SourceCount = struct {
    on: u16,
    total: u16,
};

pub const Summary = struct {
    title: [:0]const u8,
    author: [:0]const u8,
    counts: [:0]const u8,
    chapter_count: u16,
    resume_label: [:0]const u8,
    page: u16,
    pages: u16,
};

pub const Mdl = struct {
    ctx: *anyopaque,
    ops: *const Ops,

    pub const Ops = struct {
        latest: *const fn (ctx: *anyopaque, popular: bool) []const Work,
        library: *const fn (ctx: *anyopaque) []const Work,
        hits: *const fn (ctx: *anyopaque) []const Hit,
        work: *const fn (ctx: *anyopaque) Summary,
        chapters: *const fn (ctx: *anyopaque) []const Chapter,
        chapterSources: *const fn (ctx: *anyopaque) []const ChapterSource,
        jobs: *const fn (ctx: *anyopaque) []const Job,
        sources: *const fn (ctx: *anyopaque) []const Source,
        sourceEnabled: *const fn (ctx: *anyopaque, index: usize) bool,
        setSourceEnabled: *const fn (ctx: *anyopaque, index: usize, enabled: bool) void,
        sourceCount: *const fn (ctx: *anyopaque) SourceCount,
        turn: *const fn (ctx: *anyopaque, delta: i32) void,
    };

    pub fn latest(self: Mdl, popular: bool) []const Work {
        return self.ops.latest(self.ctx, popular);
    }
    pub fn library(self: Mdl) []const Work {
        return self.ops.library(self.ctx);
    }
    pub fn hits(self: Mdl) []const Hit {
        return self.ops.hits(self.ctx);
    }
    pub fn work(self: Mdl) Summary {
        return self.ops.work(self.ctx);
    }
    pub fn chapters(self: Mdl) []const Chapter {
        return self.ops.chapters(self.ctx);
    }
    pub fn chapterSources(self: Mdl) []const ChapterSource {
        return self.ops.chapterSources(self.ctx);
    }
    pub fn jobs(self: Mdl) []const Job {
        return self.ops.jobs(self.ctx);
    }
    pub fn sources(self: Mdl) []const Source {
        return self.ops.sources(self.ctx);
    }
    pub fn sourceEnabled(self: Mdl, index: usize) bool {
        return self.ops.sourceEnabled(self.ctx, index);
    }
    pub fn setSourceEnabled(self: Mdl, index: usize, enabled: bool) void {
        self.ops.setSourceEnabled(self.ctx, index, enabled);
    }
    pub fn sourceCount(self: Mdl) SourceCount {
        return self.ops.sourceCount(self.ctx);
    }
    /// Move the comic page being read by `delta`, clamped to the chapter.
    pub fn turn(self: Mdl, delta: i32) void {
        self.ops.turn(self.ctx, delta);
    }
};
