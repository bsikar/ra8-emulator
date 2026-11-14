//! Stop-local DAP handles and views, rebuilt from Session on every request.
const std = @import("std");
const session = @import("ra8_session");
const p = @import("protocol.zig");
pub const Target = struct {
    session: *session.api.Session,
    images: [2]?session.symbols.Image = .{ null, null },
};
pub const Inspection = struct {
    epoch: u32 = 1,
    lines_start_at_one: bool = true,
    columns_start_at_one: bool = true,

    pub fn invalidate(self: *Inspection) !void {
        self.epoch = try std.math.add(u32, self.epoch, 1);
        if (self.epoch > 0x00ff_ffff) return error.HandleLimit;
    }

    pub fn thread(target: Target, args: p.Value) !session.api.Core {
        const id = try p.number(p.get(args, "threadId"));
        const core: session.api.Core = switch (id) {
            1 => .cpu0,
            2 => .cpu1,
            else => return error.UnknownThread,
        };
        if (!target.session.hasCore(core)) return error.UnknownThread;
        return core;
    }

    pub fn stackTrace(self: *Inspection, target: Target, args: p.Value, out: *std.Io.Writer) !void {
        const core = try thread(target, args);
        const view = try target.session.view(core);
        const image = target.images[@backingInt(core)];
        var walked: [session.unwind.limits.frames]session.unwind.Frame = undefined;
        const cfi = if (image) |loaded| session.dwarf.line.section(loaded, ".debug_frame") else &.{};
        const count = session.unwind.walk(cfi, try session.unwind.registersOf(view), try view.register(.psp), view, &walked);
        const start = optionalNumber(args, "startFrame", 0) catch return error.InvalidArguments;
        const levels = try optionalNumber(args, "levels", 0);
        const end = if (levels == 0) count else @min(count, start +| levels);
        try out.writeAll("{\"stackFrames\":[");
        for (@min(start, count)..end) |index| {
            if (index > start) try out.writeByte(',');
            const frame = walked[index];
            const pc = if (frame.exact) frame.pc else frame.pc -| 1;
            var name_buf: [32]u8 = undefined;
            const fallback = try std.fmt.bufPrint(&name_buf, "0x{X:0>8}", .{frame.pc});
            const name = if (image) |loaded| if (session.symbols.inside(loaded, pc)) |symbol| symbol.name else fallback else fallback;
            const place = session.dwarf.line.lookup(session.source.of(image), pc) catch null;
            try out.print("{{\"id\":{d},\"name\":", .{self.frameId(core, index)});
            try p.quote(out, name);
            try out.print(",\"line\":{d},\"column\":{d},\"instructionPointerReference\":\"0x{X:0>8}\"", .{ if (place) |found| found.line -| @intFromBool(!self.lines_start_at_one) else @as(u32, 0), @intFromBool(self.columns_start_at_one), frame.pc });
            if (place) |found| {
                var path: [4096]u8 = undefined;
                var writer: std.Io.Writer = .fixed(&path);
                try session.source.qualifiedPath(&writer, found.file);
                try out.writeAll(",\"source\":");
                try p.quote(out, .{ .name = std.fs.path.basename(found.file.name), .path = writer.buffered() });
            }
            try out.writeByte('}');
        }
        try out.print("],\"totalFrames\":{d}}}", .{count});
    }

    pub fn scopes(self: *Inspection, target: Target, args: p.Value, out: *std.Io.Writer) !void {
        const id = try p.number(p.get(args, "frameId"));
        const frame = try self.decode(target, id);
        // Caller registers require CFI reconstruction; never show live registers as a caller's.
        if (frame.index != 0) return out.writeAll("{\"scopes\":[]}");
        try out.print("{{\"scopes\":[{{\"name\":\"Registers\",\"presentationHint\":\"registers\",\"variablesReference\":{d},\"expensive\":false}},{{\"name\":\"Locals\",\"presentationHint\":\"locals\",\"variablesReference\":{d},\"expensive\":false}}]}}", .{ id * 2, id * 2 + 1 });
    }

    pub fn variables(self: *Inspection, target: Target, args: p.Value, out: *std.Io.Writer) !void {
        const ref = try p.number(p.get(args, "variablesReference"));
        const frame = try self.decode(target, ref / 2);
        if (frame.index != 0) return error.InvalidReference;
        try out.writeAll("{\"variables\":[");
        if (ref % 2 == 0) {
            const names = [_]session.api.Register{ .r0, .r1, .r2, .r3, .r4, .r5, .r6, .r7, .r8, .r9, .r10, .r11, .r12, .sp, .lr, .pc, .xpsr };
            for (names, 0..) |which, index| {
                if (index != 0) try out.writeByte(',');
                try variable(out, @tagName(which), "uint32", try target.session.register(frame.core, which));
            }
        } else try locals(target, frame.core, out);
        try out.writeAll("]}");
    }

    fn locals(target: Target, core: session.api.Core, out: *std.Io.Writer) !void {
        const image = target.images[@backingInt(core)] orelse return;
        var into: [64]session.dwarf.locals.Local = undefined;
        const count = try session.dwarf.locals.inFunction(session.dwarf.locals.ofImage(image), try target.session.register(core, .pc), &into);
        const view = try target.session.view(core);
        const regs = try session.unwind.registersOf(view);
        for (into[0..count], 0..) |local, index| {
            if (index != 0) try out.writeByte(',');
            try variable(out, local.name, local.type_name, localValue(view, regs, local));
        }
    }

    fn localValue(view: session.core_view.View, regs: session.unwind.Registers, local: session.dwarf.locals.Local) ?u32 {
        if (local.size == 0 or local.size > 4) return null;
        const where = local.where orelse return null;
        const address: u32 = switch (where) {
            .frame => return null, // A frame base expression is not necessarily the current SP.
            .in_register => |reg| return if (reg < regs.len) regs[reg] & (@as(u32, std.math.maxInt(u32)) >> @as(u5, @intCast((4 - local.size) * 8))) else null,
            .address => |at| at,
            .register => |reg| if (reg.reg < regs.len) regs[reg.reg] +% @as(u32, @truncate(@as(u64, @bitCast(reg.offset)))) else return null,
        };
        var bytes: [4]u8 = @splat(0);
        view.read(address, bytes[0..local.size]) catch return null;
        return std.mem.readInt(u32, &bytes, .little);
    }

    fn variable(out: *std.Io.Writer, name: []const u8, type_name: []const u8, value: ?u32) !void {
        var buf: [32]u8 = undefined;
        const shown = if (value) |v| try std.fmt.bufPrint(&buf, "0x{X:0>8}", .{v}) else "<unavailable>";
        try p.quote(out, .{ .name = name, .type = type_name, .value = shown, .variablesReference = @as(u32, 0) });
    }

    fn frameId(self: *Inspection, core: session.api.Core, index: usize) u32 {
        return self.epoch * 64 + @as(u32, @backingInt(core)) * 32 + @as(u32, @intCast(index));
    }
    const Frame = struct { core: session.api.Core, index: u32 };
    fn decode(self: *Inspection, target: Target, id: u32) !Frame {
        if (id / 64 != self.epoch) return error.InvalidReference;
        const core: session.api.Core = if (id % 64 >= 32) .cpu1 else .cpu0;
        if (!target.session.hasCore(core)) return error.UnknownThread;
        // Validate by walking again, so fabricated frame ids cannot expose data.
        const view = try target.session.view(core);
        const image = target.images[@backingInt(core)];
        const cfi = if (image) |loaded| session.dwarf.line.section(loaded, ".debug_frame") else &.{};
        var frames: [32]session.unwind.Frame = undefined;
        const count = session.unwind.walk(cfi, try session.unwind.registersOf(view), try view.register(.psp), view, &frames);
        if (id % 32 >= count) return error.InvalidReference;
        return .{ .core = core, .index = id % 32 };
    }
};

pub fn optionalNumber(args: p.Value, key: []const u8, fallback: u32) !u32 {
    const value = p.get(args, key);
    return if (value == .null) fallback else p.number(value);
}
