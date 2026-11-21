//! Flash Cache and wait-cycle control (`FCACHE` at `0x4001_C100`).
//!
//! `R01UH1129EJ0110` §49.4.1–49.4.4 (pp. 1828–1830):
//! - `FCACHEE`  `+0x000` (16b, reset `0x0000`): bit 0 `FCACHEEN`
//! - `FCACHEIV` `+0x004` (16b, reset `0x0000`): bit 0 `FCACHEIV` (self-clearing invalidate)
//! - `FLWT`     `+0x01C` ( 8b, reset `0x00`  ): bits `[2:0]` flash wait states
//! - `FSAR`     `+0x040` (16b, reset `0x0000`): bits `0,1,8,9,10` security attribution (`PRC4`)
const bytelanes = @import("../../../periph/bytelanes.zig");
const periph = @import("../../../periph/registry.zig");
const prcr = @import("../../../periph/prcr.zig");

/// Base address and span (`FCACHE` `0x4001_C100`..`0x4001_C143`, NS `0x5001_C100`).
pub const win_base: u32 = 0x4001_C100;
pub const win_span: u32 = 0x44;

/// Byte offsets inside the `FCACHE` window.
pub const off = struct {
    pub const fcachee: u32 = 0x000;
    pub const fcacheiv: u32 = 0x004;
    pub const flwt: u32 = 0x01C;
    pub const fsar: u32 = 0x040;
};

/// Valid writable bit masks per register.
pub const mask = struct {
    pub const fcachee: u16 = 0x0001;
    pub const fcacheiv: u16 = 0x0001;
    pub const flwt: u8 = 0x07;
    pub const fsar: u16 = 0x0703;
};

/// Flash cache enable, invalidate, wait-state, and security-attribution block.
pub const Fcache = struct {
    protection: ?*const prcr.Prcr = null,
    fcachee: u16 = 0,
    flwt: u8 = 0,
    fsar: u16 = 0,
    invalidations: u32 = 0,
    stores: u32 = 0,
    dropped_locked: u32 = 0,

    pub fn init(protection: ?*const prcr.Prcr) Fcache {
        return .{ .protection = protection };
    }

    pub fn quiet(self: *const Fcache) bool {
        return self.stores == 0 and self.dropped_locked == 0 and self.invalidations == 0;
    }

    pub fn read(self: *const Fcache, address: u32, width: u3) u32 {
        const base = address -% win_base;
        var answer: u32 = 0;
        var lane: u32 = 0;
        while (lane < bytelanes.span(width)) : (lane += 1) {
            answer = bytelanes.place(answer, self.readByte(base + lane), lane);
        }
        return answer;
    }

    pub fn write(self: *Fcache, address: u32, width: u3, value: u32) void {
        const base = address -% win_base;
        if (base >= off.fsar and base < off.fsar + 2 and !self.sarUnlocked()) {
            self.dropped_locked +%= 1;
            return;
        }
        var wrote = false;
        var lane: u32 = 0;
        while (lane < bytelanes.span(width)) : (lane += 1) {
            if (self.writeByte(base + lane, bytelanes.byteAt(value, lane))) wrote = true;
        }
        if (wrote) self.stores +%= 1;
    }

    pub fn block(self: *Fcache) periph.Block {
        return .{
            .name = "FCACHE",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }

    fn sarUnlocked(self: *const Fcache) bool {
        const prot = self.protection orelse return true;
        return prot.unlocked(prcr.group.sar);
    }

    fn readByte(self: *const Fcache, offset: u32) u8 {
        return switch (offset) {
            off.fcachee => @truncate(self.fcachee),
            off.flwt => self.flwt,
            off.fsar => @truncate(self.fsar),
            off.fsar + 1 => @truncate(self.fsar >> 8),
            else => 0,
        };
    }

    fn writeByte(self: *Fcache, offset: u32, byte: u8) bool {
        switch (offset) {
            off.fcachee => self.fcachee = byte & @as(u8, @truncate(mask.fcachee)),
            off.fcacheiv => if (byte & @as(u8, @truncate(mask.fcacheiv)) != 0) {
                self.invalidations +%= 1;
            },
            off.flwt => self.flwt = byte & mask.flwt,
            off.fsar => self.fsar = (self.fsar & 0xFF00) | (byte & 0x03),
            off.fsar + 1 => self.fsar = (self.fsar & 0x00FF) | (@as(u16, byte & 0x07) << 8),
            else => return false,
        }
        return true;
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Fcache = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Fcache = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
