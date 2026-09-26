//! ELC: the event link controller, which lets one event trigger a peripheral
//! without the CPU in the middle.
//!
//! A peripheral on this part raises a numbered event. The ICU decides which
//! NVIC line that event drives (src/periph/icu.zig); the ELC decides which
//! *peripheral* it drives, so an ADC conversion can start a DMA transfer or a
//! timer can start an ADC with no interrupt taken at all. It also owns the
//! only way firmware has to raise an event itself: the four software event
//! generators, ELSEGR0..3, which produce ELC_SWEVT0..3.
//!
//!   ELCR     (+0x000, 8b)  ELCON b7: the global enable for the whole block
//!   ELSEGRn  (+0x004, 8b, stride 4) WI b7, WE b6, SEG b0: software events
//!   ELSR[n]  (+0x020, 16b, stride 4) ELS [9:0]: the event peripheral n takes
//!   ELCSARx  (+0x100/4/8, 32b) security attribution, stored, not enforced
//!   ELCPARx  (+0x110/4/8, 32b) privilege attribution, stored, not enforced
//!
//! NOTHING WAS PORTED FROM dev, BECAUSE dev NEVER MODELLED THIS BLOCK. The C
//! tree carries inc/ra8_elc_regs.h and ten blocks that talk about ELC events
//! (adc, canfd, dmac, dtc, ipc, npu, rtc, sci, timer, ulpt), and no
//! board_periph_elc.c. So every ELC register there falls through to the
//! sparse register file, which remembers what was written: a firmware runs
//! the three-step ELSEGR0 sequence, reads 0x41 back, and believes it fired a
//! software event, while no event exists and nothing downstream ever runs.
//! The register layout here is ra8_elc_regs.h and HUM Ch 19 p 817..836.
const std = @import("std");
const periph = @import("registry.zig");

/// ELC geometry (FSP R_ELC_Type, size 0x11C at 0x4020_1000).
pub const win_base: u32 = 0x4020_1000;
pub const win_span: u32 = 0x11C;

/// Register byte offsets inside the window (ra8_elc_regs.h).
pub const off = struct {
    pub const elcr: u32 = 0x000;
    pub const elsegr: u32 = 0x004;
    pub const elsegr_stride: u32 = 0x004;
    pub const elsr: u32 = 0x020;
    pub const elsr_stride: u32 = 0x004;
    pub const elcsara: u32 = 0x100;
    pub const elcpara: u32 = 0x110;
};

/// How many of each the RA8D2 has.
pub const generators: usize = 4;
pub const links: usize = 53;
/// Attribution registers: three security words then three privilege words.
pub const attributions: usize = 6;

/// Field masks.
pub const field = struct {
    /// ELCR.ELCON b7: with this clear the block conducts nothing.
    pub const elcon: u8 = 0x80;
    /// ELSEGRn.WI b7: write inhibit. A write that sets it is discarded whole.
    pub const wi: u8 = 0x80;
    /// ELSEGRn.WE b6: write enable for SEG. Has to be set by an earlier write.
    pub const we: u8 = 0x40;
    /// ELSEGRn.SEG b0: generate the software event. Self-clearing.
    pub const seg: u8 = 0x01;
    /// ELSR.ELS [9:0]: the source event this peripheral slot listens for.
    pub const els: u16 = 0x03FF;
};

/// ELC_SWEVT0 is event 0x0CC (HUM Ch 19 Table 19.3), and the other three
/// follow it, so ELSEGRn generates event 0x0CC + n.
pub const swevt_base: u16 = 0x0CC;

pub fn softwareEvent(index: usize) u16 {
    return swevt_base + @as(u16, @intCast(index));
}

/// Why a trigger write generated nothing. Every one of these reads as success
/// on a sparse register file, which is the whole reason they are counted.
pub const Refusal = enum {
    /// The write set WI, so silicon discarded it without looking further.
    inhibited,
    /// SEG was written without WE armed by an earlier write.
    unarmed,
    /// ELCR.ELCON is clear, so the block is off.
    disabled,
};

/// Software events generated this boundary, drained by the board.
pub const Due = std.BoundedArray(u16, generators);

