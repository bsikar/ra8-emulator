//! Per-core architectural SCS register rules on `BoardBus`:
//!   - `NVIC_IABR` read-only, masked by implemented `irq_lines` and `ITNS`;
//!   - `NVIC_ITNS` masked by implemented `irq_lines` (RAZ/WI without Security);
//!   - `NVIC_IPR` masked by `irq_lines`, `prio_bits` and `ITNS` (byte/half/word);
//!   - `SCB_SHPR1..3` priority fields masked by `prio_bits`;
//!   - `SYST_CALIB` read-only and seeded from `syst_calib`;
//!   - `DWT_CTRL.NUMCOMP` and `FP_CTRL.NUM_CODE` read-only when armed.
const std = @import("std");

const alias = @import("../../periph/scs_alias.zig");
const bus = @import("bus.zig");
const dwt = @import("../../periph/dwt.zig");
const fpb = @import("../../periph/fpb.zig");
const memmap = @import("../memmap.zig");
const nvic = @import("../../periph/nvic/nvic.zig");
const scs_mod = @import("../machine/scs.zig");

const iabr_span: u32 = 0x40;
const itns_span: u32 = 0x40;
const ipr_span: u32 = 0x1F0;
const shpr_span: u32 = 12;

pub const Policy = struct {
    config: scs_mod.ScsConfig = .{},
    systicks: u2 = 2,
    has_security: bool = true,
    dwt_numcomp: ?u4 = null,
    fpb_wired: bool = false,
};

/// Overlay per-core read rules onto `into` after a raw read, or answer directly.
pub fn read(policy: Policy, memory: bus.Bus, given: u32, secure: bool, into: []u8) bus.Error!bool {
    if (into.len == 0) return true;
    if (!policy.has_security and alias.scs_ns.covers(given)) {
        @memset(into, 0);
        return true;
    }
    const eff_secure = if (!policy.has_security) true else secure;
    const routed = alias.route(given, eff_secure);
    switch (routed) {
        .outside => return readDebugCaps(policy, memory, given, into),
        .res0 => {
            @memset(into, 0);
            return true;
        },
        .register => |target| return readScsRegister(policy, memory, target, into),
    }
}

fn readDebugCaps(policy: Policy, memory: bus.Bus, given: u32, into: []u8) bus.Error!bool {
    if (given == dwt.base and into.len == 4) if (policy.dwt_numcomp) |numcomp| {
        const raw = try memory.readWord(dwt.base);
        std.mem.writeInt(u32, into[0..4], dwt.ctrlWordFor(numcomp, raw), .little);
        return true;
    };
    if (policy.fpb_wired and given == fpb.base and into.len == 4) {
        const raw = try memory.readWord(fpb.base);
        const enabled = policy.config.fpb_code > 0 and (raw & fpb.ctrl_bits.enable != 0);
        std.mem.writeInt(u32, into[0..4], fpb.ctrlValue(enabled, policy.config.fpb_code), .little);
        return true;
    }
    return false;
}

fn readScsRegister(policy: Policy, memory: bus.Bus, target: alias.Target, into: []u8) bus.Error!bool {
    if (target.address == memmap.syst.calib and into.len == 4) {
        if (policy.systicks == 0 or (target.view == .non_secure and policy.systicks < 2)) {
            @memset(into, 0);
            return true;
        }
        if (policy.config.syst_calib != 0) {
            std.mem.writeInt(u32, into[0..4], policy.config.syst_calib, .little);
            return true;
        }
        return false;
    }
    if (intersects(target.address, into.len, memmap.nvic.iabr, iabr_span)) {
        try readIabrRange(policy, memory, target, into);
        return true;
    }
    if (intersects(target.address, into.len, nvic.itns.base, itns_span)) {
        try readItnsRange(policy, memory, target, into);
        return true;
    }
    if (intersects(target.address, into.len, memmap.nvic.ipr, ipr_span)) {
        try readIprRange(policy, memory, target, into);
        return true;
    }
    return false;
}

