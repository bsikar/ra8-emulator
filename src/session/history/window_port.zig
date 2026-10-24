//! The machine a reverse window drives (section 2.5): what the window
//! engine needs from the session and nothing more, so the engine stays a
//! history-layer piece and the transport binds it to the live machine.
//!
//! The binding owns the replay path: `restore` puts a whole save stream
//! back and readies the recorded interventions for re-application, `step`
//! runs one slot with the session replaying (muted, recording nothing new),
//! and `saveSide`/`loadSide` move the state beside guest memory, the save
//! stream with its memory sections left out (window_delta.zig).
const std = @import("std");
const cpu_mod = @import("ra8_chip").core.cpu.cpu;
const position_mod = @import("position.zig");
const trail_mod = @import("trail.zig");

pub const Position = position_mod.Position;
pub const Core = trail_mod.Core;
pub const Cpu = cpu_mod.Cpu;

pub const Port = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The live cursor's position on the active line.
        position: *const fn (context: *anyopaque) Position,
        /// The line the machine runs on.
        line: *const fn (context: *anyopaque) u32,
        /// One core's register file, null when the core is not attached.
        cpu: *const fn (context: *anyopaque, core: Core) ?*Cpu,
        /// Runs one slot forward on `core`'s turn, replaying.
        step: *const fn (context: *anyopaque, core: Core) anyerror!void,
        /// The whole machine's save stream.
        saveFull: *const fn (context: *anyopaque, writer: *std.Io.Writer) anyerror!void,
        /// Puts a whole save stream back and readies replay from it.
        restoreFull: *const fn (context: *anyopaque, bytes: []const u8) anyerror!void,
        /// The save stream without guest memory.
        saveSide: *const fn (context: *anyopaque, writer: *std.Io.Writer) anyerror!void,
        /// Puts the state beside guest memory back; without `board` only
        /// the core and clock sections are restored.
        loadSide: *const fn (context: *anyopaque, bytes: []const u8, board: bool) anyerror!void,
    };

    pub fn position(self: Port) Position {
        return self.vtable.position(self.context);
    }

    pub fn line(self: Port) u32 {
        return self.vtable.line(self.context);
    }

    pub fn cpu(self: Port, core: Core) ?*Cpu {
        return self.vtable.cpu(self.context, core);
    }

    pub fn step(self: Port, core: Core) !void {
        return self.vtable.step(self.context, core);
    }

    pub fn saveFull(self: Port, writer: *std.Io.Writer) !void {
        return self.vtable.saveFull(self.context, writer);
    }

    pub fn restoreFull(self: Port, bytes: []const u8) !void {
        return self.vtable.restoreFull(self.context, bytes);
    }

    pub fn saveSide(self: Port, writer: *std.Io.Writer) !void {
        return self.vtable.saveSide(self.context, writer);
    }

    pub fn loadSide(self: Port, bytes: []const u8, board: bool) !void {
        return self.vtable.loadSide(self.context, bytes, board);
    }

    /// The whole machine's save stream, owned by the caller.
    pub fn fullBytes(self: Port, allocator: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try self.saveFull(&out.writer);
        return allocator.dupe(u8, out.written());
    }

    /// The side stream into `image`, replacing what it held.
    pub fn sideInto(self: Port, allocator: std.mem.Allocator, image: *std.ArrayList(u8)) !void {
        var out: std.Io.Writer.Allocating = .fromArrayList(allocator, image);
        errdefer image.* = out.toArrayList();
        out.clearRetainingCapacity();
        try self.saveSide(&out.writer);
        image.* = out.toArrayList();
    }
};
