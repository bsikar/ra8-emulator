//! The shared DMA module bank at 0x4000_A800 (R_DMA): the activation gate
//! over all eight DMAC channels, and a shadow for the rest of it.
//!
//! Only the first register, DMAST.DMST, is modelled. It is the gate a driver
//! sets before arming any channel, and dev ignores it entirely: there the
//! whole bank is a transparent shadow, so an image that programmed a channel
//! and never started the module copies happily in the emulator and moves
//! nothing on a bench. The registers behind DMAST (DMECHR, the per-channel
//! event links) are shadowed rather than guessed at, because this part's
//! layout for them is not established here; an access to one reads back what
//! was written and does nothing else, and the count of those is reported.
const periph = @import("registry.zig");

pub const win_base: u32 = 0x4000_A800;
pub const win_span: u32 = 0xA0;

pub const off = struct {
    pub const dmast: u32 = 0x00;
};

pub const field = struct {
    /// DMAST.DMST b0: with this clear, no channel transfers.
    pub const dmst: u8 = 0x01;
};

pub const Bank = struct {
    dmast: u8 = 0,
    shadow: [win_span]u8 = [_]u8{0} ** win_span,
    /// Accesses to a register in this bank that is shadowed and not modelled.
    unmodelled: u32 = 0,

    pub fn init() Bank {
        return .{};
    }

    pub fn started(self: *const Bank) bool {
        return self.dmast & field.dmst != 0;
    }

    pub fn quiet(self: *const Bank) bool {
        return self.dmast == 0 and self.unmodelled == 0;
    }

    pub fn read(self: *Bank, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        if (offset == off.dmast) return self.dmast;
        self.unmodelled +%= 1;
        var value: u32 = 0;
        for (0..@as(usize, width)) |i| {
            const at = offset + i;
            if (at < win_span) value |= @as(u32, self.shadow[at]) << @intCast(8 * i);
        }
        return value;
    }

    pub fn write(self: *Bank, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        if (offset == off.dmast) {
            self.dmast = @truncate(value);
            return;
        }
        self.unmodelled +%= 1;
        for (0..@as(usize, width)) |i| {
            const at = offset + i;
            if (at < win_span) self.shadow[at] = @truncate(value >> @intCast(8 * i));
        }
    }

    pub fn block(self: *Bank) periph.Block {
        return .{
            .name = "DMA module",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Bank = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Bank = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
