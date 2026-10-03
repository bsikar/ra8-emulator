//! A stop on a floating-point system register transfer, completed and
//! resumed on the Unicorn backend (RA8EMU-342).
//!
//! The pinned Unicorn raises an exception on VLDR and VSTR of FPSCR,
//! FPCXT_NS and FPCXT_S, stopping at the instruction itself, and every CMSE
//! entry stub runs two of them. A stop like that whose instruction decodes in
//! src/core/fp_context.zig is carried out here, the base register written
//! back, and the run resumes after it. Anything else, and any transfer whose
//! memory access fails, is left to end the run exactly as before.
//!
//! The Unicorn backend runs Secure code and the Non-Secure image in one
//! security state (src/core/tz.zig enters the Non-Secure world itself), so
//! the Secure-only check the Zig core makes on FPCXT has nothing to read
//! here and is not made.
const std = @import("std");
const fault = @import("fault.zig");
const fp_context = @import("fp_context.zig");

const exception = "UC_ERR_EXCEPTION";
const general = .{ .r0, .r1, .r2, .r3, .r4, .r5, .r6, .r7, .r8, .r9, .r10, .r11, .r12, .sp, .lr };

/// Where to resume a stop that was one of these transfers, or null.
pub fn raised(core: anytype, taken: fault.Fault) !?u32 {
    if (taken.access != null) return null;
    if (std.mem.indexOf(u8, taken.detail, exception) == null) return null;
    var bytes: [fp_context.width]u8 = undefined;
    core.read(taken.pc, &bytes) catch return null;
    const transfer = fp_context.decode(
        std.mem.readInt(u16, bytes[0..2], .little),
        std.mem.readInt(u16, bytes[2..4], .little),
    ) orelse return null;

    const rn = try readGeneral(core, transfer.base);
    const at = transfer.address(rn);
    var state = fp_context.State{
        .fpscr = try core.register(.fpscr),
        .control = try core.register(.control),
    };
    const before = state;
    if (transfer.load) {
        const value = core.readWord(at) catch return null;
        fp_context.load(transfer.register, &state, value);
    } else {
        const value = fp_context.store(transfer.register, &state);
        core.writeWord(at, value) catch return null;
    }
    if (state.fpscr != before.fpscr) try core.setRegister(.fpscr, state.fpscr);
    if (state.control != before.control) try core.setRegister(.control, state.control);
    if (transfer.writeback) try writeGeneral(core, transfer.base, transfer.moved(rn));
    return taken.pc + fp_context.width;
}

fn readGeneral(core: anytype, index: u4) !u32 {
    inline for (general, 0..) |name, at| {
        if (index == at) return core.register(name);
    }
    unreachable;
}

fn writeGeneral(core: anytype, index: u4, value: u32) !void {
    inline for (general, 0..) |name, at| {
        if (index == at) return core.setRegister(name, value);
    }
    unreachable;
}
