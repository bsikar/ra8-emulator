//! One gdb connection, served: bytes in through the packet reader, each
//! packet answered by the dispatcher, each reply framed and sent, and a
//! reply gdb asks for again (`-`) sent again.
//!
//! The connection ends on `D` (detach, answered OK), `k` (kill, which gets
//! no reply) or the other end closing. Requests are answered one at a time,
//! so an interrupt (0x03) sent while a resume runs is read after it stops.
const std = @import("std");
const packet = @import("rsp_packet.zig");
const rsp_dispatch = @import("rsp_dispatch.zig");

pub const limits = struct {
    /// Bytes taken from the connection per read.
    pub const chunk: usize = 512;
    /// A framed reply: every payload byte escaped, plus `$`, `#` and the sum.
    pub const framed: usize = rsp_dispatch.packet_size * 2 + 4;
};

/// How the connection ended.
pub const End = enum { detached, killed, closed };

/// Serve one connection until it ends.
pub fn serve(dispatch: rsp_dispatch.Dispatch, reader: anytype, writer: anytype) !End {
    var incoming: [rsp_dispatch.packet_size]u8 = undefined;
    var wire = packet.Reader.init(&incoming);
    var payload: [rsp_dispatch.packet_size]u8 = undefined;
    var framed: [limits.framed]u8 = undefined;
    var last: []const u8 = &.{};
    var chunk: [limits.chunk]u8 = undefined;
    while (true) {
        const count = try reader.read(&chunk);
        if (count == 0) return .closed;
        for (chunk[0..count]) |byte| {
            const event = wire.push(byte) orelse continue;
            switch (event) {
                .ack, .interrupt => {},
                .resend => try writer.writeAll(last),
                .corrupt, .overflow => try writer.writeByte(packet.resend),
                .packet => |request| {
                    try writer.writeByte(packet.ack);
                    if (std.mem.eql(u8, request, "k")) return .killed;
                    const detach = request.len > 0 and request[0] == 'D';
                    const reply = if (detach) "OK" else try dispatch.answer(request, &payload);
                    last = try packet.frame(&framed, reply);
                    try writer.writeAll(last);
                    if (detach) return .detached;
                },
            }
        }
    }
}