/// Intercept firmware writes to read-only or bit-masked SCS registers.
/// Returns true when `scs_regs` handled the store completely.
pub fn write(policy: Policy, memory: bus.Bus, given: u32, secure: bool, bytes: []const u8) bus.Error!bool {
    if (bytes.len == 0) return true;
    if (!policy.has_security and alias.scs_ns.covers(given)) return true;
    const eff_secure = if (!policy.has_security) true else secure;
    switch (alias.route(given, eff_secure)) {
        .outside => return writeDebugCaps(policy, memory, given, bytes),
        .res0 => return true,
        .register => |target| return writeScsRegister(policy, memory, target, bytes),
    }
}

fn writeDebugCaps(policy: Policy, memory: bus.Bus, given: u32, bytes: []const u8) bus.Error!bool {
    if (given == dwt.base and bytes.len == 4) if (policy.dwt_numcomp) |numcomp| {
        const val = std.mem.readInt(u32, bytes[0..4], .little);
        try memory.writeWord(dwt.base, dwt.ctrlWordFor(numcomp, val));
        return true;
    };
    if (policy.fpb_wired and given == fpb.base and bytes.len == 4) {
        const val = std.mem.readInt(u32, bytes[0..4], .little);
        const cur = try memory.readWord(fpb.base);
        const was_on = cur & fpb.ctrl_bits.enable != 0;
        const is_on = if (policy.config.fpb_code > 0 and val & fpb.ctrl_bits.key != 0)
            val & fpb.ctrl_bits.enable != 0
        else
            was_on;
        try memory.writeWord(fpb.base, fpb.ctrlValue(is_on, policy.config.fpb_code));
        return true;
    }
    return false;
}

fn writeScsRegister(policy: Policy, memory: bus.Bus, target: alias.Target, bytes: []const u8) bus.Error!bool {
    if (target.address == memmap.syst.calib) return true;
    if (inSpan(target.address, memmap.nvic.iabr, iabr_span)) return true;
    if (inSpan(target.address, nvic.itns.base, itns_span)) {
        if (!policy.has_security or target.view == .non_secure) return true;
        if (bytes.len != 4 or target.address & 3 != 0) return error.Unmapped;
        const word = (target.address - nvic.itns.base) / 4;
        const val = std.mem.readInt(u32, bytes[0..4], .little) & policy.config.wordIrqMask(word);
        try memory.writeWord(target.address, val);
        return true;
    }
    if (inSpan(target.address, memmap.nvic.ipr, ipr_span)) {
        try writeIprBytes(policy, memory, target, bytes);
        return true;
    }
    return false;
}

/// Mask a word store or split-store landing on SHPR1, SHPR2 or SHPR3.
pub fn maskShprWord(policy: Policy, normal_word: u32, value: u32) u32 {
    const m: u32 = policy.config.prioMask();
    return switch (normal_word) {
        memmap.scb.shpr1 => blk: {
            const sec = if (policy.has_security) m << 24 else 0;
            break :blk value & (m | (m << 8) | (m << 16) | sec);
        },
        memmap.scb.shpr2 => value & (m << 24),
        memmap.scb.shpr3 => blk: {
            const st = if (policy.systicks == 0) 0 else m << 24;
            break :blk value & (m | (m << 16) | st);
        },
        else => value,
    };
}

/// Apply SHPR priority-bit masking to a 1-, 2-, or 4-byte store into `landed`.
pub fn applyShprMask(policy: Policy, landed: u32, bytes: []const u8, out: *[4]u8) ?[]const u8 {
    const normal = if (landed >= alias.scs_ns.first and landed <= alias.scs_ns.last)
        landed - alias.offset
    else
        landed;
    if (!inSpan(normal, memmap.scb.shpr1, shpr_span) or bytes.len > 4) return null;
    const word_base = normal & ~@as(u32, 3);
    const within = normal & 3;
    if (within + bytes.len > 4) return null;
    var word_bytes: [4]u8 = @splat(0);
    @memcpy(word_bytes[within..][0..bytes.len], bytes);
    const masked = maskShprWord(policy, word_base, std.mem.readInt(u32, &word_bytes, .little));
    std.mem.writeInt(u32, &word_bytes, masked, .little);
    @memcpy(out[0..bytes.len], word_bytes[within..][0..bytes.len]);
    return out[0..bytes.len];
}

