//! Covers src/periph/drw.zig: the power gate over the drawing engine, the
//! ORIGIN trigger, the bounding-box scan, the display-list reader and the
//! configurations this model declines rather than guesses at.
const std = @import("std");
const ra8 = @import("ra8");

const drw = ra8.periph.drw;
const blend = ra8.periph.drw_blend;
const limit = ra8.periph.drw_limit;
const pdctr = ra8.periph.pdctr;
const prcr = ra8.periph.prcr;
const engine = ra8.core.engine;

/// The SDRAM address the graphics examples draw into.
const fb_base: u32 = 0x6800_0000;

fn unlockedGuard() prcr.Prcr {
    var guard = prcr.Prcr.init();
    guard.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
    return guard;
}

/// A powered graphics domain: PDDE written as 0, which is the polarity trap.
fn poweredDomain(guard: *const prcr.Prcr) pdctr.Pdctr {
    var domain = pdctr.Pdctr.init(guard);
    domain.write(pdctr.win_base, 1, 0);
    return domain;
}

fn at(offset: u32) u32 {
    return drw.win_base + offset;
}

/// CONTROL2 for a 32-bit replacing fill that keeps its own alpha: BDI so the
/// fill replaces instead of adding, and WRITEALPHA = 01 so the stored alpha
/// is the source's. Both are corrections the driver had to make; leaving
/// either at its reset value is a bench divergence, not a detail.
const opaque_fill = @as(u32, 2) << blend.control2.format_low_shift |
    blend.control2.dst_invert |
    @as(u32, 1) << blend.control2.write_alpha_shift;

/// Program an opaque fill of `width` x `height`, without triggering it.
fn programFill(unit: *drw.Drw, width: u32, height: u32, pitch: u32, color: u32) void {
    unit.write(at(drw.off.control2), 4, opaque_fill);
    unit.write(at(drw.off.color1), 4, color);
    unit.write(at(drw.off.size), 4, width | height << 16);
    unit.write(at(drw.off.pitch), 4, pitch);
}

test "the block is dark until the graphics domain is powered" {
    const guard = unlockedGuard();
    var domain = pdctr.Pdctr.init(&guard);
    var unit = drw.Drw.init(&domain);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(drw.off.control2), 4));
    unit.write(at(drw.off.color1), 4, 0xFF00_FF00);
    try std.testing.expectEqual(@as(u32, 0), unit.color1);
    try std.testing.expectEqual(@as(u32, 1), unit.dark_reads);
    try std.testing.expectEqual(@as(u32, 1), unit.dropped_unpowered);
}

test "issue #247: HWREVISION answers once PDCTRGD.PDDE is cleared" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = drw.Drw.init(&domain);
    try std.testing.expectEqual(drw.hardware_revision, unit.read(at(drw.off.control2), 4));
}

test "STATUS reads idle and every other register reads zero" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = drw.Drw.init(&domain);
    unit.write(at(drw.off.color1), 4, 0xFF00_FF00);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(drw.off.control), 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(drw.off.color1), 4));
    try std.testing.expectEqual(@as(u32, 0xFF00_FF00), unit.color1);
}

test "the shadow takes the registers this model rasterizes from" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = drw.Drw.init(&domain);
    unit.write(at(drw.off.control), 4, 0x1);
    unit.write(at(drw.off.color2), 4, 0x8000_0000);
    unit.write(at(drw.off.size), 4, 16 | 8 << 16);
    unit.write(at(drw.off.cachectl), 4, drw.field.cache_enable);
    try std.testing.expectEqual(@as(u32, 0x1), unit.control);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), unit.color2);
    try std.testing.expectEqual(@as(u32, 16), unit.box().width);
    try std.testing.expectEqual(@as(u32, 8), unit.box().height);
    try std.testing.expectEqual(drw.field.cache_enable, unit.cachectl);
}

test "an ORIGIN write with nothing programmed is not counted as declined" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = drw.Drw.init(&domain);
    unit.write(at(drw.off.origin), 4, fb_base);
    try std.testing.expectEqual(@as(u32, 0), unit.declined);
    try std.testing.expectEqual(drw.Decline.unprogrammed, unit.last_decline.?);
}

