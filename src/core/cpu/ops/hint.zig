//! Hints: NOP, YIELD, WFE, WFI and SEV, in both widths, and every other
//! hint number as a NOP. The Arm ARM has the reserved hints (narrow 5 to 15,
//! wide 5 to 255) execute as NOPs, and DBG (wide 0xF0-0xFF), ESB (0x10) and
//! CSDB (0x14) change no state the core models, so they complete the same
//! way (RA8EMU-125).
//!
//! Left unclaimed: the PACBTI hint numbers (PACBTI 0x0D, BTI 0x0F, PAC
//! 0x1D, AUT 0x2D), which the PACBTI instruction group decodes, and the
//! narrow encodings with a nonzero mask field, which are IT.
//!
//! SEV sets the core's event register and WFE consumes it when it is set
//! (RA8EMU-129). WFI, and WFE with the event clear, leave the core waiting
//! (exception/sleep.zig) when it has an exception source to wake it. With
//! none, as in a lockstep step, they complete at once, which the
//! architecture allows.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

pub const encodings = struct {
    pub const nop_t1: u16 = 0xBF00;
    pub const nop_t2_hw1: u16 = 0xF3AF;
    pub const nop_t2_hw2: u16 = 0x8000;
    /// hint number 0 NOP, 1 YIELD, 2 WFE, 3 WFI, 4 SEV
    pub const wfe: u16 = 2;
    pub const wfi: u16 = 3;
    pub const sev: u16 = 4;
    /// Wide PACBTI, BTI, PAC and AUT: decoded by the PACBTI group, not here.
    /// The narrow encodings of those numbers are plain reserved hints.
    pub const pacbti_hints = [_]u16{ 0x0D, 0x0F, 0x1D, 0x2D };
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
    const number = instr.hw2 & 0xFF;
    for (e.pacbti_hints) |h| if (number == h) return null;
    return byNumber(number);
}

fn byNumber(number: u16) ?op.Exec {
    const e = encodings;
    return switch (number) {
        e.wfe => waitForEvent,
        e.wfi => waitForInterrupt,
        e.sev => sendEvent,
        else => complete,
    };
}

fn complete(cpu: *Cpu, instr: Instr) op.Error!void {
    _ = cpu;
    _ = instr;
}

/// WFE with the event register set clears it and completes; with it clear
/// the core waits for it.
fn waitForEvent(cpu: *Cpu, instr: Instr) op.Error!void {
    _ = instr;
    if (cpu.event) {
        cpu.event = false;
    } else if (cpu.source != null) {
        cpu.waiting = .event;
    }
}

fn waitForInterrupt(cpu: *Cpu, instr: Instr) op.Error!void {
    _ = instr;
    if (cpu.source != null) cpu.waiting = .interrupt;
}

fn sendEvent(cpu: *Cpu, instr: Instr) op.Error!void {
    _ = instr;
    cpu.event = true;
}
