//! The intervention record body a Session action is logged with, and the
//! decode the replay feeder re-applies it from (time-travel design section 11).
//!
//! Every body carries what replay needs to apply the action exactly as it
//! was applied live: the core it was aimed at, an input's virtual time, a
//! plug's or fault's endpoint and a fault's mode. Endpoints and modes cross
//! as their own text forms, the ones `--attach` and `--fault` read, so the
//! component parsers stay the only judges of what they mean.
//!
//! Console keystrokes and a camera change act on the board, not on a core,
//! so their bodies are the bytes alone and decode on CPU0.
const std = @import("std");
const record_mod = @import("record.zig");
const fork_router_mod = @import("fork_router.zig");
const core_view = @import("../core_view.zig");
const input_script = @import("ra8_components").input_script;
const endpoint = @import("ra8_components").endpoint;
const fault_spec = @import("ra8_components").fault.spec;

pub const Action = fork_router_mod.Action;
pub const What = record_mod.Intervention.What;
pub const Core = fork_router_mod.Core;
pub const Error = error{ Truncated, BadValue } || std.mem.Allocator.Error;

pub const EncodedAction = struct {
    what: What,
    body: []const u8,
};

/// The longest endpoint or mode text a body carries.
const max_text: usize = 32;

/// Encodes a Session action into an intervention record body.
pub fn encode(allocator: std.mem.Allocator, action: Action) !EncodedAction {
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 32);
    errdefer out.deinit();
    const w = &out.writer;
    const what: What = switch (action) {
        .register => |reg| blk: {
            try w.writeByte(@backingInt(reg.core));
            try w.writeInt(u32, @backingInt(reg.which), .little);
            try w.writeInt(u32, reg.value, .little);
            break :blk .register_write;
        },
        .memory => |mem| blk: {
            try w.writeByte(@backingInt(mem.core));
            try w.writeInt(u32, mem.address, .little);
            try w.writeAll(mem.bytes);
            break :blk .memory_write;
        },
        .input => |inp| blk: {
            try w.writeByte(@backingInt(inp.core));
            try w.writeInt(u64, inp.at_ns, .little);
            try input_script.encodeBody(w, inp.event);
            break :blk if (inp.event == .button) .button else .tap;
        },
        .console => |con| blk: {
            try w.writeAll(con.bytes);
            break :blk .keystroke;
        },
        .plug => |p| blk: {
            try w.writeByte(@backingInt(p.core));
            try writeText(w, p.at, Endpoint.write);
            if (p.name) |name| try w.writeAll(name);
            break :blk if (p.name != null) .plug else .unplug;
        },
        .fault => |f| blk: {
            try w.writeByte(@backingInt(f.core));
            try writeText(w, f.at, Endpoint.write);
            if (f.mode) |mode| try writeText(w, mode, writeMode);
            break :blk .fault;
        },
        .camera => |cam| blk: {
            try w.writeAll(cam.spec);
            break :blk .camera_change;
        },
        .skip_bkpt => |sk| blk: {
            try w.writeByte(@backingInt(sk.core));
            break :blk .skip_bkpt;
        },
        .load => |ld| blk: {
            try w.writeByte(@backingInt(ld.core));
            try w.writeAll(ld.image);
            break :blk .load;
        },
    };
    return .{ .what = what, .body = try out.toOwnedSlice() };
}

/// Frees memory allocated by encode.
pub fn free(allocator: std.mem.Allocator, encoded: *EncodedAction) void {
    allocator.free(encoded.body);
    encoded.* = undefined;
}

