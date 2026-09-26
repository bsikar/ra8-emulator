//! DAC_B: the two 12-bit D/A channels, and the enable bit that decides
//! whether a code written to one of them is an output at all.
//!
//! DAC_B0 sits at 0x4023_3000 and DAC_B1 0x100 above it (ra8_dac_b_regs.h,
//! FSP R_DAC_B0_Type). Each channel is a {DADR, DACR0, DACR1, DACR2} set, and
//! the part has no conversion-result readback: a driver writes a 12-bit code
//! to DADR and that is the whole output path. So what firmware can observe
//! here is its own control state read back, and what a headless run can
//! observe is the code stream itself.
//!
//! Ported from board_periph_dac.c on dev, with three things that model does
//! not do.
//!
//! A NARROW WRITE ONLY TOUCHES THE BYTES IT NAMES. dev ignores the access
//! size and drops the whole 32-bit value into the word, so a byte store to
//! DACR0.DACEN, which is how `ra8_dac_b_set_output_enable` flips the channel
//! on without disturbing the rest of the register, wipes the bytes above it.
//!
//! DADR IS TWELVE BITS WIDE, NOT THIRTY-TWO. dev latches the raw value and
//! reads it straight back, so an image that stores 0xF123 reads 0xF123 and
//! believes bits silicon does not have. Here the stored code is masked to the
//! data field, so a read-back is the code the channel would actually convert.
//!
//! A CODE WRITTEN TO A DISABLED CHANNEL IS NOT AN OUTPUT. dev counts every
//! DADR store into the same last/peak/writes trio whatever DACR0.DACEN says,
//! so a run that never enabled the channel still reports a waveform it never
//! drove. Here a store with DACEN clear is counted separately as `dark`, and
//! the report says so, because an image whose enable never took is exactly
//! the failure the count was supposed to catch.
//!
//! NOT MODELLED, AND NOT GUESSED: DACR0 carries DAE and DAOUTDIS beside
//! DACEN, and DACR1/DACR2 carry DPSEL and OFSSEL, but no header for this part
//! is in this tree to say which bits those are. Only DACEN, bit 0, which
//! dev's own mask names, is interpreted; everything else in the window is
//! shadowed so a read-modify-write survives, and never read.
const std = @import("std");
const periph = @import("registry.zig");

/// DAC_B geometry. The Non-secure alias is folded onto this base by the bus.
pub const win_base: u32 = 0x4023_3000;
pub const channel_stride: u32 = 0x100;
pub const channel_count: usize = 2;
pub const win_span: u32 = channel_stride * @as(u32, channel_count);

/// The two registers this model interprets.
pub const off_dadr: u32 = 0x00;
pub const off_dacr0: u32 = 0x04;

/// The fields dev's own masks name.
pub const field = struct {
    /// DADR's data field. The channel converts these twelve bits.
    pub const data: u32 = 0x0000_0FFF;
    /// DACR0.DACEN, the channel enable.
    pub const dacen: u32 = 0x0000_0001;
};

/// Words of a channel's window this model shadows rather than interprets.
const shadow_words: usize = channel_stride / 4;

/// One DAC_B channel: the code it holds, its control state, and what the run
/// should be told about the codes it was given.
pub const Channel = struct {
    /// DADR, masked to the data field on every store.
    code: u16 = 0,
    /// DACR0. Only bit 0 is read; the rest rides along untouched.
    dacr0: u32 = 0,
    shadow: [shadow_words]u32 = .{0} ** shadow_words,
    /// Codes accepted while the channel was enabled.
    outputs: u32 = 0,
    /// The largest code written while enabled.
    peak: u16 = 0,
    /// Codes written while DACEN was clear: stored, but not an output.
    dark: u32 = 0,

    pub fn enabled(self: *const Channel) bool {
        return self.dacr0 & field.dacen != 0;
    }

    pub fn quiet(self: *const Channel) bool {
        return self.outputs == 0 and self.dark == 0;
    }

    /// Take a code. Whether it counts as an output is DACEN's call, but the
    /// register latches either way: firmware can stage a code and enable the
    /// channel afterwards, and reading DADR back has to show what it staged.
    fn latch(self: *Channel, value: u32) void {
        self.code = @intCast(value & field.data);
        if (self.enabled()) {
            self.outputs +%= 1;
            if (self.code > self.peak) self.peak = self.code;
        } else {
            self.dark +%= 1;
        }
    }
};

pub const Dac = struct {
    channels: [channel_count]Channel = .{Channel{}} ** channel_count,

    pub fn init() Dac {
        return .{};
    }

    pub fn quiet(self: *const Dac) bool {
        for (&self.channels) |*unit| {
            if (!unit.quiet()) return false;
        }
        return true;
    }

    pub fn read(self: *Dac, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        const index = offset / channel_stride;
        if (index >= channel_count) return 0;
        const unit = &self.channels[index];
        const inner = offset % channel_stride;
        return switch (inner & ~@as(u32, 3)) {
            off_dadr => part(unit.code, inner % 4, width),
            off_dacr0 => part(unit.dacr0, inner % 4, width),
            else => part(unit.shadow[inner / 4], inner % 4, width),
        };
    }

    pub fn write(self: *Dac, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        const index = offset / channel_stride;
        if (index >= channel_count) return;
        const unit = &self.channels[index];
        const inner = offset % channel_stride;
        const byte = inner % 4;
        switch (inner & ~@as(u32, 3)) {
            off_dadr => unit.latch(merge(unit.code, byte, width, value)),
            off_dacr0 => unit.dacr0 = merge(unit.dacr0, byte, width, value),
            else => {
                const word = inner / 4;
                unit.shadow[word] = merge(unit.shadow[word], byte, width, value);
            },
        }
    }

    pub fn block(self: *Dac) periph.Block {
        return .{
            .name = "DAC_B",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// The part of a 32-bit register a narrow access names.
fn part(value: u32, byte_offset: u32, width: u3) u32 {
    if (width >= 4) return value;
    const shift: u5 = @intCast(byte_offset * 8);
    const shifted = value >> shift;
    return if (width == 1) shifted & 0xFF else shifted & 0xFFFF;
}

/// Fold a narrow write into a 32-bit register, leaving the bytes the access
/// does not name where they were.
fn merge(current: u32, byte_offset: u32, width: u3, value: u32) u32 {
    if (width >= 4) return value;
    const shift: u5 = @intCast(byte_offset * 8);
    const bits: u32 = if (width == 1) 0xFF else 0xFFFF;
    const window: u32 = bits << shift;
    return (current & ~window) | ((value & bits) << shift);
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Dac = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Dac = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The base address of one channel, so a test or a later slice does not do
/// the arithmetic itself.
pub fn channelAddress(index: usize) u32 {
    return win_base + @as(u32, @intCast(index)) * channel_stride;
}
