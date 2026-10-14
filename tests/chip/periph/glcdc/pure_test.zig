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

/// A graphics-1 layer over SRAM the test names: format, line stride and
/// line count, the output stage on and the pixel clock running.
fn layeredUnit(
    core: Guest,
    domain: *const pdctr.Pdctr,
    format: glcdc.Format,
    stride: u32,
    lines: u32,
) !glcdc.Glcdc {
    var unit = glcdc.Glcdc.init(domain);
    unit.memory = core;
    const layer = glcdc.win_base + glcdc.off.layer_base;
    unit.write(layer + glcdc.off.flm2, 4, fb_base);
    unit.write(layer + glcdc.off.flm3, 4, stride << 16);
    unit.write(layer + glcdc.off.flm5, 4, (lines - 1) << 16);
    unit.write(layer + glcdc.off.flm6, 4, @as(u32, @backingInt(format)) << 28);
    unit.write(layer + glcdc.off.flmrd, 4, 1);
    unit.write(glcdc.win_base + glcdc.off.bg_en, 4, glcdc.field.bg_en);
    unit.write(glcdc.win_base + glcdc.sys.off.panel_clk, 4, glcdc.sys.clock.enable);
    return unit;
}

/// A 2x2 ARGB8888 layer 1 over SRAM, the output stage on, the pixel clock
/// running, and the panel as big as the layer.
fn drawnUnit(core: Guest, domain: *const pdctr.Pdctr) !glcdc.Glcdc {
    return layeredUnit(core, domain, .rgb888, 8, 2);
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

test "a CLUT layer composes through its palette purely" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    const core = try store_memory.open();
    defer store_memory.close(core);
    // Two index bytes in the framebuffer, two entries in layer 1's first
    // palette plane. The pixel values below are the palette's answer, not
    // the bytes the fetch took.
    try core.write(fb_base, &[_]u8{ 0, 1 });
    var unit = try layeredUnit(core, &domain, .clut8, 2, 1);
    unit.write(glcdc.win_base, 4, 0xFFAA_0000);
    unit.write(glcdc.win_base + 4, 4, 0xFF00_BB11);
    const inputs = unit.compositeInputs() orelse return error.NoInputs;
    var pixels: [2]u32 = undefined;
    const result = unit.composite(inputs, true, &pixels);
    const picture = result.picture;
    try std.testing.expectEqual(@as(u32, 0xFFAA_0000), pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xFF00_BB11), pixels[1]);
    const shown = unit.scanOut() orelse return error.NoScan;
    try std.testing.expectEqual(shown.hash, picture.hash);
    try std.testing.expectEqual(shown.pixels, picture.pixels);
}

test "an empty palette refuses the CLUT layer's pure composition" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    const core = try store_memory.open();
    defer store_memory.close(core);
    try core.write(fb_base, &[_]u8{ 0, 1 });
    var unit = try layeredUnit(core, &domain, .clut8, 2, 1);
    const inputs = unit.compositeInputs() orelse return error.NoInputs;
    var pixels: [2]u32 = undefined;
    const result = unit.composite(inputs, true, &pixels);
    try std.testing.expectEqual(scan.Refusal.no_palette, result.refused);
}

