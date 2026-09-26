//! DRW: the D/AVE 2D drawing engine, and the pixels it actually stores.
//!
//! The RA8D2 2D rasterizer sits at 0x4044_4000 (HUM Ch 62, ra8_drw_regs.h),
//! inside the switchable graphics power domain, so it asks pdctr.zig before
//! it answers anything. It is the second consumer of that seam after GLCDC,
//! and the block the C tree's issue #247 was actually about: the engine had
//! never rasterized on the bench because nothing ever cleared PDCTRGD.PDDE,
//! and the emulator modelled no power domain at all, so the app passed.
//! Ported from board_periph_drw.c on dev; the blend arithmetic lives next
//! door in drw_blend.zig.
//!
//! The geometry rule is the whole block in one sentence (HUM Ch 62.6.2
//! p 3716): the engine scans the bounding box SIZE gives it, anchored at the
//! pixel ORIGIN points at, stepping PITCH pixels per row, and WRITING ORIGIN
//! IS THE TRIGGER. So an axis-aligned rectangle needs no spatial limiter,
//! and a driver that programs SIZE last has drawn nothing.
//!
//! Every DRW register except STATUS, HWREVISION and the performance counters
//! is write-only on silicon (HUM Ch 62.2, R/W column "W"), so the shadow
//! below is not a convenience, it is the only copy of what was programmed.
const std = @import("std");

const engine = @import("../core/engine.zig");
const blend = @import("drw_blend.zig");
const limit = @import("drw_limit.zig");
const pdctr = @import("pdctr.zig");
const periph = @import("registry.zig");

pub const win_base: u32 = 0x4044_4000;
pub const win_span: u32 = 0x104;

/// Register byte offsets this model tracks (HUM Ch 62.2).
pub const off = struct {
    /// CONTROL on write, STATUS on read.
    pub const control: u32 = 0x000;
    /// CONTROL2 on write, HWREVISION on read.
    pub const control2: u32 = 0x004;
    pub const color1: u32 = 0x064;
    pub const color2: u32 = 0x068;
    pub const size: u32 = 0x078;
    pub const pitch: u32 = 0x07C;
    /// Writing ORIGIN anchors the box and starts the render.
    pub const origin: u32 = 0x080;
    pub const cachectl: u32 = 0x0C4;
    /// Writing DLISTSTART kicks the display-list reader.
    pub const dliststart: u32 = 0x0C8;
};

pub const field = struct {
    /// CACHECTL.CENABLEFX: the framebuffer cache (HUM Ch 62.2.4 p 3694).
    pub const cache_enable: u32 = 1 << 0;
    pub const size_mask: u32 = 0xFFFF;
    pub const height_shift: u5 = 16;
};

/// HWREVISION as read from an EK-RA8D2 over J-Link with the domain powered
/// (HUM Ch 62.2.6 p 3696). Reads 0 while the domain is gated, which is the
/// cheapest "is my engine alive" check a driver can make.
pub const hardware_revision: u32 = 0x0FBE_0107;

/// The display-list encoding the ra8_drw builder emits and the bench
/// confirmed for issue #247: a one-index tag (byte 1 bit 7 set, byte 0 the
/// register index) followed by one value word, and end-of-list words whose
/// low byte is 0xFF with the argument in byte 1. Multi-index packing was
/// never observed, so the reader stops on it rather than guessing.
pub const dlist = struct {
    pub const index_mask: u32 = 0xFF;
    pub const one_index: u32 = 0x0000_8000;
    pub const end_of_list: u32 = 0xFF;
    pub const argument_shift: u5 = 8;
    /// Wait for the pipeline and cache, then keep reading.
    pub const argument_wait: u32 = 2;
    /// A DLISTSTART entry inside a list is a jump, which is where this
    /// reader stops.
    pub const dliststart_index: u32 = 50;
    pub const bytes_per_word: u32 = 4;
    /// A bound on the fetch, so a corrupt list cannot spin the run.
    pub const max_words: u32 = 4096;
};

/// Why a render the firmware asked for produced no pixels. Both unmodelled
/// cases fail SAFE: nothing is drawn, so an app relying on them goes visibly
/// blank here rather than reporting a false pass on invented pixels.
pub const Decline = enum {
    /// The domain is gated: on silicon the write never reached a flip-flop.
    unpowered,
    /// SIZE, PITCH or ORIGIN not programmed yet, e.g. the init ORIGIN write.
    unprogrammed,
    /// A quadratic limiter coupling (CONTROL.QUAD1/2/3) is enabled. It is a
    /// different evaluation from the six linear edges, not a harder one, and
    /// no in-tree primitive programs it.
    quad,
    /// The framebuffer cache holds the pixels until a CFLUSHFX, and its
    /// geometry is undocumented.
    cache,
    /// A pattern or texture source, which this model does not read.
    sourced,
    /// No memory to draw into, which only a board built without an engine
    /// hits: the geometry was fine and the pixels had nowhere to go.
    unbacked,
};

