//! The ITM as firmware drives it: the stimulus ports STIM0..31 at
//! 0xE000_0000, and the ITM_TER, ITM_TPR and ITM_TCR controls above them.
//!
//! CMSIS `ITM_SendChar` checks ITM_TCR.ITMENA and ITM_TER bit 0, waits for
//! STIM0 to read FIFOREADY, then stores the character to STIM0. That is
//! how firmware printf reaches a debugger with no UART, so the model keeps
//! what port 0 was sent as text, for the debugger to show. Stores to the
//! other enabled ports are only counted for now. A stimulus port always
//! reads FIFOREADY: the modelled FIFO never fills.
//!
//! The session writes the text out a line at a time after each run, and
//! the rest when it ends.
//!
//! Each core has its own ITM. The PPB is plain memory, so after a store the
//! debug core writes these registers back the way a read should see them.
const std = @import("std");

pub const base: u32 = 0xE000_0000;

pub const offsets = struct {
    pub const stim0: u32 = 0x000;
    pub const ter: u32 = 0xE00;
    pub const tpr: u32 = 0xE40;
    pub const tcr: u32 = 0xE80;
};

pub const limits = struct {
    pub const ports: u32 = 32;
    /// One past the last register, from `base`.
    pub const span: u32 = offsets.tcr + 4;
    /// Port 0 text kept before further characters are dropped.
    pub const capacity: usize = 4096;
};

pub const tcr_bits = struct {
    pub const itmena: u32 = 1 << 0;
    /// BUSY reads zero: nothing is ever in flight.
    pub const busy: u32 = 1 << 23;
};

/// What a stimulus port reads: FIFOREADY.
pub const fifo_ready: u32 = 1;

pub const Itm = struct {
    ter: u32 = 0,
    tpr: u32 = 0,
    tcr: u32 = 0,
    text: std.BoundedArray(u8, limits.capacity) = .{},
    /// Port 0 characters that arrived with the text already full.
    dropped: usize = 0,
    /// Stores that reached an enabled port other than 0.
    other_ports: usize = 0,
    /// A register changed since memory last showed the register file.
    changed: bool = false,

    /// The register at `offset` as a read sees it, or null when the
    /// offset is not one of the ITM's registers.
    pub fn peek(self: *const Itm, offset: u32) ?u32 {
        if (stimPort(offset)) |_| return fifo_ready;
        return switch (offset) {
            offsets.ter => self.ter,
            offsets.tpr => self.tpr,
            offsets.tcr => self.tcr,
            else => null,
        };
    }

    /// Store `width` bytes of `value` to the register at `offset`. False
    /// when it is not one of the ITM's registers.
    pub fn write(self: *Itm, offset: u32, value: u32, width: u8) bool {
        if (stimPort(offset)) |port| {
            self.stimulus(port, value, width);
        } else switch (offset) {
            offsets.ter => self.ter = value,
            offsets.tpr => self.tpr = value & 0xF,
            offsets.tcr => self.tcr = value & ~tcr_bits.busy,
            else => return false,
        }
        self.changed = true;
        return true;
    }

    /// What port 0 has been sent so far.
    pub fn output(self: *const Itm) []const u8 {
        return self.text.constSlice();
    }

    /// Write each complete line port 0 has been sent as "itm: <line>",
    /// and keep an unfinished line for later. With `all`, or once the text
    /// is full, the unfinished line is written too.
    pub fn flush(self: *Itm, out: anytype, all: bool) !void {
        const text = self.text.constSlice();
        var done: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, done, '\n')) |end| {
            try out.print("itm: {s}\n", .{std.mem.trimRight(u8, text[done..end], "\r")});
            done = end + 1;
        }
        if ((all or text.len == limits.capacity) and done < text.len) {
            try out.print("itm: {s}\n", .{text[done..]});
            done = text.len;
        }
        if (self.dropped != 0) try out.print("itm: ({d} characters dropped)\n", .{self.dropped});
        self.dropped = 0;
        const rest = text.len - done;
        std.mem.copyForwards(u8, self.text.buffer[0..rest], text[done..]);
        self.text.len = rest;
    }

    /// Forget the port 0 text, once the debugger has shown it.
    pub fn clear(self: *Itm) void {
        self.text.len = 0;
        self.dropped = 0;
    }

    fn stimulus(self: *Itm, port: u32, value: u32, width: u8) void {
        if (self.tcr & tcr_bits.itmena == 0) return;
        if ((self.ter >> @intCast(port)) & 1 == 0) return;
        if (port != 0) {
            self.other_ports += 1;
            return;
        }
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        for (bytes[0..@min(width, bytes.len)]) |byte| {
            self.text.append(byte) catch {
                self.dropped += 1;
            };
        }
    }
};

fn stimPort(offset: u32) ?u32 {
    if (offset >= limits.ports * 4 or offset % 4 != 0) return null;
    return offset / 4;
}
