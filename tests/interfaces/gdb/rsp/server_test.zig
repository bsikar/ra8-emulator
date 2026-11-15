//! One connection served over in-memory streams: acknowledgements,
//! framing, a resend on request, a corrupt packet refused, and the ways a
//! connection ends.
const std = @import("std");
const ra8 = @import("ra8");

const dispatch = ra8.gdb.rsp.dispatch;
const packet = ra8.gdb.rsp.packet;
const server = dispatch.server;
const memmap = ra8.chip.core.memmap;
const Rig = @import("../../../session/view_ram.zig").Rig;

fn open(rig: *Rig) !void {
    rig.wire();
    try rig.view().write(memmap.sram_base, &[_]u8{ 0xca, 0xfe });
}

/// `payloads` framed the way gdb sends them, with `extra` after.
fn wire(buffer: []u8, payloads: []const []const u8, extra: []const u8) ![]const u8 {
    var at: usize = 0;
    for (payloads) |payload| at += (try packet.frame(buffer[at..], payload)).len;
    @memcpy(buffer[at..][0..extra.len], extra);
    return buffer[0 .. at + extra.len];
}

fn play(rig: *Rig, input: []const u8, sent: *std.Io.Writer.Allocating) !server.End {
    var reader: std.Io.Reader = .fixed(input);
    return server.serve(.{ .view = rig.view() }, &reader, &sent.writer);
}

// Each packet is acknowledged and answered, and D ends the connection.
test "packets are acknowledged and answered until detach" {
    var rig: Rig = .{};
    try open(&rig);
    var buffer: [128]u8 = undefined;
    const input = try wire(&buffer, &.{ "m22000000,2", "D" }, "");
    var sent: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent.deinit();
    try std.testing.expectEqual(server.End.detached, try play(&rig, input, &sent));
    try std.testing.expectEqualStrings("+$cafe#8f+$OK#9a", sent.written());
}

// A `-` gets the last reply again; a bad checksum gets `-`; k ends silently.
test "resend, a corrupt packet, and kill" {
    var rig: Rig = .{};
    try open(&rig);
    var buffer: [128]u8 = undefined;
    const input = try wire(&buffer, &.{"qAttached"}, "-$m0,1#00$k#6b");
    var sent: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent.deinit();
    try std.testing.expectEqual(server.End.killed, try play(&rig, input, &sent));
    try std.testing.expectEqualStrings("+$1#31$1#31-+", sent.written());
}

// The stream running dry ends the connection as closed.
test "the other end closing" {
    var rig: Rig = .{};
    try open(&rig);
    var sent: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent.deinit();
    try std.testing.expectEqual(server.End.closed, try play(&rig, "+", &sent));
    try std.testing.expectEqual(@as(usize, 0), sent.written().len);
}

const FlushProbe = struct {
    writer: std.Io.Writer,
    sent_ack: bool = false,
    observed_during_run: bool = false,

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FlushProbe = @fieldParentPtr("writer", writer);
        if (std.mem.indexOfScalar(u8, writer.buffered(), packet.ack) != null) self.sent_ack = true;
        writer.end = 0;
        var consumed = data[data.len - 1].len * splat;
        for (data[0 .. data.len - 1]) |part| consumed += part.len;
        return consumed;
    }
    fn check(context: *anyopaque) bool {
        const self: *FlushProbe = @ptrCast(@alignCast(context));
        self.observed_during_run = self.sent_ack;
        return true;
    }
    fn now(_: *anyopaque) u64 {
        return 0;
    }
};

test "a resume ACK reaches the client before execution asks for an interrupt" {
    var rig: Rig = .{};
    rig.wire();
    try rig.view().write(memmap.sram_base, &.{ 0xFE, 0xE7 });
    try rig.view().setRegister(.pc, memmap.sram_base);
    try rig.view().setRegister(.xpsr, ra8.chip.core.cpu.regs.xpsr_bits.thumb);
    var machine: ra8.session.stop_machine.Machine = .{};
    var live: ra8.session.api.Session = .{ .live = .{ .core = .{ .cpu = &rig.cpu }, .machine = &machine, .budget = 8 } };
    var out: [256]u8 = undefined;
    var probe: FlushProbe = .{ .writer = .{ .buffer = &out, .vtable = &.{ .drain = FlushProbe.drain } } };
    var target: dispatch.zig_run.Target = .{
        .session = &live,
        .poll = .{ .context = &probe, .check = FlushProbe.check },
        .wall = .{ .context = &probe, .nowFn = FlushProbe.now },
    };
    var input: [64]u8 = undefined;
    var reader: std.Io.Reader = .fixed(try wire(&input, &.{ "c", "D" }, ""));
    try std.testing.expectEqual(server.End.detached, try server.serve(.{ .zig = &target }, &reader, &probe.writer));
    try std.testing.expect(probe.observed_during_run);
}
