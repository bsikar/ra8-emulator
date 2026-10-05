//! One gdb connection, served: bytes in through the packet reader, each
//! packet answered by the dispatcher, each reply framed and sent, and a
//! reply gdb asks for again (`-`) sent again.
//!
//! The connection ends on `D` (detach, answered OK), `k` (kill, which gets
//! no reply) or the other end closing. Requests are answered one at a time.
//! An interrupt (0x03) sent while a resume runs is picked up between run
//! chunks by the session's poll (src/debug/rsp_poll.zig), not here.
//! What firmware printed through ITM port 0 during a resume goes out as
//! `O` packets just before its stop reply (src/debug/rsp_console.zig).
const std = @import("std");
const packet = @import("rsp_packet.zig");
const rsp_dispatch = @import("rsp_dispatch.zig");
const console = @import("rsp_console.zig");

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
                    if (dispatch.zig) |live| {
                        if (console.resumes(request)) {
                            const port = try live.session.itmPort(live.session.currentCore());
                            try console.send(writer, port, &framed);
                        }
                    }
                    last = try packet.frame(&framed, reply);
                    try writer.writeAll(last);
                    if (detach) return .detached;
                },
            }
        }
    }
}