fn readIabrRange(policy: Policy, memory: bus.Bus, target: alias.Target, into: []u8) bus.Error!void {
    try memory.read(target.address, into);
    for (into, 0..) |*byte, idx| {
        const addr = target.address + @as(u32, @intCast(idx));
        if (!inSpan(addr, memmap.nvic.iabr, iabr_span)) continue;
        const word = (addr - memmap.nvic.iabr) / 4;
        var allowed = policy.config.wordIrqMask(word);
        if (target.view == .non_secure and allowed != 0) {
            allowed &= try memory.readWord(nvic.itns.base + word * 4);
        }
        const shift: u5 = @intCast((addr & 3) * 8);
        byte.* &= @truncate(allowed >> shift);
    }
}

fn readItnsRange(policy: Policy, memory: bus.Bus, target: alias.Target, into: []u8) bus.Error!void {
    if (!policy.has_security or target.view == .non_secure) return @memset(into, 0);
    try memory.read(target.address, into);
    for (into, 0..) |*byte, idx| {
        const addr = target.address + @as(u32, @intCast(idx));
        if (!inSpan(addr, nvic.itns.base, itns_span)) continue;
        const word = (addr - nvic.itns.base) / 4;
        const allowed = policy.config.wordIrqMask(word);
        const shift: u5 = @intCast((addr & 3) * 8);
        byte.* &= @truncate(allowed >> shift);
    }
}

fn readIprRange(policy: Policy, memory: bus.Bus, target: alias.Target, into: []u8) bus.Error!void {
    try memory.read(target.address, into);
    const pmask = policy.config.prioMask();
    for (into, 0..) |*byte, idx| {
        const addr = target.address + @as(u32, @intCast(idx));
        if (!inSpan(addr, memmap.nvic.ipr, ipr_span)) continue;
        const line = addr - memmap.nvic.ipr;
        if (line >= policy.config.irq_lines) {
            byte.* = 0;
            continue;
        }
        if (target.view == .non_secure and !(try lineIsNs(memory, @intCast(line)))) {
            byte.* = 0;
            continue;
        }
        byte.* &= pmask;
    }
}

fn writeIprBytes(policy: Policy, memory: bus.Bus, target: alias.Target, bytes: []const u8) bus.Error!void {
    if ((bytes.len != 1 and bytes.len != 2 and bytes.len != 4) or (target.address & (bytes.len - 1)) != 0) {
        return error.Unmapped;
    }
    const pmask = policy.config.prioMask();
    for (bytes, 0..) |raw, idx| {
        const line = (target.address - memmap.nvic.ipr) + @as(u32, @intCast(idx));
        if (line >= policy.config.irq_lines) continue;
        if (target.view == .non_secure and !(try lineIsNs(memory, @intCast(line)))) continue;
        const out = [1]u8{raw & pmask};
        try memory.write(memmap.nvic.ipr + line, &out);
    }
}

fn lineIsNs(memory: bus.Bus, line: u16) bus.Error!bool {
    const word = try memory.readWord(nvic.itns.wordFor(line));
    return word & nvic.itns.bitFor(line) != 0;
}

fn inSpan(address: u32, base: u32, span: u32) bool {
    return address >= base and address - base < span;
}

fn intersects(address: u32, len: usize, base: u32, span: u32) bool {
    const end = @as(u64, address) + len;
    return address < @as(u64, base) + span and end > base;
}
