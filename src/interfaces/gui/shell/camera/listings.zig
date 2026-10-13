//! The camera leaf's listings (RA8EMU-1123): the host's webcams and the
//! project's media, each listed once per run, the files' previews decoded
//! from the files themselves (thumb.zig), bounded to `max_listed` a kind.
//! The leaf's rows offer them; a click makes one the source a pick changes
//! to. Refreshing again is a later slice's work: clearing while a slot
//! still points into the listing would dangle it.
const std = @import("std");
const camera_barrel = @import("../../camera/camera.zig");

/// One project file a listing row offers, its decoded preview included.
pub const Listed = struct {
    name: []const u8,
    thumb: ?camera_barrel.thumb.Thumb = null,
};

/// How many files a kind's listing row offers at most.
pub const max_listed: usize = 8;

pub const Listings = struct {
    io: ?std.Io = null,
    done: bool = false,
    host_devices: ?camera_barrel.devices.Devices = null,
    media_files: ?camera_barrel.media.Media = null,
    pictures: []Listed = &.{},
    clips: []Listed = &.{},
    picture_names: []const []const u8 = &.{},
    clip_names: []const []const u8 = &.{},

    /// The host's webcams; none when the host lists none.
    pub fn devices(self: *const Listings) []const u32 {
        const d = self.host_devices orelse return &[_]u32{};
        return d.numbers;
    }

    /// Lists the host's webcams and the project's media once.
    pub fn refresh(self: *Listings, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.done = true;
        const io = self.io orelse return;
        if (camera_barrel.devices.listHost(allocator, io)) |d| {
            self.host_devices = d;
        } else |_| {}
        // The cwd's handle is AT.FDCWD, which the directory reader cannot
        // seek, so iteration opens the directory proper first.
        if (std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true })) |opened| {
            var project = opened;
            defer project.close(io);
            if (camera_barrel.media.list(allocator, io, project)) |m| {
                self.media_files = m;
                const images = m.images[0..@min(m.images.len, max_listed)];
                const videos = m.videos[0..@min(m.videos.len, max_listed)];
                self.pictures = entriesOf(allocator, io, project, images);
                self.clips = entriesOf(allocator, io, project, videos);
                self.picture_names = namesOf(allocator, images);
                self.clip_names = namesOf(allocator, videos);
            } else |_| {}
        } else |_| {}
    }

    fn clear(self: *Listings, allocator: std.mem.Allocator) void {
        for (self.pictures) |l| if (l.thumb) |t| t.deinit(allocator);
        for (self.clips) |l| if (l.thumb) |t| t.deinit(allocator);
        if (self.pictures.len > 0) allocator.free(self.pictures);
        if (self.clips.len > 0) allocator.free(self.clips);
        if (self.picture_names.len > 0) allocator.free(self.picture_names);
        if (self.clip_names.len > 0) allocator.free(self.clip_names);
        if (self.host_devices) |*d| d.deinit();
        if (self.media_files) |*m| m.deinit();
        self.pictures = &.{};
        self.clips = &.{};
        self.picture_names = &.{};
        self.clip_names = &.{};
        self.host_devices = null;
        self.media_files = null;
    }
};

/// `entries` as rows, each preview decoded from its file; failures leave
/// the entry without one.
fn entriesOf(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, entries: [][]u8) []Listed {
    const out = allocator.alloc(Listed, entries.len) catch return &.{};
    for (entries, 0..) |name, i| {
        out[i] = .{ .name = name };
        out[i].thumb = camera_barrel.thumb.load(allocator, io, dir, name) catch null;
    }
    return out;
}

/// `entries` as the row's names, aliased into the listing's own strings.
fn namesOf(allocator: std.mem.Allocator, entries: [][]u8) []const []const u8 {
    const out = allocator.alloc([]const u8, entries.len) catch return &[_][]const u8{};
    for (entries, 0..) |name, i| out[i] = name;
    return out;
}
