//! Complete architectural register state capture and slot representation (Section 4).
//!
//! Captures the Armv8-M CPU's complete architectural core state:
//! - Core register file (r0-r12, msp, psp, lr, pc, xpsr, control, primask,
//!   basepri, faultmask, msplim, psplim, low marks, pac keys, returns)
//! - Floating-point state (s0-s31, fpscr, vpr, fpccr, fpcar, fpdscr, cpacr)
//! - Banked security state (current mode, other msp/psp/limits/masks/control)
//! - Exclusive monitor and event register
//!
//! Stores compact deltas per slot (only modified fields), with symmetric
//! in-place swap enabling exact undo and redo.
const std = @import("std");
const cpu_mod = @import("ra8_chip").core.cpu.cpu;
const regs_mod = @import("ra8_chip").core.cpu.regs;
const fp_state = @import("ra8_chip").core.cpu.fpu.state;
const banked_mod = @import("ra8_chip").core.banked;
const position_mod = @import("ra8_chip").core.scheduler.position;
const trail_mod = @import("trail.zig");

pub const Position = position_mod.Position;
pub const Core = trail_mod.Core;

pub const SlotKind = enum(u8) {
    ram_cpu = 0,
    complex = 1,
    board_tick = 2,
    barrier = 3,
};

pub const RegTag = enum(u8) {
    r0 = 0,
    r1,
    r2,
    r3,
    r4,
    r5,
    r6,
    r7,
    r8,
    r9,
    r10,
    r11,
    r12,
    msp,
    psp,
    lr,
    pc,
    xpsr,
    control,
    primask,
    basepri,
    faultmask,
    msplim,
    psplim,
    low_msp,
    low_psp,
    pac_key_p0,
    pac_key_p1,
    pac_key_p2,
    pac_key_p3,
    pac_key_u0,
    pac_key_u1,
    pac_key_u2,
    pac_key_u3,
    exc_return,
    fnc_return,
    s0,
    s1,
    s2,
    s3,
    s4,
    s5,
    s6,
    s7,
    s8,
    s9,
    s10,
    s11,
    s12,
    s13,
    s14,
    s15,
    s16,
    s17,
    s18,
    s19,
    s20,
    s21,
    s22,
    s23,
    s24,
    s25,
    s26,
    s27,
    s28,
    s29,
    s30,
    s31,
    fpscr,
    vpr,
    fpccr,
    fpcar,
    fpdscr,
    cpacr,
    banked_current,
    banked_other_msp,
    banked_other_psp,
    banked_other_msplim,
    banked_other_psplim,
    banked_other_primask,
    banked_other_basepri,
    banked_other_faultmask,
    banked_other_control,
    banked_other_low_msp,
    banked_other_low_psp,
    exclusive,
    event,
};

pub const reg_tag_count: usize = @typeInfo(RegTag).@"enum".field_names.len;

pub const RegDiff = struct {
    tag: RegTag,
    pre_valid: bool = true,
    post_valid: bool = true,
    pre: u32 = 0,
    post: u32 = 0,

    pub fn swap(self: *RegDiff) void {
        std.mem.swap(u32, &self.pre, &self.post);
        std.mem.swap(bool, &self.pre_valid, &self.post_valid);
    }
};