test "a quadratic coupling, the framebuffer cache and a texture source are all declined" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = drw.Drw.init(&domain);
    programFill(&unit, 16, 16, 480, 0xFF00_FF00);

    unit.write(at(drw.off.control), 4, limit.control.quads);
    unit.write(at(drw.off.origin), 4, fb_base);
    try std.testing.expectEqual(drw.Decline.quad, unit.last_decline.?);

    unit.write(at(drw.off.control), 4, 0);
    unit.write(at(drw.off.cachectl), 4, drw.field.cache_enable);
    unit.write(at(drw.off.origin), 4, fb_base);
    try std.testing.expectEqual(drw.Decline.cache, unit.last_decline.?);

    unit.write(at(drw.off.cachectl), 4, 0);
    unit.write(at(drw.off.control2), 4, blend.control2.texture_enable);
    unit.write(at(drw.off.origin), 4, fb_base);
    try std.testing.expectEqual(drw.Decline.sourced, unit.last_decline.?);

    try std.testing.expectEqual(@as(u32, 3), unit.declined);
    try std.testing.expectEqual(@as(u32, 0), unit.renders);
}

test "a render with no memory behind it is declined, not silently counted" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = drw.Drw.init(&domain);
    programFill(&unit, 4, 4, 480, 0xFF00_FF00);
    unit.write(at(drw.off.origin), 4, fb_base);
    try std.testing.expectEqual(drw.Decline.unbacked, unit.last_decline.?);
    try std.testing.expectEqual(@as(u32, 0), unit.renders);
}

/// A board's worth of machine for the rasterizing tests: SDRAM mapped, the
/// domain powered, the engine handed to the block as its framebuffer memory.
const Bench = struct {
    core: engine.Engine,
    guard: prcr.Prcr,
    domain: pdctr.Pdctr,
    unit: drw.Drw,

    fn open(self: *Bench) !void {
        self.core = try engine.Engine.open();
        try self.core.map(fb_base, 0x1000);
        self.guard = unlockedGuard();
        self.domain = poweredDomain(&self.guard);
        self.unit = drw.Drw.init(&self.domain);
        self.unit.memory = self.core;
    }

    fn close(self: *Bench) void {
        self.core.close();
    }

    fn pixel(self: *Bench, index: u32) !u32 {
        return self.core.readWord(fb_base + index * 4);
    }
};

test "writing ORIGIN scans the bounding box and stores the pixels" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    programFill(&bench.unit, 4, 2, 8, 0xFF00_FF00);
    bench.unit.write(at(drw.off.origin), 4, fb_base);

    try std.testing.expectEqual(@as(u32, 1), bench.unit.renders);
    try std.testing.expectEqual(@as(u64, 8), bench.unit.pixels);
    try std.testing.expectEqual(@as(u32, 4), bench.unit.last_width);
    try std.testing.expectEqual(@as(u32, 2), bench.unit.last_height);
    try std.testing.expectEqual(@as(u32, 0xFF00_FF00), try bench.pixel(0));
    try std.testing.expectEqual(@as(u32, 0xFF00_FF00), try bench.pixel(3));
    // Row two starts a PITCH of pixels along, not a width of them.
    try std.testing.expectEqual(@as(u32, 0), try bench.pixel(4));
    try std.testing.expectEqual(@as(u32, 0xFF00_FF00), try bench.pixel(8));
}

test "the box is anchored where ORIGIN points, so a corner stays untouched" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    programFill(&bench.unit, 2, 1, 8, 0xFF11_2233);
    bench.unit.write(at(drw.off.origin), 4, fb_base + 8);

    try std.testing.expectEqual(@as(u32, 0), try bench.pixel(0));
    try std.testing.expectEqual(@as(u32, 0xFF11_2233), try bench.pixel(2));
    try std.testing.expectEqual(@as(u32, 0xFF11_2233), try bench.pixel(3));
}

test "the reset blend adds to what is already in the framebuffer" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    try bench.core.writeWord(fb_base, 0x0000_0010);
    const argb8888 = @as(u32, 2) << blend.control2.format_low_shift;
    bench.unit.write(at(drw.off.control2), 4, argb8888);
    bench.unit.write(at(drw.off.color1), 4, 0xFF00_FF00);
    bench.unit.write(at(drw.off.size), 4, 1 | 1 << 16);
    bench.unit.write(at(drw.off.pitch), 4, 1);
    bench.unit.write(at(drw.off.origin), 4, fb_base);

    // Alpha comes from COLOR2, which is zero: issue #170 in one read-back.
    try std.testing.expectEqual(@as(u32, 0x0000_FF10), try bench.pixel(0));
}

