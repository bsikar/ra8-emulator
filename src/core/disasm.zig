//! One instruction, in text, for the fault path.
//!
//! When a run ends on a fault the PC alone is not much of an answer. Capstone
//! is a C library, so this is a thin Zig face over it: give it the bytes at
//! the PC and it gives back "str r1, [r0]". Only the error path uses it, so it
//! opens and closes per call rather than holding a handle open for a run that
//! may never fault.
const std = @import("std");
const c = @import("c.zig");

pub const Error = error{
    OpenFailed,
    NothingDecoded,
};

/// The longest Thumb-2 instruction is four bytes; the text of one is short.
pub const Text = struct {
    buffer: [64]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Text) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// Decode the single instruction at `address` from `bytes`.
pub fn one(address: u32, bytes: []const u8) Error!Text {
    var handle: c.cs.csh = 0;
    if (c.cs.cs_open(c.cs.CS_ARCH_ARM, c.cs.CS_MODE_THUMB | c.cs.CS_MODE_MCLASS, &handle) != c.cs.CS_ERR_OK) {
        return Error.OpenFailed;
    }
    defer _ = c.cs.cs_close(&handle);

    var insn: [*c]c.cs.cs_insn = undefined;
    const count = c.cs.cs_disasm(handle, bytes.ptr, bytes.len, address, 1, &insn);
    if (count == 0) return Error.NothingDecoded;
    defer c.cs.cs_free(insn, count);

    var text = Text{};
    const mnemonic = std.mem.sliceTo(&insn[0].mnemonic, 0);
    const operands = std.mem.sliceTo(&insn[0].op_str, 0);
    var writer = std.io.fixedBufferStream(&text.buffer);
    if (operands.len == 0) {
        writer.writer().print("{s}", .{mnemonic}) catch {};
    } else {
        writer.writer().print("{s} {s}", .{ mnemonic, operands }) catch {};
    }
    text.len = writer.pos;
    return text;
}