pub const ArchState = struct {
    regs: regs_mod.Regs = .{},
    fp: fp_state.State = .{},
    banked: banked_mod.Banked = .{},
    exclusive: ?u32 = null,
    event: bool = false,

    pub fn capture(cpu: *const cpu_mod.Cpu) ArchState {
        return .{
            .regs = cpu.regs,
            .fp = cpu.fp,
            .banked = cpu.banked,
            .exclusive = cpu.exclusive,
            .event = cpu.event,
        };
    }

    pub fn restore(self: ArchState, cpu: *cpu_mod.Cpu) void {
        cpu.regs = self.regs;
        cpu.fp = self.fp;
        cpu.banked = self.banked;
        cpu.exclusive = self.exclusive;
        cpu.event = self.event;
    }

    pub fn readField(self: *const ArchState, tag: RegTag, val: *u32, valid: *bool) void {
        val.* = 0;
        valid.* = true;
        const n = @backingInt(tag);
        if (n <= 12) {
            val.* = self.regs.low[n];
        } else if (n >= @backingInt(RegTag.s0) and n <= @backingInt(RegTag.s31)) {
            val.* = self.fp.bank.s[n - @backingInt(RegTag.s0)];
        } else switch (tag) {
            .msp => val.* = self.regs.msp,
            .psp => val.* = self.regs.psp,
            .lr => val.* = self.regs.lr,
            .pc => val.* = self.regs.pc,
            .xpsr => val.* = self.regs.xpsr,
            .control => val.* = self.regs.control,
            .primask => val.* = self.regs.primask,
            .basepri => val.* = self.regs.basepri,
            .faultmask => val.* = self.regs.faultmask,
            .msplim => val.* = self.regs.msplim,
            .psplim => val.* = self.regs.psplim,
            .low_msp => val.* = self.regs.low_msp,
            .low_psp => val.* = self.regs.low_psp,
            .pac_key_p0 => val.* = self.regs.pac_key_p[0],
            .pac_key_p1 => val.* = self.regs.pac_key_p[1],
            .pac_key_p2 => val.* = self.regs.pac_key_p[2],
            .pac_key_p3 => val.* = self.regs.pac_key_p[3],
            .pac_key_u0 => val.* = self.regs.pac_key_u[0],
            .pac_key_u1 => val.* = self.regs.pac_key_u[1],
            .pac_key_u2 => val.* = self.regs.pac_key_u[2],
            .pac_key_u3 => val.* = self.regs.pac_key_u[3],
            .exc_return => {
                if (self.regs.exc_return) |v| {
                    val.* = v;
                } else {
                    valid.* = false;
                }
            },
            .fnc_return => {
                if (self.regs.fnc_return) |v| {
                    val.* = v;
                } else {
                    valid.* = false;
                }
            },
            .fpscr => val.* = @bitCast(self.fp.fpscr),
            .vpr => val.* = @bitCast(self.fp.vpr),
            .fpccr => val.* = @bitCast(self.fp.context.fpccr),
            .fpcar => val.* = self.fp.context.fpcar,
            .fpdscr => val.* = self.fp.context.fpdscr,
            .cpacr => val.* = self.fp.cpacr,
            .banked_current => val.* = @backingInt(self.banked.current),
            .banked_other_msp => val.* = self.banked.other.msp,
            .banked_other_psp => val.* = self.banked.other.psp,
            .banked_other_msplim => val.* = self.banked.other.msplim,
            .banked_other_psplim => val.* = self.banked.other.psplim,
            .banked_other_primask => val.* = self.banked.other.primask,
            .banked_other_basepri => val.* = self.banked.other.basepri,
            .banked_other_faultmask => val.* = self.banked.other.faultmask,
            .banked_other_control => val.* = self.banked.other.control,
            .banked_other_low_msp => val.* = self.banked.other.low_msp,
            .banked_other_low_psp => val.* = self.banked.other.low_psp,
            .exclusive => {
                if (self.exclusive) |v| {
                    val.* = v;
                } else {
                    valid.* = false;
                }
            },
            .event => val.* = @intFromBool(self.event),
            else => unreachable,
        }
    }

    pub fn writeField(self: *ArchState, tag: RegTag, val: u32, valid: bool) void {
        const n = @backingInt(tag);
        if (n <= 12) {
            self.regs.low[n] = val;
        } else if (n >= @backingInt(RegTag.s0) and n <= @backingInt(RegTag.s31)) {
            self.fp.bank.s[n - @backingInt(RegTag.s0)] = val;
        } else switch (tag) {
            .msp => self.regs.msp = val,
            .psp => self.regs.psp = val,
            .lr => self.regs.lr = val,
            .pc => self.regs.pc = val,
            .xpsr => self.regs.xpsr = val,
            .control => self.regs.control = val,
            .primask => self.regs.primask = val,
            .basepri => self.regs.basepri = val,
            .faultmask => self.regs.faultmask = val,
            .msplim => self.regs.msplim = val,
            .psplim => self.regs.psplim = val,
            .low_msp => self.regs.low_msp = val,
            .low_psp => self.regs.low_psp = val,
            .pac_key_p0 => self.regs.pac_key_p[0] = val,
            .pac_key_p1 => self.regs.pac_key_p[1] = val,
            .pac_key_p2 => self.regs.pac_key_p[2] = val,
            .pac_key_p3 => self.regs.pac_key_p[3] = val,
            .pac_key_u0 => self.regs.pac_key_u[0] = val,
            .pac_key_u1 => self.regs.pac_key_u[1] = val,
            .pac_key_u2 => self.regs.pac_key_u[2] = val,
            .pac_key_u3 => self.regs.pac_key_u[3] = val,
            .exc_return => self.regs.exc_return = if (valid) val else null,
            .fnc_return => self.regs.fnc_return = if (valid) val else null,
            .fpscr => self.fp.fpscr = @bitCast(val),
            .vpr => self.fp.vpr = @bitCast(val),
            .fpccr => self.fp.context.fpccr = @bitCast(val),
            .fpcar => self.fp.context.fpcar = val,
            .fpdscr => self.fp.context.fpdscr = val,
            .cpacr => self.fp.cpacr = val,
            .banked_current => self.banked.current = @fromBackingInt(@intCast(@as(u1, @truncate(val)))),
            .banked_other_msp => self.banked.other.msp = val,
            .banked_other_psp => self.banked.other.psp = val,
            .banked_other_msplim => self.banked.other.msplim = val,
            .banked_other_psplim => self.banked.other.psplim = val,
            .banked_other_primask => self.banked.other.primask = val,
            .banked_other_basepri => self.banked.other.basepri = val,
            .banked_other_faultmask => self.banked.other.faultmask = val,
            .banked_other_control => self.banked.other.control = val,
            .banked_other_low_msp => self.banked.other.low_msp = val,
            .banked_other_low_psp => self.banked.other.low_psp = val,
            .exclusive => self.exclusive = if (valid) val else null,
            .event => self.event = (val != 0),
            else => unreachable,
        }
    }
};