test "an RGB565 fill stores two bytes per pixel" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    const rgb565 = @as(u32, 1) << blend.control2.format_low_shift;
    bench.unit.write(at(drw.off.control2), 4, rgb565 | blend.control2.dst_invert);
    bench.unit.write(at(drw.off.color1), 4, 0xFFFF_0000);
    bench.unit.write(at(drw.off.size), 4, 2 | 1 << 16);
    bench.unit.write(at(drw.off.pitch), 4, 2);
    bench.unit.write(at(drw.off.origin), 4, fb_base);

    try std.testing.expectEqual(@as(u32, 0xF800_F800), try bench.pixel(0));
}

test "a framebuffer base pointing at nothing mapped is counted, not fatal" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    programFill(&bench.unit, 2, 1, 8, 0xFF00_FF00);
    bench.unit.write(at(drw.off.origin), 4, 0x3000_0000);

    try std.testing.expectEqual(@as(u32, 1), bench.unit.renders);
    try std.testing.expectEqual(@as(u32, 2), bench.unit.faults);
}

test "a display list programs registers and its ORIGIN entry draws" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    const list = fb_base + 0x800;
    const entries = [_]u32{
        drw.dlist.one_index | drw.off.control2 / 4, opaque_fill,
        drw.dlist.one_index | drw.off.color1 / 4,   0xFF44_5566,
        drw.dlist.one_index | drw.off.size / 4,     2 | 1 << 16,
        drw.dlist.one_index | drw.off.pitch / 4,    2,
        drw.dlist.one_index | drw.off.origin / 4,   fb_base,
        drw.dlist.end_of_list,                      0,
    };
    for (entries, 0..) |word, index| try bench.core.writeWord(list + @as(u32, @intCast(index)) * 4, word);
    bench.unit.write(at(drw.off.dliststart), 4, list);

    try std.testing.expectEqual(@as(u32, 1), bench.unit.dlists);
    try std.testing.expectEqual(@as(u32, 1), bench.unit.renders);
    try std.testing.expectEqual(@as(u32, 0xFF44_5566), try bench.pixel(0));
    try std.testing.expectEqual(@as(u32, 0xFF44_5566), try bench.pixel(1));
}

test "an end-of-list wait keeps reading, and a DLISTSTART entry stops" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    const list = fb_base + 0x800;
    const wait = drw.dlist.end_of_list | drw.dlist.argument_wait << drw.dlist.argument_shift;
    const entries = [_]u32{
        wait,
        drw.dlist.one_index | drw.off.color1 / 4,
        0x1122_3344,
        drw.dlist.one_index | drw.dlist.dliststart_index,
        drw.dlist.one_index | drw.off.color2 / 4,
        0x5566_7788,
    };
    for (entries, 0..) |word, index| try bench.core.writeWord(list + @as(u32, @intCast(index)) * 4, word);
    bench.unit.write(at(drw.off.dliststart), 4, list);

    try std.testing.expectEqual(@as(u32, 0x1122_3344), bench.unit.color1);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.color2);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.dlist_stops);
}

test "an unmodelled multi-index tag stops the reader instead of guessing" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    const list = fb_base + 0x800;
    try bench.core.writeWord(list, 0x0000_0003);
    try bench.core.writeWord(list + 4, drw.dlist.one_index | drw.off.color1 / 4);
    bench.unit.write(at(drw.off.dliststart), 4, list);

    try std.testing.expectEqual(@as(u32, 1), bench.unit.dlist_stops);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.color1);
}

test "the block claims its own window on the bus" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = drw.Drw.init(&domain);
    const claim = unit.block();
    try std.testing.expectEqualStrings("DRW", claim.name);
    try std.testing.expectEqual(drw.win_base, claim.base);
    try std.testing.expect(claim.covers(at(drw.off.dliststart)));
    try std.testing.expect(!claim.covers(drw.win_base + drw.win_span));
}

test "a run that never touched the engine has nothing to narrate" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = drw.Drw.init(&domain);
    try std.testing.expect(unit.quiet());
    unit.write(at(drw.off.color1), 4, 1);
    try std.testing.expect(!unit.quiet());
}
