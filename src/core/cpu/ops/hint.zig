//! Hints: NOP, YIELD, WFE, WFI and SEV, in both widths.
//!
//! SEV sets the core's event register and WFE consumes it when it is set
//! (RA8EMU-129). Waiting is still to come: WFI, and WFE with the event clear,
//! complete at once for now, which the architecture allows, so a loop around
//! WFI spins on the budget rather than stopping the run.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

pub const encodings = struct {
    pub const nop_t1: u16 = 0xBF00;
    pub const nop_t2_hw1: u16 = 0xF3AF;
    pub const nop_t2_hw2: u16 = 0x8000;
    /// hint number 0 NOP, 1 YIELD, 2 WFE, 3 WFI, 4 SEV
    pub const last_hint: u16 = 4;
    pub const wfe: u16 = 2;
    pub const sev: u16 = 4;
};

pub const group: op.Group = .{ .name = "hint", .decode = decode };

fn decode(instr: Instr) ?op.Exec {
    const e = encodings;
    if (instr.size == 2) {
        // 1011 1111 hint 0000: the mask field zero is what makes it a hint
        // and not an IT.
        if (instr.hw1 & 0xFF0F != e.nop_t1) return null;
        return byNumber((instr.hw1 >> 4) & 0xF);
    }
    if (instr.hw1 != e.nop_t2_hw1) return null;
    if (instr.hw2 & 0xFF00 != e.nop_t2_hw2) return null;
    return byNumber(instr.hw2 & 0xFF);
}

fn byNumber(number: u16) ?op.Exec {
    const e = encodings;
    if (number > e.last_hint) return null;
    return switch (number) {
        e.wfe => waitForEvent,
        e.sev => sendEvent,
        else => complete,
    };
}

fn complete(cpu: *Cpu, instr: Instr) op.Error!void {
    _ = cpu;
    _ = instr;
}

/// WFE with the event register set clears it and completes.
fn waitForEvent(cpu: *Cpu, instr: Instr) op.Error!void {
    _ = instr;
    cpu.event = false;
}

fn sendEvent(cpu: *Cpu, instr: Instr) op.Error!void {
    _ = instr;
    cpu.event = true;
}