/// The drawing engine: the write-only register shadow, the power domain it
/// lives in, the memory it rasterizes into, and the counters behind the
/// end-of-run line.
pub const Drw = struct {
    domain: *const pdctr.Pdctr,
    /// Where the pixels go. Held by value because an engine handle is a
    /// handle; a board built by a test that never rasterizes leaves it null
    /// and a render is declined as unbacked rather than silently counted.
    memory: ?engine.Engine = null,

    /// The six edge limiters, and the tree CONTROL folds them down.
    limits: limit.Set = .{},

    control: u32 = 0,
    control2: u32 = 0,
    color1: u32 = 0,
    color2: u32 = 0,
    size: u32 = 0,
    pitch: u32 = 0,
    origin: u32 = 0,
    cachectl: u32 = 0,

    writes: u32 = 0,
    dropped_unpowered: u32 = 0,
    dark_reads: u32 = 0,
    /// Bounding boxes rasterized, and the last one's shape.
    renders: u32 = 0,
    last_width: u32 = 0,
    last_height: u32 = 0,
    pixels: u64 = 0,
    /// Renders declined, and why the most recent one was.
    declined: u32 = 0,
    last_decline: ?Decline = null,
    /// Renders the limiters actually shaped, and the bounding-box pixels
    /// they kept out.
    limited: u32 = 0,
    clipped: u64 = 0,
    /// Pixels painted at full coverage that sit inside the sub-pixel band at
    /// a limiter boundary, where an anti-aliasing engine would part-cover.
    hard_edges: u64 = 0,
    /// Display lists executed, and entries whose encoding stopped the reader.
    dlists: u32 = 0,
    dlist_stops: u32 = 0,
    /// Pixel accesses the memory refused, e.g. a framebuffer base pointing
    /// at nothing mapped.
    faults: u32 = 0,

    pub fn init(domain: *const pdctr.Pdctr) Drw {
        return .{ .domain = domain };
    }

    pub fn quiet(self: *const Drw) bool {
        return self.writes == 0 and self.dropped_unpowered == 0 and self.dark_reads == 0;
    }

    pub fn style(self: *const Drw) blend.Style {
        return blend.Style.decode(self.control2);
    }

    /// Width and height of the box SIZE currently describes.
    pub fn box(self: *const Drw) struct { width: u32, height: u32 } {
        return .{
            .width = self.size & field.size_mask,
            .height = self.size >> field.height_shift & field.size_mask,
        };
    }

    /// STATUS reads as idle: this model rasterizes inside the ORIGIN write,
    /// so the engine is never busy by the time firmware can look. Every
    /// other register is write-only and reads back zero, HWREVISION aside.
    pub fn read(self: *Drw, address: u32, width: u3) u32 {
        _ = width;
        if (!self.domain.powered()) {
            self.dark_reads +%= 1;
            return 0;
        }
        return switch (address - win_base) {
            off.control2 => hardware_revision,
            else => 0,
        };
    }

    pub fn write(self: *Drw, address: u32, width: u3, value: u32) void {
        _ = width;
        // An unpowered block does not latch: dev snoops the value anyway, so
        // a firmware that forgot PDCTRGD draws a complete picture there and
        // nothing on the bench.
        if (!self.domain.powered()) {
            self.dropped_unpowered +%= 1;
            return;
        }
        self.writes +%= 1;
        switch (address - win_base) {
            off.origin => {
                self.origin = value;
                self.render();
            },
            off.dliststart => self.runList(value),
            else => self.latch(address - win_base, value),
        }
    }

    /// Take a value into the shadow. The limiters keep their own state; the
    /// texture, CLUT and IRQ registers are accepted and dropped, because a
    /// driver programs them and this model declines to rasterize anything
    /// that depends on them anyway.
    fn latch(self: *Drw, offset: u32, value: u32) void {
        if (self.limits.latch(offset, value)) return;
        switch (offset) {
            off.control => self.control = value,
            off.control2 => self.control2 = value,
            off.color1 => self.color1 = value,
            off.color2 => self.color2 = value,
            off.size => self.size = value,
            off.pitch => self.pitch = value,
            off.cachectl => self.cachectl = value,
            else => {},
        }
    }

    /// Why this configuration cannot be rasterized, or null when it can.
    pub fn declineReason(self: *const Drw) ?Decline {
        const shape = self.box();
        if (!self.domain.powered()) return .unpowered;
        if (shape.width == 0 or shape.height == 0 or self.pitch == 0 or self.origin == 0) return .unprogrammed;
        if (self.control & limit.control.quads != 0) return .quad;
        if (self.cachectl & field.cache_enable != 0) return .cache;
        if (self.style().sourced) return .sourced;
        if (self.memory == null) return .unbacked;
        return null;
    }

    /// Scan the bounding box, compositing COLOR1 over every pixel in it.
    pub fn render(self: *Drw) void {
        if (self.declineReason()) |reason| {
            self.decline(reason);
            return;
        }
        const shape = self.box();
        const painting = self.style();
        const bytes = painting.format.bytesPerPixel();
        const memory = self.memory.?;
        const shaped = limit.Set.active(self.control);
        var drawn: u64 = 0;
        var row: u32 = 0;
        while (row < shape.height) : (row += 1) {
            const line = @as(u64, self.origin) + @as(u64, row) * self.pitch * bytes;
            var column: u32 = 0;
            while (column < shape.width) : (column += 1) {
                if (shaped and !self.covered(column, row)) {
                    self.clipped +%= 1;
                    continue;
                }
                const at = line + @as(u64, column) * bytes;
                if (at > std.math.maxInt(u32)) {
                    self.faults +%= 1;
                    continue;
                }
                self.paint(memory, @intCast(at), painting, bytes);
                drawn += 1;
            }
        }
        self.renders +%= 1;
        if (shaped) self.limited +%= 1;
        self.last_width = shape.width;
        self.last_height = shape.height;
        self.pixels +%= drawn;
    }

    /// Whether the limiters admit this pixel of the bounding box, counting
    /// the ones that land on a boundary the engine would soften.
    fn covered(self: *Drw, column: u32, row: u32) bool {
        if (!self.limits.admits(self.control, column, row)) return false;
        if (self.limits.onEdge(self.control, column, row)) self.hard_edges +%= 1;
        return true;
    }

    fn paint(self: *Drw, memory: engine.Engine, at: u32, painting: blend.Style, bytes: u32) void {
        var cell = [_]u8{0} ** 4;
        const slot = cell[0..bytes];
        memory.read(at, slot) catch {
            self.faults +%= 1;
            return;
        };
        const stored = painting.pack(painting.shade(self.color1, self.color2, load(slot)));
        store(slot, stored);
        memory.write(at, slot) catch {
            self.faults +%= 1;
        };
    }

    /// An init ORIGIN write with nothing programmed yet is not a failed
    /// render, so only a box the firmware meant is counted as declined.
    fn decline(self: *Drw, reason: Decline) void {
        self.last_decline = reason;
        if (reason == .unprogrammed) return;
        self.declined +%= 1;
    }

    /// The display-list reader: the same register writes, fetched from
    /// memory instead of taken from the CPU (HUM Ch 62.6, TES D/AVE format).
    pub fn runList(self: *Drw, at: u32) void {
        const memory = self.memory orelse {
            self.decline(.unbacked);
            return;
        };
        self.dlists +%= 1;
        var cursor = at;
        var fetched: u32 = 0;
        while (fetched < dlist.max_words) : (fetched += 1) {
            const tag = memory.readWord(cursor) catch {
                self.faults +%= 1;
                return;
            };
            cursor +%= dlist.bytes_per_word;
            if (tag & dlist.one_index != 0) {
                const index = tag & dlist.index_mask;
                if (index == dlist.dliststart_index) return;
                const value = memory.readWord(cursor) catch {
                    self.faults +%= 1;
                    return;
                };
                cursor +%= dlist.bytes_per_word;
                self.execute(index, value);
                continue;
            }
            if (tag & dlist.index_mask == dlist.end_of_list) {
                if (tag >> dlist.argument_shift & dlist.index_mask == dlist.argument_wait) continue;
                return;
            }
            // Multi-index packing: never observed on the bench, so stop
            // rather than invent the pixels it would have drawn.
            self.dlist_stops +%= 1;
            return;
        }
        self.dlist_stops +%= 1;
    }

    /// One list entry. A register index is its byte offset over four, and an
    /// ORIGIN entry triggers exactly as a CPU write to it would.
    fn execute(self: *Drw, index: u32, value: u32) void {
        const offset = index * dlist.bytes_per_word;
        if (offset == off.origin) {
            self.origin = value;
            self.render();
            return;
        }
        self.latch(offset, value);
    }

    pub fn block(self: *Drw) periph.Block {
        return .{
            .name = "DRW",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// A framebuffer pixel is one, two or four little-endian bytes wide.
fn load(slot: []const u8) u32 {
    var value: u32 = 0;
    for (slot, 0..) |byte, index| value |= @as(u32, byte) << @intCast(index * 8);
    return value;
}

fn store(slot: []u8, value: u32) void {
    for (slot, 0..) |*byte, index| byte.* = @truncate(value >> @intCast(index * 8));
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Drw = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Drw = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
