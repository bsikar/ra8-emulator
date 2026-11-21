//! Himax HX6538 dual-core IPC Mailbox (`MAILBOX` at `0x4400_A000` / `0x5400_A000`).
//!
//! Layout from `hx_drv_mb.h` and `libdriver.a`:
//!   +0x000  CM55M_STATUS (RO)  pending IRQ bitmap for CM55M (`IRQ7`)
//!   +0x004  CM55M_TRIG   (WO)  write 1s to assert bits in CM55M_STATUS
//!   +0x008  CM55M_CLR    (W1C) write 1s to clear bits in CM55M_STATUS
//!   +0x010  CM55S_STATUS (RO)  pending IRQ bitmap for CM55S (`IRQ7`)
//!   +0x014  CM55S_TRIG   (WO)  write 1s to assert bits in CM55S_STATUS
//!   +0x018  CM55S_CLR    (W1C) write 1s to clear bits in CM55S_STATUS
//!   +0x100..+0x15C  24 x 32-bit shared mailbox words
//!   +0x200..+0x25C  24 x atomic hardware mutexes (1=free/claim-on-read, write 1=release)
const registry = @import("../../../periph/registry.zig");

pub const base: u32 = 0x5400_A000;
pub const size: u32 = 0x1000;
pub const irq_line: u16 = 7;
pub const share_count: usize = 24;
pub const mutex_count: usize = 24;

pub const regs = struct {
    pub const cm55m_status: u32 = 0x000;
    pub const cm55m_trig: u32 = 0x004;
    pub const cm55m_clr: u32 = 0x008;
    pub const cm55s_status: u32 = 0x010;
    pub const cm55s_trig: u32 = 0x014;
    pub const cm55s_clr: u32 = 0x018;
    pub const share_base: u32 = 0x100;
    pub const mutex_base: u32 = 0x200;
};

pub const Mailbox = struct {
    cm55m_status: u32 = 0,
    cm55s_status: u32 = 0,
    share: [share_count]u32 = @splat(0),
    mutex: [mutex_count]u32 = @splat(1),

    pub fn block(self: *Mailbox) registry.Block {
        return .{
            .name = "hx_mailbox",
            .base = base,
            .size = size,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
            .peekFn = peekThunk,
        };
    }

    pub fn pendingM(self: *const Mailbox) bool {
        return self.cm55m_status != 0;
    }

    pub fn pendingS(self: *const Mailbox) bool {
        return self.cm55s_status != 0;
    }

    pub fn read(self: *Mailbox, offset: u32) u32 {
        return switch (offset) {
            regs.cm55m_status, regs.cm55m_clr => self.cm55m_status,
            regs.cm55s_status, regs.cm55s_clr => self.cm55s_status,
            else => self.readArray(offset),
        };
    }

    pub fn peek(self: *const Mailbox, offset: u32) u32 {
        return switch (offset) {
            regs.cm55m_status, regs.cm55m_clr => self.cm55m_status,
            regs.cm55s_status, regs.cm55s_clr => self.cm55s_status,
            else => self.peekArray(offset),
        };
    }

    pub fn write(self: *Mailbox, offset: u32, value: u32) void {
        switch (offset) {
            regs.cm55m_trig => self.cm55m_status |= value,
            regs.cm55m_clr => self.cm55m_status &= ~value,
            regs.cm55s_trig => self.cm55s_status |= value,
            regs.cm55s_clr => self.cm55s_status &= ~value,
            else => self.writeArray(offset, value),
        }
    }

    fn readArray(self: *Mailbox, offset: u32) u32 {
        if (shareIndex(offset)) |idx| return self.share[idx];
        if (mutexIndex(offset)) |idx| {
            const prev = self.mutex[idx];
            if (prev != 0) self.mutex[idx] = 0;
            return prev;
        }
        return 0;
    }

    fn peekArray(self: *const Mailbox, offset: u32) u32 {
        if (shareIndex(offset)) |idx| return self.share[idx];
        if (mutexIndex(offset)) |idx| return self.mutex[idx];
        return 0;
    }

    fn writeArray(self: *Mailbox, offset: u32, value: u32) void {
        if (shareIndex(offset)) |idx| {
            self.share[idx] = value;
            return;
        }
        if (mutexIndex(offset)) |idx| {
            if (value & 1 != 0) self.mutex[idx] = 1;
        }
    }

    fn shareIndex(offset: u32) ?usize {
        if (offset < regs.share_base or offset >= regs.share_base + share_count * 4) return null;
        if (offset & 3 != 0) return null;
        return (offset - regs.share_base) / 4;
    }

    fn mutexIndex(offset: u32) ?usize {
        if (offset < regs.mutex_base or offset >= regs.mutex_base + mutex_count * 4) return null;
        if (offset & 3 != 0) return null;
        return (offset - regs.mutex_base) / 4;
    }
};

fn readThunk(context: *anyopaque, address: u32, _: u3) u32 {
    const self: *Mailbox = @ptrCast(@alignCast(context));
    return self.read(address - base);
}

fn peekThunk(context: *anyopaque, address: u32, _: u3) u32 {
    const self: *const Mailbox = @ptrCast(@alignCast(context));
    return self.peek(address - base);
}

fn writeThunk(context: *anyopaque, address: u32, _: u3, value: u32) void {
    const self: *Mailbox = @ptrCast(@alignCast(context));
    self.write(address - base, value);
}
