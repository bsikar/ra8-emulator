//! GLCDC: the display controller, and where the panel is being scanned from.
//!
//! The RA8D2 graphics LCD controller sits at 0x4034_2000 (HUM Ch 63,
//! ra8_glcdc_regs.h). The display and e-reader examples program a graphics
//! layer's framebuffer address, line stride, line count and pixel format,
//! then set FLMRD.RENB to fetch and BG_EN.EN to turn the output stage on.
//! Ported from board_periph_glcdc.c on dev.
//!
//! The register map and field masks live in window.zig. A VEN BIT IS A
//! COMMAND, NOT A SETTING. BG_EN, GR1_EN and GR2_EN each carry one and the
//! driver polls BG_EN.VEN for the vblank window; dev stored the bit, so
//! that poll burned its budget and the background colour was never written.
//! The bit is spent on the write here; the rule and its evidence live in
//! latch.zig.
//!
//! The block sits in the switchable graphics power domain (HUM Ch 11.5.1
//! Table 11.7 p 480), dark at reset, so it asks pdctr.zig before answering:
//! programming a dark display controller is the shape of the C tree's
//! issue #247.
const periph = @import("../registry.zig");
const pdctr = @import("../pdctr.zig");
const Guest = @import("../../core/cpu/memory/guest/guest.zig").Guest;
pub const clut = @import("clut.zig");
const lanes = @import("../lanes.zig");
pub const pixel = @import("pixel.zig");
pub const scan = @import("scan.zig");
pub const blend = @import("blend.zig");
pub const mix = @import("mix.zig");
pub const out = @import("out.zig");
pub const vsync = out.vsync;
pub const frame = @import("frame.zig");
pub const backdrop = @import("backdrop.zig");
pub const pure = @import("pure.zig");
pub const Framebuffer = window.Framebuffer;
pub const Window = window.Window;
pub const ram_windows = window.ram_windows;
pub const max_dimension = window.max_dimension;
pub const shapeOf = window.shapeOf;
pub const windowEnd = window.windowEnd;
pub const addressIsRam = window.addressIsRam;

pub const tcon = @import("tcon.zig");
pub const sys = @import("sys.zig");
pub const latch = @import("latch.zig");
pub const gamma = @import("gamma.zig");
pub const snapshot = @import("snapshot.zig");
/// GLCDC geometry. The span reaches past the graphics layers to the panel
/// clock control at +0x1450, which is the last register in the block.
pub const window = @import("window.zig");
pub const win_base = window.win_base;
pub const win_span = window.win_span;
pub const off = window.off;
pub const field = window.field;
pub const Format = window.Format;

const words = win_span / 4;

