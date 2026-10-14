//! Covers the GLCDC frame event: the panel's frame boundary without a
//! pixel pass, the cheap edge the panel_vsync config runs.
const std = @import("std");
const ra8 = @import("ra8");

const glcdc = ra8.chip.periph.glcdc;
const pdctr = ra8.chip.periph.pdctr;
const prcr = ra8.chip.periph.prcr;
const store_memory = @import("../store_memory.zig");
const Guest = store_memory.Guest;
const memmap = ra8.chip.core.memmap;

const fb_base: u32 = memmap.sram_base;

fn unlockedGuard() prcr.Prcr {
    var guard = prcr.Prcr.init();
    guard.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
    return guard;
}

fn poweredDomain(guard: *const prcr.Prcr) pdctr.Pdctr {
    var domain = pdctr.Pdctr.init(guard, .graphics);
    domain.write(pdctr.Domain.graphics.base(), 1, 0);
    return domain;
}

/// A believable 2x2 RGB888 layer 1, the output stage on, the pixel clock
/// running, and VPOS detection armed.
fn liveUnit(domain: *const pdctr.Pdctr) glcdc.Glcdc {
    var unit = glcdc.Glcdc.init(domain);
    const layer = glcdc.win_base + glcdc.off.layer_base;
    unit.write(layer + glcdc.off.flm2, 4, fb_base);
    unit.write(layer + glcdc.off.flm3, 4, 8 << 16);
    unit.write(layer + glcdc.off.flm5, 4, 1 << 16);
    unit.write(layer + glcdc.off.flm6, 4, @as(u32, @backingInt(glcdc.Format.rgb888)) << 28);
    unit.write(layer + glcdc.off.flmrd, 4, 1);
    unit.write(glcdc.win_base + glcdc.off.bg_en, 4, glcdc.field.bg_en);
    unit.write(glcdc.win_base + glcdc.sys.off.dtcten, 4, glcdc.sys.state.vpos);
    unit.write(glcdc.win_base + glcdc.sys.off.panel_clk, 4, glcdc.sys.clock.enable);
    return unit;
}

test "a frame event with no pixel clock moves nothing" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = liveUnit(&domain);
    unit.write(glcdc.win_base + glcdc.sys.off.panel_clk, 4, 0);
    unit.frameEvent();
    try std.testing.expectEqual(@as(u32, 0), unit.system.frames);
    try std.testing.expectEqual(@as(u32, 0), unit.system.status);
}

test "a frame event raises VPOS for a driver waiting on it" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = liveUnit(&domain);
    unit.frameEvent();
    try std.testing.expectEqual(@as(u32, 1), unit.system.frames);
    try std.testing.expectEqual(@as(u32, 1), unit.system.status);
    try std.testing.expectEqual(@as(u32, 1), unit.system.detections);
}

test "a frame event with detection disarmed lands the frame silently" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = liveUnit(&domain);
    unit.write(glcdc.win_base + glcdc.sys.off.dtcten, 4, 0);
    unit.frameEvent();
    try std.testing.expectEqual(@as(u32, 1), unit.system.frames);
    try std.testing.expectEqual(@as(u32, 0), unit.system.status);
    try std.testing.expectEqual(@as(u32, 1), unit.system.undetected);
}

test "a layer that cannot deliver underflows on the frame edge" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = liveUnit(&domain);
    // Underflow detection armed as well: the model raises only an armed
    // detection, which is the DTCTEN rule on silicon too.
    unit.write(glcdc.win_base + glcdc.sys.off.dtcten, 4, glcdc.sys.state.all);
    unit.write(glcdc.win_base + glcdc.off.layer_base + glcdc.off.flm2, 4, 0);
    unit.frameEvent();
    try std.testing.expectEqual(@as(u32, 0), unit.system.frames);
    try std.testing.expectEqual(@as(u32, glcdc.sys.state.gr1_underflow), unit.system.status);
    try std.testing.expectEqual(@as(u32, 1), unit.system.underflows);
}

test "a frame event with the output stage off lands no frame" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = liveUnit(&domain);
    unit.write(glcdc.win_base + glcdc.off.bg_en, 4, 0);
    unit.frameEvent();
    try std.testing.expectEqual(@as(u32, 0), unit.system.frames);
    try std.testing.expectEqual(@as(u32, 0), unit.system.status);
}

test "a background-only panel lands its frame on the edge" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    unit.write(glcdc.win_base + glcdc.off.bg_en, 4, glcdc.field.bg_en);
    unit.write(glcdc.win_base + glcdc.sys.off.dtcten, 4, glcdc.sys.state.vpos);
    unit.write(glcdc.win_base + glcdc.sys.off.panel_clk, 4, glcdc.sys.clock.enable);
    unit.frameEvent();
    try std.testing.expectEqual(@as(u32, 1), unit.system.frames);
    try std.testing.expectEqual(@as(u32, 1), unit.system.status);
}

test "the frame clock arms from the run's panel_vsync config" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    unit.armFrameClock(1_000_000, 16_666_667);
    const clock = unit.output.vsync.?;
    try std.testing.expectEqual(@as(u64, 1_000_000), clock.next_ns);
    try std.testing.expectEqual(@as(u64, 16_666_667), clock.period_ns);
    try std.testing.expect(clock.sink == null);
}
