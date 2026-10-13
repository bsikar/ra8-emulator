//! What a debugger sees of the NPU (RA8EMU-948): every word a read answers
//! is computed from state and changes nothing, so a peek of one is the read
//! without the traffic count a guest read earns.
const npu = @import("npu.zig");
const lanes = @import("../lanes.zig");

/// The registry's peek for the NPU block.
pub fn thunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *const npu.Npu = @ptrCast(@alignCast(context));
    return peek(self, address, width);
}

pub fn peek(self: *const npu.Npu, address: u32, width: u3) u32 {
    const offset = address -% npu.win_base;
    if (offset >= npu.win_span) return 0;
    const aligned = offset & ~@as(u32, 3);
    const value = switch (aligned) {
        npu.off.id => npu.identity,
        npu.off.status => self.state,
        else => self.reg[offset / 4],
    };
    return lanes.part(value, offset % 4, width);
}