/// The display controller: the register window, the power domain it lives
/// in, and the counters behind the end-of-run line.
pub const Glcdc = struct {
    pub const EventHook = struct { context: *anyopaque, frameFn: *const fn (*anyopaque, *Glcdc) void };

    /// The domain gate, held as a pointer so the answer is the board's live
    /// PDCTRGD rather than a copy of it taken at construction.
    domain: *const pdctr.Pdctr,
    /// The machine whose RAM the panel is scanned out of. Null on a board
    /// built without an engine, which is every unit test that only cares
    /// about the register window.
    memory: ?Guest = null,
    registers: [words]u32 = @splat(0),
    /// One palette pair per graphics layer, layer 1 first.
    palettes: [2]clut.Palette = @splat(.{}),
    /// The scan-out: what the panel actually shows.
    scanner: scan.Scanner = .{},
    /// One blend stage per graphics layer, layer 1 first.
    blends: [2]blend.Layer = @splat(.{}),
    /// The compositor that stacks those layers on the background.
    mixer: mix.Mixer = .{},
    /// The output stage every composited pixel leaves through.
    output: out.Stage = .{},
    /// The timing controller: how big the panel itself is, and which pin
    /// carries which sync signal.
    timing: tcon.Tcon = .{},
    /// The system control block: the pixel clock gate and the status word a
    /// driver polls a frame on.
    system: sys.Syscnt = .{},
    event_hook: ?EventHook = null,
    /// Writes accepted into the register window.
    writes: u32 = 0,
    /// Writes discarded because the graphics domain was gated off.
    dropped_unpowered: u32 = 0,
    /// Reads answered with zero for the same reason.
    dark_reads: u32 = 0,
    /// Times a layer's FLMRD.RENB went from clear to set.
    starts: u32 = 0,
    /// VEN register-update commands spent.
    latches: u32 = 0,

    pub fn init(domain: *const pdctr.Pdctr) Glcdc {
        return .{ .domain = domain };
    }

    /// A run that never touched the block has nothing to narrate.
    pub fn quiet(self: *const Glcdc) bool {
        return self.writes == 0 and self.dropped_unpowered == 0 and self.dark_reads == 0 and
            self.scanner.quiet() and self.output.quiet() and self.timing.quiet() and
            self.system.quiet();
    }

    /// BG_EN.EN: the output stage. A layer can be fetching with this clear,
    /// and the panel stays blank.
    pub fn outputEnabled(self: *const Glcdc) bool {
        return self.word(off.bg_en) & field.bg_en != 0;
    }

    /// The framebuffer being scanned out, or null when neither layer is
    /// fetching from something that looks like one. Layer 1 is the upper
    /// layer the display examples draw into, so it wins when both are up.
    pub fn framebuffer(self: *const Glcdc) ?Framebuffer {
        if (!self.domain.powered()) return null;
        if (self.decode(1)) |found| return found;
        return self.decode(2);
    }

    /// Recover one layer's descriptor, out of the five registers that
    /// describe it. The decode itself is frame.zig's.
    pub fn decode(self: *const Glcdc, layer: u8) ?Framebuffer {
        const at = off.layer_base + off.layer_stride * (@as(u32, layer) - 1);
        return frame.decode(.{
            .flmrd = self.word(at + off.flmrd),
            .flm2 = self.word(at + off.flm2),
            .flm3 = self.word(at + off.flm3),
            .flm5 = self.word(at + off.flm5),
            .flm6 = self.word(at + off.flm6),
        }, layer, self.outputEnabled());
    }

    /// An unpowered block does not drive the bus: reads give zero, and the
    /// read is counted so the run can say the panel was programmed dark.
    /// Every register here is 32 bits wide, so a read is served from the
    /// word it lands in and cut to the lanes it named.
    pub fn read(self: *Glcdc, address: u32, width: u3) u32 {
        if (!self.domain.powered()) {
            self.dark_reads +%= 1;
            return 0;
        }
        const offset = address - win_base;
        const held = self.readWord(lanes.word(offset));
        return lanes.part(held, lanes.lane(offset), width);
    }

    /// The whole register at a word-aligned offset. A CLUT entry reads back so
    /// a driver can check the palette it filled, and STMON is the block's own
    /// status rather than the last word written at it, so both answer first.
    pub fn readWord(self: *Glcdc, offset: u32) u32 {
        if (clut.slotOf(offset)) |slot| {
            return self.palettes[slot.layer - 1].load(slot.plane, slot.index);
        }
        if (self.system.read(offset)) |value| return value;
        return self.word(offset);
    }

    /// A write while the domain is gated reaches no flip-flop on silicon and
    /// is dropped here, counted rather than absorbed. dev snoops the value
    /// into its shadow whatever the domain is doing, so a firmware that
    /// forgot PDCTRGD gets a full framebuffer descriptor there and a dark
    /// panel on the bench. A narrow store is merged into the word it lands in,
    /// so the lanes it does not name keep what they held.
    pub fn write(self: *Glcdc, address: u32, width: u3, value: u32) void {
        if (!self.domain.powered()) {
            self.dropped_unpowered +%= 1;
            return;
        }
        const offset = address - win_base;
        const at = lanes.word(offset);
        const held = self.readWord(at);
        self.writeWord(at, lanes.merge(held, lanes.lane(offset), width, value));
    }

    fn writeWord(self: *Glcdc, offset: u32, value: u32) void {
        if (self.isStart(offset, value)) self.starts +%= 1;
        if (latch.requested(offset, value)) self.latches +%= 1;
        if (self.latchPalette(offset, value)) {
            self.writes +%= 1;
            return;
        }
        self.setWord(offset, latch.stored(offset, value));
        self.writes +%= 1;
    }

    /// Register updates a VEN asked for.
    pub fn updates(self: *const Glcdc) u32 {
        return self.latches;
    }

    /// A write into the four CLUT planes, or into a layer's CLUTINT plane
    /// select. dev snoops neither, so a palette a driver spent its init
    /// filling went into a register shadow nobody read back.
    fn latchPalette(self: *Glcdc, offset: u32, value: u32) bool {
        // The output stage keeps its own copy and the shadow keeps the word,
        // so a driver that reads OUT_SET back still finds it there.
        _ = self.output.latch(offset, value);
        _ = self.timing.latch(offset, value);
        _ = self.system.latch(offset, value);
        if (clut.slotOf(offset)) |slot| {
            self.palettes[slot.layer - 1].store(slot.plane, slot.index, value);
            return true;
        }
        for (0..2) |index| {
            const base_off = off.layer_base + off.layer_stride * @as(u32, @intCast(index));
            if (offset == base_off + off.clutint) {
                self.palettes[index].select(value);
                return false;
            }
            if (offset < base_off or offset >= base_off + off.layer_stride) continue;
            // The blend stage keeps its own copy and the shadow keeps the
            // word, so a driver that reads AB1 back still finds it there.
            _ = self.blends[index].latch(offset - base_off, value);
        }
        return false;
    }

    /// Scan the panel: composite the layers onto the background colour and
    /// hand back what a viewer would see; null when there is nothing to
    /// show, and the scanner keeps why.
    pub fn scanOut(self: *Glcdc) ?scan.Picture {
        const shown = self.framebuffer() orelse return backdrop.show(self);
        if (!shown.enabled) return self.scanner.refuseOutputOff();
        if (!self.system.startFrame()) return self.scanner.refuseUnclocked();
        const memory = self.memory orelse return null;
        var planes: [mix.layers]mix.Plane = undefined;
        var fetching: [mix.layers]u8 = undefined;
        var count: usize = 0;
        for (1..mix.layers + 1) |layer| {
            const found = self.decode(@intCast(layer)) orelse continue;
            self.imply(found);
            planes[count] = .{
                .shape = shapeOf(found),
                .palette = &self.palettes[layer - 1],
                .stage = &self.blends[layer - 1],
            };
            fetching[count] = @intCast(layer);
            count += 1;
        }
        const panel = mix.Panel{
            .width = self.panelWidth(),
            .height = self.panelHeight(),
            .background = self.word(off.bg_bgc),
            .stage = &self.output,
        };
        return switch (self.mixer.run(memory, panel, planes[0..count])) {
            .picture => |picture| self.frameLanded(picture),
            .refused => |why| self.frameLost(why, fetching[0..count]),
        };
    }

    /// A frame reached the panel: the status block raises VPOS for a driver
    /// waiting on it, and the picture is what the report prints.
    pub fn frameLanded(self: *Glcdc, picture: scan.Picture) ?scan.Picture {
        self.system.completeFrame();
        if (self.event_hook) |hook| hook.frameFn(hook.context, self);
        return self.scanner.record(picture);
    }

    /// The scan wanted bytes it could not have: on silicon that is an
    /// underflow on the layer that was fetching, not a silent blank frame.
    fn frameLost(self: *Glcdc, why: scan.Refusal, fetching: []const u8) ?scan.Picture {
        if (why == .off_ram or why == .fault or why == .too_big) {
            for (fetching) |layer| self.system.underflow(layer);
        }
        return self.scanner.refuseWith(why);
    }

    /// The copied inputs for a pure composition of this block (pure.zig).
    pub fn compositeInputs(self: *const Glcdc) ?mix.Source {
        return pure.inputs(self);
    }

    /// Pure composition (pure.zig): what the panel would show, without
    /// touching a thing (RA8EMU-D13). The composition runs on the inputs'
    /// own copies, so it raises no status, counts no meters and never
    /// calls scanOut.
    pub fn composite(self: *const Glcdc, source: mix.Source, powered: bool, into: []u32) mix.Result {
        return pure.composite(self, source, powered, into);
    }

    /// The panel's frame boundary, cheap: what a driver sees at a modeled
    /// frame edge, with no pixel pass (RA8EMU R9). The pixel clock gates
    /// it; an unbelievable descriptor underflows here and an output stage
    /// that is off lands nowhere.
    pub fn frameEvent(self: *Glcdc) void {
        if (!self.system.clocked()) return;
        var lost = false;
        for (1..mix.layers + 1) |layer| {
            const at = off.layer_base + off.layer_stride * (@as(u32, @intCast(layer)) - 1) + off.flmrd;
            if (self.registers[at / 4] & field.renb == 0) continue;
            const found = self.decode(@intCast(layer)) orelse {
                lost = true;
                self.system.underflow(@intCast(layer));
                continue;
            };
            if (!found.enabled) lost = true;
        }
        if (!lost) self.system.completeFrame();
    }

    /// Arm the frame clock from the run's `panel_vsync` config; consumers
    /// attach to the clock afterwards and never arm or resize it.
    pub fn armFrameClock(self: *Glcdc, phase_ns: u64, period_ns: u64) void {
        self.output.vsync = .{ .period_ns = period_ns, .next_ns = phase_ns };
    }

    /// A layer with no AB registers written is displayed over its whole
    /// framebuffer, as this model did before the blend stage; once AB1 is
    /// programmed the register is believed.
    fn imply(self: *Glcdc, shown: Framebuffer) void {
        const stage = &self.blends[shown.layer - 1];
        if (self.timing.timing()) |found| blend.placeAll(&self.blends, .{ .left = found.h_back, .top = found.v_back });
        if (stage.quiet()) stage.* = blend.implied(shown.width, shown.height);
    }

    /// The panel is as wide and as tall as TCON says it is: the driver
    /// wrote the panel's own active area into STHB1 and STVB1 out of the
    /// board's panel table. Until it does, the panel is taken as far as the
    /// layers programmed onto it reach, which is all this model had before
    /// the timing block and is still right for a unit test that only
    /// programs a layer.
    pub fn panelWidth(self: *const Glcdc) u32 {
        if (self.timing.timing()) |found| return @min(found.h_active, max_dimension);
        return self.extent(true);
    }

    pub fn panelHeight(self: *const Glcdc) u32 {
        if (self.timing.timing()) |found| return @min(found.v_active, max_dimension);
        return self.extent(false);
    }

    fn extent(self: *const Glcdc, horizontal: bool) u32 {
        var reach: u32 = 0;
        for (1..mix.layers + 1) |layer| {
            const found = self.decode(@intCast(layer)) orelse continue;
            const rect = self.blends[layer - 1].rect();
            const edge = if (horizontal) rect.left + rect.width else rect.top + rect.height;
            const own = if (horizontal) found.width else found.height;
            reach = @max(reach, @max(edge, own));
        }
        return @min(reach, max_dimension);
    }

    /// Whether this write is the edge that starts a layer fetching.
    fn isStart(self: *const Glcdc, offset: u32, value: u32) bool {
        const layer1 = off.layer_base + off.flmrd;
        const layer2 = off.layer_base + off.layer_stride + off.flmrd;
        if (offset != layer1 and offset != layer2) return false;
        return value & field.renb != 0 and self.word(offset) & field.renb == 0;
    }

    /// The shadow behind the window, zero past the end of it.
    pub fn word(self: *const Glcdc, offset: u32) u32 {
        const index = offset / 4;
        if (index >= words) return 0;
        return self.registers[index];
    }

    fn setWord(self: *Glcdc, offset: u32, value: u32) void {
        const index = offset / 4;
        if (index >= words) return;
        self.registers[index] = value;
    }

    /// Put the controller on the bus with the machine its panel is scanned
    /// out of. The block owns this the way the Ethernet and I2C sides own
    /// theirs, so the board wires a display in one line.
    pub fn attach(self: *Glcdc, bus: *periph.Bus, domain: *const pdctr.Pdctr, core: Guest) !void {
        self.* = Glcdc.init(domain);
        self.memory = core;
        try bus.add(self.block());
    }

    pub fn block(self: *Glcdc) periph.Block {
        return .{
            .name = "GLCDC",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
            .peekFn = @import("peek.zig").thunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Glcdc = @ptrCast(@alignCast(context));
    return self.read(address, width);
}
fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Glcdc = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