/// The link table, the generators, and the counters behind the report line.
pub const Elc = struct {
    elcr: u8 = 0,
    /// The live WE bit of each generator. WI reads back set, so it is not
    /// stored: it is a write-side gate, not a state bit.
    armed: [generators]bool = [_]bool{false} ** generators,
    elsr: [links]u16 = [_]u16{0} ** links,
    attribution: [attributions]u32 = [_]u32{0} ** attributions,
    pending: Due = .{},
    /// Software events actually generated.
    generated: u32 = 0,
    /// Trigger writes refused, by reason.
    inhibited: u32 = 0,
    unarmed: u32 = 0,
    disabled: u32 = 0,
    /// Events generated whose ELSR link names a peripheral no block models,
    /// so the link exists and conducts to nothing.
    unconsumed: u32 = 0,

    pub fn init() Elc {
        return .{};
    }

    /// A run that never touched the block stays out of the report.
    pub fn quiet(self: *const Elc) bool {
        return self.generated == 0 and self.refused() == 0 and self.linkCount() == 0;
    }

    pub fn refused(self: *const Elc) u32 {
        return self.inhibited + self.unarmed + self.disabled;
    }

    /// Whether ELCR.ELCON is set. Nothing conducts while it is not.
    pub fn enabled(self: *const Elc) bool {
        return self.elcr & field.elcon != 0;
    }

    /// How many peripheral slots have a source event programmed.
    pub fn linkCount(self: *const Elc) u32 {
        var total: u32 = 0;
        for (self.elsr) |slot| {
            if (slot & field.els != 0) total += 1;
        }
        return total;
    }

    /// The first peripheral slot linked to `event`, or null. Several slots may
    /// take the same source, so this answers "is anything listening" rather
    /// than standing in for the whole set.
    pub fn target(self: *const Elc, event: u16) ?usize {
        if (event == 0) return null;
        for (self.elsr, 0..) |slot, index| {
            if (slot & field.els == event) return index;
        }
        return null;
    }

    /// The software events generated since the last drain. The board raises
    /// each into the ICU at the chunk boundary, the same seam the serial
    /// block's interrupts go through.
    pub fn takeEvents(self: *Elc) Due {
        const due = self.pending;
        self.pending = .{};
        return due;
    }

    pub fn read(self: *Elc, address: u32, width: u3) u32 {
        _ = width;
        const offset = address -% win_base;
        if (offset == off.elcr) return self.elcr;
        if (self.generatorAt(offset)) |index| return self.readGenerator(index);
        if (self.linkAt(offset)) |index| return self.elsr[index];
        if (self.attributionAt(offset)) |index| return self.attribution[index];
        return 0;
    }

    pub fn write(self: *Elc, address: u32, width: u3, value: u32) void {
        _ = width;
        const offset = address -% win_base;
        if (offset == off.elcr) {
            self.elcr = @truncate(value);
            return;
        }
        if (self.generatorAt(offset)) |index| return self.writeGenerator(index, @truncate(value));
        if (self.linkAt(offset)) |index| {
            self.elsr[index] = @truncate(value);
            return;
        }
        if (self.attributionAt(offset)) |index| self.attribution[index] = value;
    }

    /// WI reads back set, so a driver reading the register before writing it
    /// sees a write-inhibited generator, which is what it is. SEG is
    /// self-clearing and never reads back as one.
    fn readGenerator(self: *const Elc, index: usize) u32 {
        return field.wi | (if (self.armed[index]) field.we else 0);
    }

    /// The three-step sequence, as bits rather than as a step counter:
    /// 0x00 clears WE, 0x40 arms it, 0x41 fires. A write that sets WI is
    /// discarded whole (that is what the bit means), and SEG only takes when
    /// an earlier write already armed WE, so the single 0x41 store a driver
    /// reaches for first generates nothing on silicon. FSP writes all three
    /// (ELC_ELSEGRN_STEP1..3 in r_elc.c) for exactly this reason.
    fn writeGenerator(self: *Elc, index: usize, value: u8) void {
        if (value & field.wi != 0) {
            self.inhibited +%= 1;
            return;
        }
        const was_armed = self.armed[index];
        self.armed[index] = value & field.we != 0;
        if (value & field.seg == 0) return;
        if (!was_armed or !self.armed[index]) {
            self.unarmed +%= 1;
            return;
        }
        self.generate(index);
    }

    /// Fire software event index, if the block is switched on at all. The
    /// generator disarms afterwards, so each event costs its own sequence.
    fn generate(self: *Elc, index: usize) void {
        self.armed[index] = false;
        if (!self.enabled()) {
            self.disabled +%= 1;
            return;
        }
        const event = softwareEvent(index);
        self.generated +%= 1;
        if (self.target(event) != null) self.unconsumed +%= 1;
        self.pending.append(event) catch {};
    }

    fn generatorAt(self: *const Elc, offset: u32) ?usize {
        _ = self;
        if (offset < off.elsegr or offset >= off.elsr) return null;
        const index = (offset - off.elsegr) / off.elsegr_stride;
        return if (index < generators) index else null;
    }

    fn linkAt(self: *const Elc, offset: u32) ?usize {
        _ = self;
        if (offset < off.elsr or offset >= off.elcsara) return null;
        const index = (offset - off.elsr) / off.elsr_stride;
        return if (index < links) index else null;
    }

    /// ELCSARA/B/C then ELCPARA/B/C, six words in two groups of three. They
    /// are stored and read back and NOT enforced: every access in this
    /// emulator is treated as secure and privileged, so a firmware that locks
    /// itself out of the block on silicon still gets through here.
    fn attributionAt(self: *const Elc, offset: u32) ?usize {
        _ = self;
        if (offset >= off.elcsara and offset < off.elcsara + 12) {
            return (offset - off.elcsara) / 4;
        }
        if (offset >= off.elcpara and offset < off.elcpara + 12) {
            return 3 + (offset - off.elcpara) / 4;
        }
        return null;
    }

    pub fn block(self: *Elc) periph.Block {
        return .{
            .name = "ELC event links",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Elc = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Elc = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The address of one ELSEGR generator, so a test or a later slice does not
/// redo the arithmetic.
pub fn generatorAddress(index: usize) u32 {
    return win_base + off.elsegr + off.elsegr_stride * @as(u32, @intCast(index));
}

/// The address of one ELSR peripheral slot.
pub fn linkAddress(index: usize) u32 {
    return win_base + off.elsr + off.elsr_stride * @as(u32, @intCast(index));
}
