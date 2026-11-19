//! The memory geometry line for a run on a non-default part.
//!
//! `--part ra8p1` used to change only whether the NPU window answers, and a
//! run said nothing about which part it modelled. This line names the part
//! and the geometry src/chip/core/part/map.zig cites for it. It prints only off
//! the default part, so an RA8D2 run's report stays byte identical to the
//! one every corpus expectation was recorded against.
const std = @import("std");

const machine_mod = @import("ra8_chip").core.machine;
const part = @import("ra8_chip").core.part;
const Writer = @import("../report.zig").Writer;

const kib: u32 = 1024;

/// The part line for `which`, written into `buf`.
pub fn line(buf: []u8, which: part.Part) ![]const u8 {
    return lineMachine(buf, machine_mod.catalog.ofPart(which));
}

/// The machine geometry line for `which`, written into `buf`. A single-core
/// machine omits CPU1's TCM and cache; a custom memory map reports its own
/// flash and SRAM regions.
pub fn lineMachine(buf: []u8, which: *const machine_mod.Machine) ![]const u8 {
    if (which.memory != &machine_mod.memory.ra8) return lineCustom(buf, which);
    const geometry = part.map.of(which.part);
    if (!which.hasSecond()) {
        return std.fmt.bufPrint(buf, "PART: {s} MRAM {d} KB @0x{X:0>8}, SRAM {d} KB @0x{X:0>8}, CPU0 TCM {d} KB + " ++
            "cache {d} KB ({s})\n", .{
            which.label,
            geometry.mram_bytes / kib,
            geometry.mram_base,
            geometry.sram_bytes / kib,
            geometry.sram_base,
            geometry.cpu0TcmBytes() / kib,
            2 * geometry.cpu0_cache_bank_bytes / kib,
            geometry.source,
        });
    }
    return std.fmt.bufPrint(buf, "PART: {s} MRAM {d} KB @0x{X:0>8}, SRAM {d} KB @0x{X:0>8}, CPU0 TCM {d} KB + " ++
        "cache {d} KB, CPU1 TCM {d} KB + cache {d} KB ({s})\n", .{
        which.label,
        geometry.mram_bytes / kib,
        geometry.mram_base,
        geometry.sram_bytes / kib,
        geometry.sram_base,
        geometry.cpu0TcmBytes() / kib,
        2 * geometry.cpu0_cache_bank_bytes / kib,
        geometry.cpu1TcmBytes() / kib,
        2 * geometry.cpu1_cache_bank_bytes / kib,
        geometry.source,
    });
}

fn lineCustom(buf: []u8, which: *const machine_mod.Machine) ![]const u8 {
    const flash = which.memory.regionByRole(.flash);
    const sram = which.memory.regionByRole(.sram);
    const flash_name = if (flash) |f| f.name else "FLASH";
    const flash_kb = if (flash) |f| f.size / kib else 0;
    const flash_base = if (flash) |f| f.base else 0;
    const sram_name = if (sram) |s| s.name else "SRAM";
    const sram_kb = if (sram) |s| s.size / kib else 0;
    const sram_base = if (sram) |s| s.base else 0;
    const source = which.source orelse "machine memory map";
    return std.fmt.bufPrint(
        buf,
        "PART: {s} {s} {d} KB @0x{X:0>8}, {s} {d} KB @0x{X:0>8}, CPU0 {s} ({s})\n",
        .{ which.label, flash_name, flash_kb, flash_base, sram_name, sram_kb, sram_base, which.primary().name, source },
    );
}

/// Whether a run on `which` prints the part line at all.
pub fn shown(which: part.Part) bool {
    return which != .ra8d2;
}

/// Whether a run on `which` prints the machine line at all.
pub fn shownMachine(which: *const machine_mod.Machine) bool {
    return !std.mem.eql(u8, which.name, "ra8d2");
}

/// Print the part line for `which`, when it is not the default part.
pub fn print(out: Writer, which: part.Part) !void {
    return printMachine(out, machine_mod.catalog.ofPart(which));
}

/// Print the machine line for `which`, when it is not the default machine.
pub fn printMachine(out: Writer, which: *const machine_mod.Machine) !void {
    if (!shownMachine(which)) return;
    var buf: [256]u8 = undefined;
    try out.writeAll(try lineMachine(&buf, which));
}
