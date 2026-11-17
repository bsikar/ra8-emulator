//! Read-only annotated disassembly; text uses session.disasm's canonical lines.
const proto = @import("rpc.zig");

pub const capability: u32 = 1 << 22;
pub const Request = struct { core: proto.Core, address: u32, count: u16 };
pub const Reply = struct {
    core: proto.Core,
    count: u16,
    next: u32,
    text: []const u8,
    pub const max_len = .{ .text = 32_768 };
};