/// Computes the minimal diff between two architectural register states.
pub fn diffArch(pre: *const ArchState, post: *const ArchState, out: []RegDiff) usize {
    var count: usize = 0;
    inline for (@typeInfo(RegTag).@"enum".field_values) |value| {
        const tag: RegTag = @fromBackingInt(@intCast(value));
        var pre_val: u32 = 0;
        var pre_valid: bool = true;
        pre.readField(tag, &pre_val, &pre_valid);
        var post_val: u32 = 0;
        var post_valid: bool = true;
        post.readField(tag, &post_val, &post_valid);
        if (pre_val != post_val or pre_valid != post_valid) {
            if (count < out.len) {
                out[count] = .{
                    .tag = tag,
                    .pre = pre_val,
                    .post = post_val,
                    .pre_valid = pre_valid,
                    .post_valid = post_valid,
                };
            }
            count += 1;
        }
    }
    return count;
}

/// Applies pre-state to `state` and swaps pre/post in `diffs` in place.
pub fn swapDiffInState(diffs: []RegDiff, state: *ArchState) void {
    var i = diffs.len;
    while (i > 0) {
        i -= 1;
        state.writeField(diffs[i].tag, diffs[i].pre, diffs[i].pre_valid);
        diffs[i].swap();
    }
}

pub fn applyUndo(diffs: []const RegDiff, state: *ArchState) void {
    var i = diffs.len;
    while (i > 0) {
        i -= 1;
        state.writeField(diffs[i].tag, diffs[i].pre, diffs[i].pre_valid);
    }
}

pub fn applyRedo(diffs: []const RegDiff, state: *ArchState) void {
    for (diffs) |d| {
        state.writeField(d.tag, d.post, d.post_valid);
    }
}

pub const WindowSlot = struct {
    position: Position,
    kind: SlotKind,
    core: Core,
    diff_start: u32 = 0,
    diff_count: u16 = 0,
    byte_start: u32 = 0,
    byte_count: u32 = 0,
    honest_bytes: usize = 0,
};
