//! A whole board in a snapshot (RA8EMU-688): a `part` section naming the
//! part, then every board-owned section in kind order.
//!
//! Guest memory and the cores are not board fields, so the run that owns
//! them saves them beside this (RA8EMU-660). Preparation decodes every
//! section into detached guest resources while retaining the target's wiring.
//! Only a successful preparation can commit those resources to the live board.
const std = @import("std");
const file = @import("ra8_snapshot").file;
const fields = @import("ra8_snapshot").fields;
const time = @import("ra8_chip").snapshot.time;
const Part = @import("ra8_chip").core.part.Part;
pub const inputs = @import("inputs.zig");
pub const inventory = @import("inventory.zig");

pub const Error = file.Error || fields.Error || error{ Missing, WrongPart };

/// The board-shaped sections after time, in kind order. Appending is a
/// format change.
const sections = .{
    @import("ra8_chip").snapshot.timers,
    @import("ra8_chip").periph.sci.snapshot,
    @import("sd.zig"),
    @import("wire.zig"),
    @import("ra8_chip").periph.drw.snapshot,
    @import("ra8_chip").periph.glcdc.snapshot,
    @import("ra8_components").eink.snapshot,
    @import("ra8_chip").snapshot.clocks,
    @import("ra8_chip").snapshot.security,
    @import("ra8_chip").snapshot.controllers,
    @import("storage.zig"),
    @import("ra8_chip").snapshot.signals,
    @import("ra8_chip").snapshot.datapath,
    @import("ra8_chip").snapshot.media,
    @import("wired.zig"),
    @import("ra8_chip").snapshot.channels,
    @import("usb.zig"),
    @import("rswitch.zig"),
    @import("ra8_chip").periph.npu.snapshot,
    @import("ra8_components").esp_hosted.snapshot,
};

pub fn save(board: anytype, writer: anytype) !void {
    comptime if (!inventory.complete(@TypeOf(board.*))) @compileError("unclassified Board snapshot field");
    if (board.asks.count != 0) return error.UnsupportedAttachments;
    try file.writeSectionHeader(writer, .part, 1);
    try fields.write(writer, @as(u8, @backingInt(board.part)));
    try time.save(&board.time, writer);
    inline for (sections) |section| try section.save(board, writer);
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try board.bus.saveSnapshot(&counter.writer);
    try file.writeSectionHeader(writer, .registry, counter.fullCount());
    try board.bus.saveSnapshot(writer);
    try inputs.save(board, writer);
}

/// Restores every board section, leaving the live board unchanged on error.
pub fn load(board: anytype, bytes: []const u8) !void {
    var staged = try prepare(board, bytes);
    defer staged.deinit();
    staged.commit(board);
}

fn decode(board: anytype, bytes: []const u8) LoadError()!void {
    try partOf(board.part, bytes);
    try time.load(&board.time, bytes);
    inline for (sections) |section| try section.load(board, bytes);
    const registry = try file.Reader.find(bytes, .registry) orelse return Error.Missing;
    try board.bus.loadSnapshot(registry.payload);
}

/// Every error a load can end in: this file's and each section's.
fn LoadError() type {
    comptime var all = Error || time.Error || error{OutOfMemory};
    inline for (sections) |section| all = all || section.Error;
    return all;
}

/// A shallow copy keeps all wiring aimed at the stable live addresses. Only
/// owned variable-size guest resources are detached and rebuilt in the copy.
pub fn Prepared(comptime B: type) type {
    return struct {
        next: *B,
        reboot: ?@import("ra8_chip").core.reboot.Reboot = null,
        disk: []const u8 = &.{},

        pub fn deinit(self: *@This()) void {
            resourcesFree(self.next);
            std.heap.page_allocator.destroy(self.next);
        }

        pub fn commit(self: *@This(), live: *B) void {
            live.c6.wire.bridge.closeFlows();
            self.next.c6.wire.bridge = live.c6.wire.bridge;
            rebaseUsb(self.next, live);
            @memcpy(live.usb.stick.disk, self.disk);
            resourcesFree(live);
            live.* = self.next.*;
            if (self.reboot) |saved| live.reboot.?.* = saved;
            // Ownership was transferred; deinit only releases empty resources.
            resourcesDetach(self.next);
        }
    };
}

pub fn prepare(board: anytype, bytes: []const u8) !Prepared(@TypeOf(board.*)) {
    if (board.asks.count != 0) return error.UnsupportedAttachments;
    const B = @TypeOf(board.*);
    const next = try std.heap.page_allocator.create(B);
    next.* = board.*;
    resourcesDetach(next);
    var staged: Prepared(B) = .{ .next = next };
    errdefer staged.deinit();
    try decode(next, bytes);
    const loaded = try inputs.load(next, bytes);
    staged.reboot = loaded.reboot;
    staged.disk = loaded.disk;
    return staged;
}

fn resourcesDetach(board: anytype) void {
    board.sd.img.blocks = .init(board.sd.img.allocator);
    board.host_card.img.blocks = .init(board.host_card.img.allocator);
    board.options.otp.written = .init(board.options.otp.written.allocator);
    board.nor.inverted = &.{};
    board.nor.dirty = &.{};
    board.panel.planes.image = .{};
    board.panel.planes.glass = .{};
    board.bus.cells = .init(board.bus.cells.allocator);
    board.c6.wire.bridge = .{};
}

fn resourcesFree(board: anytype) void {
    board.sd.deinit();
    board.host_card.deinit();
    board.options.deinit();
    board.nor.deinit();
    board.panel.planes.deinit();
    board.bus.cells.deinit();
}

fn rebaseUsb(next: anytype, live: anytype) void {
    const data = next.usb.stick.data;
    if (data.len == 0) return;
    const at = @intFromPtr(data.ptr);
    const lo = @intFromPtr(&next.usb.stick.scratch);
    if (at >= lo and at - lo < next.usb.stick.scratch.len) {
        next.usb.stick.data = live.usb.stick.scratch[at - lo ..][0..data.len];
    }
}

/// Refuses a file without a part section or from a different part.
pub fn partOf(expected: Part, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .part) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    const tag = try fields.read(u8, &cursor);
    if (!cursor.done()) return Error.BadValue;
    if (tag != @backingInt(expected)) return Error.WrongPart;
}
