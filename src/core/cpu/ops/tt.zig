//! TT, TTT, TTA and TTAT (T1, 0xE84n 0xFxxx) on the Zig core (RA8EMU-352).
//!
//! The decode and the response word are src/core/tt.zig's, the same ones the
//! Unicorn hook uses, so both backends answer one way. The answer comes from
//! the core's attribution source; the board's is built from the SAU the
//! firmware programmed (src/core/cpu/sau_source.zig).
//!
//! The security half is reported only from the Secure state. The MPU half
//! (MREGION, MRVALID, R, RW, and the NSR/NSRW they feed) comes from the
//! core's MPU through src/core/cpu/tt_mpu.zig (RA8EMU-276); the T bit checks
//! it unprivileged.
//!
//! Not checked against Unicorn in lockstep: its flat domain answers TT
//! from an SAU nothing programs.
const op = @import("../op.zig");
const attribution = @import("../attribution.zig");
const sysreg = @import("../sysreg.zig");
const tt_mpu = @import("../tt_mpu.zig");
const tt = @import("../../tt.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

pub const group: op.Group = .{ .name = "tt", .decode = decode, .oracle = false };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4) return null;
    _ = tt.decode(instr.hw1, instr.hw2) orelse return null;
    return testTarget;
}

fn testTarget(cpu: *Cpu, instr: Instr) op.Error!void {
    const form = tt.decode(instr.hw1, instr.hw2).?;
    const secure = cpu.banked.current == .secure;
    const target = cpu.regs.get(form.rn);
    const security = attribution.respond(cpu.attribution, target, secure);
    const privileged = sysreg.privileged(&cpu.regs);
    const view: tt_mpu.View = .{ .privileged = privileged and !form.unprivileged, .reports_region = privileged };
    const unit = if (cpu.mpu) |check| check.unit else null;
    cpu.regs.set(form.rd, tt_mpu.merge(security, tt_mpu.half(unit, target, view)));
}
