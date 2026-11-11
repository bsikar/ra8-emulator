//! Host-free byte and state-file callbacks for `ra8_session` (ADR 0004 D20).
//! `ra8_session` never opens host directories, files, or OS paths; callers pass
//! byte slices directly or wire `ra8_host.session_files` through these hooks.
const std = @import("std");

pub const WriteStreamFn = *const fn (context: *anyopaque, writer: *std.Io.Writer) anyerror!void;

pub const ReadFn = *const fn (
    context: ?*anyopaque,
    io: std.Io,
    path: []const u8,
    allocator: std.mem.Allocator,
    max_bytes: usize,
) anyerror![]u8;

pub const WriteFn = *const fn (
    context: ?*anyopaque,
    io: std.Io,
    path: []const u8,
    stream_context: *anyopaque,
    write_stream: WriteStreamFn,
) anyerror!void;

pub const SaveStateFn = *const fn (
    context: ?*anyopaque,
    io: std.Io,
    dir: ?[]const u8,
    name: []const u8,
    stream_context: *anyopaque,
    write_stream: WriteStreamFn,
) anyerror!void;

pub const RestoreStateFn = *const fn (
    context: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: ?[]const u8,
    name: []const u8,
    max_bytes: usize,
) anyerror![]u8;

pub const Reader = struct {
    context: ?*anyopaque = null,
    readFn: ReadFn,

    pub fn readAlloc(
        self: Reader,
        io: std.Io,
        path: []const u8,
        allocator: std.mem.Allocator,
        max_bytes: usize,
    ) anyerror![]u8 {
        return self.readFn(self.context, io, path, allocator, max_bytes);
    }
};

pub const Writer = struct {
    context: ?*anyopaque = null,
    writeFn: WriteFn,

    pub fn writeStream(
        self: Writer,
        io: std.Io,
        path: []const u8,
        stream_context: *anyopaque,
        write_stream: WriteStreamFn,
    ) anyerror!void {
        return self.writeFn(self.context, io, path, stream_context, write_stream);
    }
};

pub const StateStore = struct {
    context: ?*anyopaque = null,
    saveFn: SaveStateFn,
    restoreFn: RestoreStateFn,

    pub fn save(
        self: StateStore,
        io: std.Io,
        dir: ?[]const u8,
        name: []const u8,
        stream_context: *anyopaque,
        write_stream: WriteStreamFn,
    ) anyerror!void {
        return self.saveFn(self.context, io, dir, name, stream_context, write_stream);
    }

    pub fn restore(
        self: StateStore,
        io: std.Io,
        allocator: std.mem.Allocator,
        dir: ?[]const u8,
        name: []const u8,
        max_bytes: usize,
    ) anyerror![]u8 {
        return self.restoreFn(self.context, io, allocator, dir, name, max_bytes);
    }
};

pub const Ops = struct {
    reader: Reader,
    writer: Writer,
    state: StateStore,
};
