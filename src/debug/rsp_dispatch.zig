//! What a remote-protocol packet asks of the machine, answered as the
//! payload the stub sends back (framing is rsp_packet.zig's job).
//!
//! This is the read side: the halt reason, what the stub supports, the
//! target description, all registers, one register and a span of memory.
//! A request it does not know gets the empty reply, which is how the
//! protocol says "not supported" and lets gdb fall back.
const std = @import("std");
const engine = @import("../core/engine.zig");
const features = @import("rsp_features.zig");

pub const Error = error{NoSpace};

/// The `g` order, which is target.xml's order: r0 to r12, sp, lr, pc, xpsr.
pub const registers = [_]engine.Cortex{
    .r0, .r1,  .r2,  .r3,  .r4, .r5, .r6, .r7,   .r8,
    .r9, .r10, .r11, .r12, .sp, .lr, .pc, .xpsr,
};

/// The largest packet the stub reads, in bytes, as qSupported tells gdb.
pub const packet_size: usize = 0x1000;

/// gdb's SIGTRAP: the machine stopped where the debugger asked it to.
pub const halted = "S05";

const supported = std.fmt.comptimePrint("PacketSize={x};qXfer:features:read+", .{packet_size});
const xfer = "qXfer:features:read:";
const memory_error = "E01";
const request_error = "E00";

pub const Dispatch = struct {
    core: *const engine.Engine,

    /// The reply payload for `request`, written into `out`.
    pub fn answer(self: Dispatch, request: []const u8, out: []u8) Error![]const u8 {
        if (request.len == 0) return out[0..0];
        if (std.mem.startsWith(u8, request, "qSupported")) return copy(out, supported);
        if (std.mem.startsWith(u8, request, xfer)) return features.read(request[xfer.len..], out);
        if (std.mem.eql(u8, request, "qAttached")) return copy(out, "1");
        return switch (request[0]) {
            '?' => copy(out, halted),
            'g' => self.allRegisters(out),
            'p' => self.oneRegister(request[1..], out),
            'm' => self.memory(request[1..], out),
            'H' => copy(out, "OK"),
            else => out[0..0],
        };
    }

    fn allRegisters(self: Dispatch, out: []u8) Error![]const u8 {
        var at: usize = 0;
        for (registers) |which| {
            const value = self.core.register(which) catch return copy(out, request_error);
            try word(out, &at, value);
        }
        return out[0..at];
    }

    fn oneRegister(self: Dispatch, args: []const u8, out: []u8) Error![]const u8 {
        const index = std.fmt.parseInt(usize, args, 16) catch return copy(out, request_error);
        if (index >= registers.len) return copy(out, request_error);
        const value = self.core.register(registers[index]) catch return copy(out, request_error);
        var at: usize = 0;
        try word(out, &at, value);
        return out[0..at];
    }

    fn memory(self: Dispatch, args: []const u8, out: []u8) Error![]const u8 {
        const comma = std.mem.indexOfScalar(u8, args, ',') orelse return copy(out, request_error);
        const address = std.fmt.parseInt(u32, args[0..comma], 16) catch return copy(out, request_error);
        const length = std.fmt.parseInt(usize, args[comma + 1 ..], 16) catch return copy(out, request_error);
        if (length * 2 > out.len) return error.NoSpace;
        var at: usize = 0;
        var chunk: [64]u8 = undefined;
        var done: usize = 0;
        while (done < length) {
            const take = @min(chunk.len, length - done);
            const where = address +% @as(u32, @intCast(done));
            self.core.read(where, chunk[0..take]) catch return copy(out, memory_error);
            for (chunk[0..take]) |byte| try hexByte(out, &at, byte);
            done += take;
        }
        return out[0..at];
    }
};

/// A register as gdb wants it: the four bytes in target (little-endian)
/// order, two hex digits each.
fn word(out: []u8, at: *usize, value: u32) Error!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    for (bytes) |byte| try hexByte(out, at, byte);
}

fn hexByte(out: []u8, at: *usize, byte: u8) Error!void {
    if (at.* + 2 > out.len) return error.NoSpace;
    const digits = std.fmt.hex(byte);
    out[at.*] = digits[0];
    out[at.* + 1] = digits[1];
    at.* += 2;
}

fn copy(out: []u8, text: []const u8) Error![]const u8 {
    if (out.len < text.len) return error.NoSpace;
    @memcpy(out[0..text.len], text);
    return out[0..text.len];
}
