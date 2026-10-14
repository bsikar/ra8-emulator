//! Covers src/chip/periph/glcdc/pure.zig and the Glcdc composite path:
//! what the panel would show, composed without touching a thing.
const std = @import("std");
const ra8 = @import("ra8");

const glcdc = ra8.chip.periph.glcdc;
const pdctr = ra8.chip.periph.pdctr;
const prcr = ra8.chip.periph.prcr;
const scan = ra8.chip.periph.glcdc.scan;
const store_memory = @import("../store_memory.zig");
const Guest = store_memory.Guest;
const memmap = ra8.chip.core.memmap;

const fb_base: u32 = memmap.sram_base;

/// A protection model with PRC1 unlocked, which is what a driver does before
/// it can touch the power domain at all.
fn unlockedGuard() prcr.Prcr {
    var guard = prcr.Prcr.init();
    guard.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
    return guard;
}

/// A powered graphics domain: PDDE written as 0, which is the polarity trap.
fn poweredDomain(guard: *const prcr.Prcr) pdctr.Pdctr {
    var domain = pdctr.Pdctr.init(guard, .graphics);
    domain.write(pdctr.Domain.graphics.base(), 1, 0);
    return domain;
}

/// Fill a framebuffer with one ARGB8888 colour.
fn fill(core: Guest, base: u32, count: u32, colour: u32) !void {
    var word: [4]u8 = undefined;
    std.mem.writeInt(u32, &word, colour, .little);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        try core.write(base + index * 4, &word);
    }
}

/// A 2x2 ARGB8888 layer 1 over SRAM, the output stage on, the pixel clock
/// running, and the panel as big as the layer.
fn drawnUnit(core: Guest, domain: *const pdctr.Pdctr) !glcdc.Glcdc {
    var unit = glcdc.Glcdc.init(domain);
    unit.memory = core;
    const layer = glcdc.win_base + glcdc.off.layer_base;
    unit.write(layer + glcdc.off.flm2, 4, fb_base);
    unit.write(layer + glcdc.off.flm3, 4, 8 << 16);
    unit.write(layer + glcdc.off.flm5, 4, 1 << 16);
    unit.write(layer + glcdc.off.flm6, 4, @as(u32, @backingInt(glcdc.Format.rgb888)) << 28);
    unit.write(layer + glcdc.off.flmrd, 4, 1);
    unit.write(glcdc.win_base + glcdc.off.bg_en, 4, glcdc.field.bg_en);
    unit.write(glcdc.win_base + glcdc.sys.off.panel_clk, 4, glcdc.sys.clock.enable);
    return unit;
}

test "a pure composition matches what a scan of the same state shows" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    const core = try store_memory.open();
    defer store_memory.close(core);
    try fill(core, fb_base, 4, 0xFF11_2233);
    var unit = try drawnUnit(core, &domain);
    const inputs = unit.compositeInputs() orelse return error.NoInputs;
    var pixels: [4]u32 = undefined;
    const result = unit.composite(inputs, true, &pixels);
    const picture = result.picture;
    const shown = unit.scanOut() orelse return error.NoScan;
    try std.testing.expectEqual(shown.hash, picture.hash);
    try std.testing.expectEqual(shown.pixels, picture.pixels);
    try std.testing.expectEqual(@as(u32, 0xFF11_2233), pixels[3]);
}

test "repeated pure composites change no meter status or model field" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    const core = try store_memory.open();
    defer store_memory.close(core);
    try fill(core, fb_base, 4, 0xFF44_5566);
    var unit = try drawnUnit(core, &domain);
    _ = unit.scanOut();
    const frames = unit.system.frames;
    const status = unit.system.status;
    const detections = unit.system.detections;
    const writes = unit.output.pixels;
    const shown = unit.blends[0].shown;
    const mixes = unit.mixer.mixes;
    const inputs = unit.compositeInputs() orelse return error.NoInputs;
    var pixels: [4]u32 = undefined;
    var round: u32 = 0;
    while (round < 3) : (round += 1) {
        const result = unit.composite(inputs, true, &pixels);
        try std.testing.expect(result.picture.hash != 0);
    }
    try std.testing.expectEqual(frames, unit.system.frames);
    try std.testing.expectEqual(status, unit.system.status);
    try std.testing.expectEqual(detections, unit.system.detections);
    try std.testing.expectEqual(writes, unit.output.pixels);
    try std.testing.expectEqual(shown, unit.blends[0].shown);
    try std.testing.expectEqual(mixes, unit.mixer.mixes);
}

test "an unpowered block composes nothing" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    const core = try store_memory.open();
    defer store_memory.close(core);
    try fill(core, fb_base, 4, 0xFF00_00FF);
    var unit = try drawnUnit(core, &domain);
    const inputs = unit.compositeInputs() orelse return error.NoInputs;
    var pixels: [4]u32 = undefined;
    const result = unit.composite(inputs, false, &pixels);
    try std.testing.expectEqual(scan.Refusal.no_layer, result.refused);
}

test "an unclocked block refuses its composition" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    const core = try store_memory.open();
    defer store_memory.close(core);
    try fill(core, fb_base, 4, 0xFF00_00FF);
    var unit = try drawnUnit(core, &domain);
    unit.write(glcdc.win_base + glcdc.sys.off.panel_clk, 4, 0);
    const inputs = unit.compositeInputs() orelse return error.NoInputs;
    var words: [4]u32 = undefined;
    const result = unit.composite(inputs, true, &words);
    try std.testing.expectEqual(scan.Refusal.unclocked, result.refused);
}

test "a background-only panel composes the backdrop purely" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    const core = try store_memory.open();
    defer store_memory.close(core);
    var unit = glcdc.Glcdc.init(&domain);
    unit.memory = core;
    unit.write(glcdc.win_base + glcdc.off.bg_en, 4, glcdc.field.bg_en);
    // The panel's own active area, which the driver writes into TCON.
    unit.write(glcdc.win_base + glcdc.tcon.off.sthb1, 4, 2);
    unit.write(glcdc.win_base + glcdc.tcon.off.stvb1, 4, 2);
    unit.write(glcdc.win_base + glcdc.sys.off.panel_clk, 4, glcdc.sys.clock.enable);
    const inputs = unit.compositeInputs() orelse return error.NoInputs;
    var pixels: [4]u32 = undefined;
    const result = unit.composite(inputs, true, &pixels);
    const picture = result.picture;
    const shown = unit.scanOut() orelse return error.NoScan;
    try std.testing.expectEqual(shown.hash, picture.hash);
}