test "a blended layer composes its own alpha and ARCDEF over the background" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    const core = try store_memory.open();
    defer store_memory.close(core);
    // Pixel 0 carries half its own alpha; pixel 1 carries none, so ARCDEF
    // gives it 0x80; the second row is opaque red over the backdrop.
    try fill(core, fb_base, 1, 0x40FF_0000);
    try fill(core, fb_base + 4, 1, 0x00FF_0000);
    try fill(core, fb_base + 8, 2, 0xFF00_0000);
    var unit = try layeredUnit(core, &domain, .argb8888, 8, 2);
    const layer = glcdc.win_base + glcdc.off.layer_base;
    const blended = glcdc.blend.field.grcdispon |
        @as(u32, @backingInt(glcdc.blend.Display.blended));
    unit.write(layer + glcdc.blend.off.ab1, 4, blended);
    unit.write(layer + glcdc.blend.off.ab2, 4, 2);
    unit.write(layer + glcdc.blend.off.ab3, 4, 2);
    unit.write(layer + glcdc.blend.off.ab7, 4, 0x80 << glcdc.blend.field.arcdef_shift);
    unit.write(glcdc.win_base + glcdc.off.bg_bgc, 4, 0x0000_1122);
    const inputs = unit.compositeInputs() orelse return error.NoInputs;
    var pixels: [4]u32 = undefined;
    const result = unit.composite(inputs, true, &pixels);
    try std.testing.expect(result == .picture);
    const backdrop = glcdc.blend.opaqueColour(0x0000_1122);
    try std.testing.expectEqual(glcdc.blend.over(0x40FF_0000, backdrop), pixels[0]);
    try std.testing.expectEqual(glcdc.blend.over(0x80FF_0000, backdrop), pixels[1]);
    try std.testing.expectEqual(@as(u32, 0xFF00_0000), pixels[2]);
    try std.testing.expectEqual(@as(u32, 0xFF00_0000), pixels[3]);
    try std.testing.expect(pixels[0] != 0xFF00_0000 and pixels[0] != backdrop);
}

test "two layers compose in stack order purely" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    const core = try store_memory.open();
    defer store_memory.close(core);
    // Graphics 1: 2x2 red at the origin. Graphics 2: 2x1 blue from column 1,
    // so the panels overlap in column 1 of the first row and graphics 2
    // is what the panel shows there. Column 2 of the second row reaches
    // neither layer, so the backdrop shows there.
    try fill(core, fb_base, 4, 0xFF11_1111);
    try fill(core, fb_base + 64, 2, 0xFF22_2222);
    var unit = try layeredUnit(core, &domain, .argb8888, 8, 2);
    unit.write(glcdc.win_base + glcdc.off.bg_bgc, 4, 0x0000_0909);
    const upper = glcdc.win_base + glcdc.off.layer_base + glcdc.off.layer_stride;
    unit.write(upper + glcdc.off.flm2, 4, fb_base + 64);
    unit.write(upper + glcdc.off.flm3, 4, 8 << 16);
    unit.write(upper + glcdc.off.flm5, 4, 0);
    unit.write(upper + glcdc.off.flm6, 4, @as(u32, @backingInt(glcdc.Format.argb8888)) << 28);
    unit.write(upper + glcdc.off.flmrd, 4, 1);
    const shown_mode = glcdc.blend.field.grcdispon |
        @as(u32, @backingInt(glcdc.blend.Display.shown));
    unit.write(upper + glcdc.blend.off.ab1, 4, shown_mode);
    unit.write(upper + glcdc.blend.off.ab2, 4, 1);
    unit.write(upper + glcdc.blend.off.ab3, 4, (1 << glcdc.blend.field.start_shift) | 2);
    const inputs = unit.compositeInputs() orelse return error.NoInputs;
    try std.testing.expectEqual(@as(usize, 2), inputs.count);
    var pixels: [6]u32 = undefined;
    const result = unit.composite(inputs, true, &pixels);
    const picture = result.picture;
    try std.testing.expectEqual(@as(u32, 0xFF11_1111), pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xFF22_2222), pixels[1]);
    try std.testing.expectEqual(@as(u32, 0xFF22_2222), pixels[2]);
    try std.testing.expectEqual(@as(u32, 0xFF11_1111), pixels[3]);
    try std.testing.expectEqual(@as(u32, 0xFF11_1111), pixels[4]);
    try std.testing.expectEqual(glcdc.blend.opaqueColour(0x0000_0909), pixels[5]);
    const shown = unit.scanOut() orelse return error.NoScan;
    try std.testing.expectEqual(shown.hash, picture.hash);
}