/// Decodes an intervention record body back into the action it logged.
/// Byte payloads are duplicated into `allocator`; fork_router.freeAction
/// releases them.
pub fn decode(allocator: std.mem.Allocator, what: What, body: []const u8) !Action {
    var r: Reader = .{ .body = body };
    switch (what) {
        .register_write => {
            const core = try r.core();
            const raw = try r.int(u32);
            const value = try r.int(u32);
            if (raw > std.math.maxInt(u6)) return Error.BadValue;
            const which = std.enums.fromInt(core_view.Cortex, @as(u6, @intCast(raw))) orelse return Error.BadValue;
            return .{ .register = .{ .core = core, .which = which, .value = value } };
        },
        .memory_write => {
            const core = try r.core();
            const address = try r.int(u32);
            return .{ .memory = .{ .core = core, .address = address, .bytes = try allocator.dupe(u8, r.rest()) } };
        },
        .tap, .button => {
            const core = try r.core();
            const at_ns = try r.int(u64);
            const event = input_script.decodeBody(r.rest()) catch return Error.BadValue;
            return .{ .input = .{ .core = core, .at_ns = at_ns, .event = event } };
        },
        .keystroke => return .{ .console = .{ .core = .cpu0, .bytes = try allocator.dupe(u8, body) } },
        .camera_change => return .{ .camera = .{ .core = .cpu0, .spec = try allocator.dupe(u8, body) } },
        .plug, .unplug => {
            const core = try r.core();
            const at = endpoint.parse(try r.text()) catch return Error.BadValue;
            const name: ?[]const u8 = if (what == .plug) try allocator.dupe(u8, r.rest()) else null;
            return .{ .plug = .{ .core = core, .at = at, .name = name } };
        },
        .fault => {
            const core = try r.core();
            const at = endpoint.parse(try r.text()) catch return Error.BadValue;
            const mode: ?fault_spec.Mode = if (r.done()) null else fault_spec.parseMode(try r.text()) catch return Error.BadValue;
            return .{ .fault = .{ .core = core, .at = at, .mode = mode } };
        },
        .skip_bkpt => return .{ .skip_bkpt = .{ .core = try r.core() } },
        .load => {
            const core = try r.core();
            return .{ .load = .{ .core = core, .image = try allocator.dupe(u8, r.rest()) } };
        },
        else => return Error.BadValue,
    }
}

const Endpoint = endpoint.Endpoint;

/// A length-prefixed text field, written through the type's own printer.
fn writeText(w: *std.Io.Writer, value: anytype, comptime print: anytype) !void {
    var buf: [max_text]u8 = undefined;
    var text: std.Io.Writer = .fixed(&buf);
    try print(value, &text);
    try w.writeByte(@intCast(text.buffered().len));
    try w.writeAll(text.buffered());
}

/// A fault mode in the text form fault.spec.parseMode reads back.
pub fn writeMode(mode: fault_spec.Mode, out: *std.Io.Writer) !void {
    switch (mode) {
        .disconnected => try out.writeAll("disconnected"),
        .bus_low => try out.writeAll("bus_low"),
        .nack_every => |n| try out.print("nack:{d}", .{n}),
        .stuck => |b| try out.print("stuck:0x{X:0>2}", .{b}),
        .garbage => |seed| try out.print("garbage:{d}", .{seed}),
        .slow_ns => |ns| try out.print("slow:{d}", .{ns}),
        .stretch_ns => |ns| try out.print("stretch:{d}", .{ns}),
    }
}

const Reader = struct {
    body: []const u8,
    at: usize = 0,

    fn done(self: *const Reader) bool {
        return self.at == self.body.len;
    }

    fn rest(self: *Reader) []const u8 {
        defer self.at = self.body.len;
        return self.body[self.at..];
    }

    fn int(self: *Reader, comptime T: type) Error!T {
        const span = @sizeOf(T);
        if (self.body.len - self.at < span) return Error.Truncated;
        defer self.at += span;
        return std.mem.readInt(T, self.body[self.at..][0..span], .little);
    }

    fn core(self: *Reader) Error!Core {
        const raw = try self.int(u8);
        if (raw > 1) return Error.BadValue;
        return if (raw == 0) .cpu0 else .cpu1;
    }

    fn text(self: *Reader) Error![]const u8 {
        const len = try self.int(u8);
        if (self.body.len - self.at < len) return Error.Truncated;
        defer self.at += len;
        return self.body[self.at..][0..len];
    }
};
