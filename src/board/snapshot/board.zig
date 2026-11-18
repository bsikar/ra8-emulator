//! A whole board in a snapshot (RA8EMU-688): a `part` section naming the
//! part, then every board-owned section in kind order.
//!
//! Guest memory and the cores are not board fields, so the run that owns
//! them saves them beside this (RA8EMU-660). Preparation decodes every
//! section into detached guest resources while retaining the target's wiring.
//! Only a successful preparation can commit those resources to the live board.
const chip = @import("ra8_chip");
const components = @import("ra8_components");
const rswitch = @import("rswitch.zig");
const sd = @import("sd.zig");
const storage = @import("storage.zig");
const usb = @import("usb.zig");
const wire = @import("wire.zig");
const wired = @import("wired.zig");

const std = @import("std");

const fields = @import("ra8_snapshot").fields;
const file = @import("ra8_snapshot").file;
pub const inputs = @import("inputs.zig");
pub const inventory = @import("inventory.zig");
const Part = @import("ra8_chip").core.part.Part;
const time = @import("ra8_chip").snapshot.time;

const catalog = chip.core.machine.catalog;
const Machine = chip.core.machine.Machine;
pub const Error = file.Error || fields.Error || error{ Missing, WrongPart, UnsupportedAttachments };
pub const named_part_tag: u8 = 0xFF;

/// The board-shaped sections after time, in kind order. Appending is a
/// format change.
const sections = .{
    chip.snapshot.timers,
    chip.periph.sci.snapshot,
    sd,
    wire,
    chip.periph.drw.snapshot,
    chip.periph.glcdc.snapshot,
    components.eink.snapshot,
    chip.snapshot.clocks,
    chip.snapshot.security,
    chip.snapshot.controllers,
    storage,
    chip.snapshot.signals,
    chip.snapshot.datapath,
    chip.snapshot.media,
    wired,
    chip.snapshot.channels,
    usb,
    rswitch,
    chip.periph.npu.snapshot,
    components.esp_hosted.snapshot,
};

pub fn save(board: anytype, writer: anytype) !void {
    return saveMode(board, writer, false);
}

/// The outer owner has validated and will serialize its typed attachment graph.
pub fn saveAttached(board: anytype, writer: anytype) !void {
    return saveMode(board, writer, true);
}

fn saveMode(board: anytype, writer: anytype, owned: bool) !void {
    if (!owned and board.asks.needsOwner()) return error.UnsupportedAttachments;
    comptime if (!inventory.complete(@TypeOf(board.*))) @compileError("unclassified Board snapshot field");
    try writePart(boardDesc(board), writer);
    try time.save(&board.time, writer);
    inline for (sections) |section| {
        try section.save(board, writer);
    }
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
    try machineOf(boardDesc(board), bytes);
    try time.load(&board.time, bytes);
    inline for (sections) |section| {
        try section.load(board, bytes);
    }
    const registry = try file.Reader.find(bytes, .registry) orelse return Error.Missing;
    try board.bus.loadSnapshot(registry.payload);
}

/// Every error a load can end in: this file's and each section's.
fn LoadError() type {
    comptime var all = Error || time.Error || error{OutOfMemory};
    inline for (sections) |section| {
        all = all || section.Error;
    }
    return all;
}

/// A shallow copy keeps all wiring aimed at the stable live addresses. Only
/// owned variable-size guest resources are detached and rebuilt in the copy.
pub fn Prepared(comptime B: type) type {
    return struct {
        next: *B,
        reboot: ?chip.core.reboot.Reboot = null,
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
            if (self.next.nor.inverted.len == 0 and live.nor.inverted.len == self.next.nor.capacity) {
                live.nor.clearDirtySectors();
                self.next.nor.inverted = live.nor.inverted;
                live.nor.inverted = &.{};
            }
            resourcesFree(live);
            live.* = self.next.*;
            if (self.reboot) |saved| live.reboot.?.* = saved;
            // Ownership was transferred; deinit only releases empty resources.
            resourcesDetach(self.next);
        }
    };
}

pub fn prepare(board: anytype, bytes: []const u8) !Prepared(@TypeOf(board.*)) {
    return prepareMode(board, bytes, false);
}

/// Only the outer typed attachment owner may commit this preparation.
pub fn prepareAttached(board: anytype, bytes: []const u8) !Prepared(@TypeOf(board.*)) {
    return prepareMode(board, bytes, true);
}

fn prepareMode(board: anytype, bytes: []const u8, owned: bool) !Prepared(@TypeOf(board.*)) {
    if (!owned and board.asks.needsOwner()) return error.UnsupportedAttachments;
    try machineOf(boardDesc(board), bytes);
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

pub fn boardDesc(board: anytype) *const Machine {
    const B = @TypeOf(board.*);
    if (@hasDecl(B, "desc")) return board.desc();
    return catalog.ofPart(board.part);
}

fn legacyTag(desc: *const Machine) ?u8 {
    const shipped = catalog.ofPart(desc.part);
    if (desc != shipped and !std.meta.eql(desc.*, shipped.*)) return null;
    return @backingInt(shipped.part);
}

fn writePart(desc: *const Machine, writer: anytype) !void {
    if (legacyTag(desc)) |tag| {
        try file.writeSectionHeader(writer, .part, 1);
        try writer.writeByte(tag);
        return;
    }
    if (desc.name.len == 0) return error.BadValue;
    try file.writeSectionHeader(writer, .part, 1 + desc.name.len);
    try writer.writeByte(named_part_tag);
    try writer.writeAll(desc.name);
}

/// Returns the machine name encoded in `bytes`'s `.part` section.
pub fn machineNameOf(bytes: []const u8) Error![]const u8 {
    const section = try file.Reader.find(bytes, .part) orelse return Error.Missing;
    if (section.payload.len == 0) return Error.Truncated;
    const tag = section.payload[0];
    if (tag == named_part_tag) {
        const name = section.payload[1..];
        if (name.len == 0) return Error.BadValue;
        return name;
    }
    if (section.payload.len != 1) return Error.BadValue;
    const which = std.enums.fromInt(Part, tag) orelse return Error.WrongPart;
    return catalog.ofPart(which).name;
}

/// Refuses a file without a part section or from a different machine.
pub fn machineOf(expected: *const Machine, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .part) orelse return Error.Missing;
    if (section.payload.len == 0) return Error.Truncated;
    const tag = section.payload[0];
    if (tag == named_part_tag) {
        const name = section.payload[1..];
        if (name.len == 0) return Error.BadValue;
        if (legacyTag(expected) != null or !std.mem.eql(u8, name, expected.name)) return Error.WrongPart;
        return;
    }
    if (section.payload.len != 1) return Error.BadValue;
    const wanted = legacyTag(expected) orelse return Error.WrongPart;
    if (tag != wanted) return Error.WrongPart;
}

/// Refuses a file without a part section or from a different shipped part.
pub fn partOf(expected: Part, bytes: []const u8) Error!void {
    return machineOf(catalog.ofPart(expected), bytes);
}
