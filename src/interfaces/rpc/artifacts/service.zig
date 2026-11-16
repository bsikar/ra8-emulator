//! Application-owned session slot. Prepared imports switch only after the reply is sent.
const std = @import("std");

const board = @import("ra8_board");
const bundle = @import("ra8_snapshot").bundle;
const capture = @import("capture.zig");
const importer = @import("../bundle/import.zig");
const setup = @import("../served_setup.zig");
const Spool = @import("spool.zig").Spool;

pub const Options = struct {
    enabled: bool = true,
    profile: []const u8 = board.profile.ek_ra8d2,
    context: ?*anyopaque = null,
    prepareFn: ?*const fn (?*anyopaque, *setup.Served) anyerror!void = null,
};

pub const Service = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    initial: *setup.Served,
    active: *setup.Served,
    spool: *Spool,
    options: Options,
    pending: ?*setup.Served = null,
    next: u64 = 1,

    /// Takes ownership of initial only on success; initial's struct remains caller-owned.
    pub fn open(
        gpa: std.mem.Allocator,
        io: std.Io,
        initial: *setup.Served,
        path: []const u8,
        options: Options,
    ) !*Service {
        const self = try gpa.create(Service);
        errdefer gpa.destroy(self);
        const spool = try Spool.open(gpa, io, path);
        self.* = .{ .gpa = gpa, .io = io, .initial = initial, .active = initial, .spool = spool, .options = options };
        if (options.enabled) initial.context.artifacts = self;
        return self;
    }

    pub fn close(self: *Service) !void {
        const gpa = self.gpa;
        defer gpa.destroy(self);
        self.discardPending();
        self.active.deinit();
        if (self.active != self.initial) gpa.destroy(self.active);
        try self.spool.close();
    }

    pub fn id(self: *Service) !u64 {
        if (self.next == std.math.maxInt(u64)) return error.IdExhausted;
        const result = self.next;
        self.next += 1;
        return result;
    }

    pub fn prepare(self: *Service, file: std.Io.File) !void {
        if (self.pending != null) return error.SessionBusy;
        try capture.quiet(self.active);
        try self.active.flushHistory();
        const first = self.active.owner.loadedImage(.cpu0) orelse return error.NoImage;
        const second = self.active.owner.loadedImage(.cpu1);
        const root = self.active.owner.session().root;
        var buffer: [65536]u8 = undefined;
        var reader = file.reader(self.io, &buffer);
        const profile = if (try isRecording(self.gpa, self.io, file))
            null
        else if (root) |value|
            value.board_profile
        else
            self.options.profile;
        const candidate = try importer.open(self.gpa, self.io, &reader.interface, .{
            .history_root = self.spool.base.path,
            .elf0 = first.bytes,
            .elf1 = if (second) |value| value.bytes else null,
            .board_profile = profile,
        });
        errdefer {
            candidate.deinit();
            self.gpa.destroy(candidate);
        }
        if (self.options.prepareFn) |prepareFn| try prepareFn(self.options.context, candidate);
        if (self.options.enabled) candidate.context.artifacts = self;
        self.pending = candidate;
    }

    pub fn discardPending(self: *Service) void {
        if (self.pending) |candidate| {
            candidate.deinit();
            self.gpa.destroy(candidate);
            self.pending = null;
        }
    }

    /// Call after dropping the old connection's borrowed hooks and reply buffers.
    pub fn activate(self: *Service) void {
        const next = self.pending orelse return;
        self.pending = null;
        const old = self.active;
        self.active = next;
        old.deinit();
        if (old != self.initial) self.gpa.destroy(old);
    }
};

fn isRecording(gpa: std.mem.Allocator, io: std.Io, file: std.Io.File) !bool {
    var buffer: [8192]u8 = undefined;
    var source = file.reader(io, &buffer);
    var reader = try bundle.reader.Reader.init(gpa, &source.interface, .{});
    defer reader.deinit();
    return reader.metadata.value.recording;
}
