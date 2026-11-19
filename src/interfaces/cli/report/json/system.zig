//! The `icu`, `pinfunc`, `options`, `part` and `backup` objects of
//! `--report json` (RA8EMU-373): the event links and external-IRQ pins, the
//! pin-function writes, the extra-MRAM option sequencer, the modelled part
//! and its geometry, and the battery-backed corner (PRCR, VBTBKRn, the VBATT
//! control file), the same facts report/icu.zig, pinfunc.zig, options.zig,
//! part.zig and backup.zig print. Every key is always present.
const Board = @import("ra8_board").board.Board;
const json_options = @import("options.zig");
const machine_mod = @import("ra8_chip").core.machine;
const part = @import("ra8_chip").core.part;
const std = @import("std");

/// The five objects, keyed inside the document after `capture`.
pub fn section(j: anytype, board: *Board) !void {
    try icu(j, board);
    try pinfunc(j, board);
    try json_options.section(j, &board.options);
    try partInfo(j, board.desc());
    try backup(j, board);
}

fn icu(j: anytype, board: *Board) !void {
    const unit = &board.events;
    try j.open("icu", '{');
    try j.field("raised", unit.raised);
    try j.field("pended", unit.pends);
    try j.field("unrouted", unit.unlinked);
    try j.field("repended", unit.repends);
    try j.field("irq_pins_configured", unit.pins.configured());
    try j.field("irq_pin_rewrites_while_routed", unit.pins.rewrites_while_routed);
    try j.close('}');
}

fn pinfunc(j: anytype, board: *Board) !void {
    const unit = &board.pinfunc;
    try j.open("pinfunc", '{');
    try j.field("programmed", unit.programmed);
    try j.field("refused_unlocked", unit.guard.refused);
    try j.field("refused_direction", unit.direction_refused);
    try j.field("gpio_refused_direction", board.pins.direction_refused);
    try j.field("glitched", unit.ordering.glitched);
    try j.field("ignored_keys", unit.guard.ignored_keys);
    try j.close('}');
}

fn partInfo(j: anytype, which: *const machine_mod.Machine) !void {
    try j.open("part", '{');
    try j.field("name", which.label);
    if (which.memory != &machine_mod.memory.ra8) {
        const flash = which.memory.regionByRole(.flash);
        const sram = which.memory.regionByRole(.sram);
        try j.field("mram_base", if (flash) |f| f.base else 0);
        try j.field("mram_bytes", if (flash) |f| f.size else 0);
        try j.field("sram_base", if (sram) |s| s.base else 0);
        try j.field("sram_bytes", if (sram) |s| s.size else 0);
        try j.field("cpu0_tcm_bytes", customTcmBytes(which.memory));
        try j.field("cpu0_cache_bytes", @as(u32, 0));
        try j.field("source", which.source orelse "machine memory map");
        try j.close('}');
        return;
    }
    const geometry = part.map.of(which.part);
    try j.field("mram_base", geometry.mram_base);
    try j.field("mram_bytes", geometry.mram_bytes);
    try j.field("sram_base", geometry.sram_base);
    try j.field("sram_bytes", geometry.sram_bytes);
    try j.field("cpu0_tcm_bytes", geometry.cpu0TcmBytes());
    try j.field("cpu0_cache_bytes", 2 * geometry.cpu0_cache_bank_bytes);
    if (which.hasSecond()) {
        try j.field("cpu1_tcm_bytes", geometry.cpu1TcmBytes());
        try j.field("cpu1_cache_bytes", 2 * geometry.cpu1_cache_bank_bytes);
    }
    try j.field("source", geometry.source);
    try j.close('}');
}

fn customTcmBytes(map: *const machine_mod.MemoryMap) u32 {
    var total: u32 = 0;
    for (map.regions) |r| {
        if (std.mem.eql(u8, r.name, "ITCM") or std.mem.eql(u8, r.name, "DTCM")) total += r.size;
    }
    return total;
}

fn backup(j: anytype, board: *Board) !void {
    const prcr = &board.protection;
    const unit = &board.backup;
    try j.open("backup", '{');
    try j.open("prcr", '{');
    try j.field("unlocks", prcr.unlocks);
    try j.field("rejected_keys", prcr.bad_key);
    try j.field("groups", prcr.groups);
    try j.close('}');
    try j.field("vbtbkr_writes", unit.writes);
    try j.field("dropped_locked", unit.dropped_locked);
    try j.field("dropped_disabled", unit.dropped_disabled);
    try j.field("last_drop", @tagName(unit.lastDrop()));
    try j.open("control", '{');
    try j.field("writes", unit.control.writes);
    try j.field("flags_cleared", unit.control.cleared);
    try j.field("vbae", unit.control.vbaeSet());
    try j.field("refused", unit.control.refused);
    try j.field("dropped_locked", unit.control_locked);
    try j.close('}');
    try j.close('}');
}
