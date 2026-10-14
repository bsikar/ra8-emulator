//! Who is driving a bus access: a CPU, the NPU's DMA, another bus initiator, or
//! untimed setup.
const std = @import("std");

pub const Initiator = enum(u4) {
    none,
    cpu0,
    cpu1,
    ethos_u55,
    dmac,
    dtc0,
    dtc1,
    glcdc,
    drw,
    ceu,
    eth,

    /// Every initiator the fabric tracks a timed port for, in port order.
    pub const timed = [_]Initiator{ .cpu0, .cpu1, .ethos_u55, .dmac, .dtc0, .dtc1, .glcdc, .drw, .ceu, .eth };

    /// How many timed ports the fabric tracks.
    pub const timed_count = timed.len;

    /// Which timed port this initiator's accesses are accounted on, if any.
    pub fn timedIndex(self: Initiator) ?usize {
        return switch (self) {
            .none => null,
            inline else => |one| comptime std.mem.indexOfScalar(Initiator, &timed, one).?,
        };
    }
};
