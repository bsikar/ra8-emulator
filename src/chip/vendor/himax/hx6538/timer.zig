//! Arm CMSDK APB Timer (`TIMER0..8`) for the Himax HX6538 (`DDI0479`).
//!
//! Register map (`WE2_device_addr.h`, `timer_disasm.txt`):
//!   +0x00 CTRL      [0]=EN [1]=EXTIN_EN [2]=EXTIN_CLK [3]=IRQ_EN
//!   +0x04 VALUE     current 32-bit down-counter
//!   +0x08 RELOAD    reload value copied after reaching 0
//!   +0x0C INTSTATUS / INTCLEAR (RO status bit 0, W1C clear bit 0)
const registry = @import("../../../periph/registry.zig");

pub const channel_count: usize = 9;
pub const window_size: u32 = 0x1000;

pub const bases = [channel_count]u32{
    0x5500_A000,
    0x5500_B000,
    0x5500_C000,
    0x5500_D000,
    0x5500_E000,
    0x5500_F000,
    0x5600_9000,
    0x5600_A000,
    0x5600_B000,
};

pub const irqs = [channel_count]u16{ 34, 35, 36, 37, 38, 39, 47, 48, 49 };

pub const ctrl_bits = struct {
    pub const enable: u32 = 1 << 0;
    pub const irq_enable: u32 = 1 << 3;
    pub const write_mask: u32 = 0x0F;
};

pub const regs = struct {
    pub const ctrl: u32 = 0x00;
    pub const value: u32 = 0x04;
    pub const reload: u32 = 0x08;
    pub const int_status: u32 = 0x0C;
};

pub const Channel = struct {
    ctrl: u32 = 0,
    value: u32 = 0,
    reload: u32 = 0,
    int_pending: u32 = 0,

    pub fn block(self: *Channel, index: usize) registry.Block {
        return .{
            .name = "hx_timer",
            .base = bases[index],
            .size = window_size,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
            .peekFn = peekThunk,
        };
    }

    pub fn read(self: *const Channel, offset: u32) u32 {
        return switch (offset) {
            regs.ctrl => self.ctrl,
            regs.value => self.value,
            regs.reload => self.reload,
            regs.int_status => self.int_pending,
            else => 0,
        };
    }

    pub fn write(self: *Channel, offset: u32, val: u32) void {
        switch (offset) {
            regs.ctrl => self.ctrl = val & ctrl_bits.write_mask,
            regs.value => self.value = val,
            regs.reload => self.reload = val,
            regs.int_status => if (val & 1 != 0) {
                self.int_pending = 0;
            },
            else => {},
        }
    }

    pub fn tickCycles(self: *Channel, cycles_in: u64) bool {
        if (self.ctrl & ctrl_bits.enable == 0 or cycles_in == 0) return false;
        if (self.value == 0 and self.reload == 0) return false;
        var cycles = cycles_in;
        if (self.value == 0) {
            self.value = self.reload;
            cycles -= 1;
            if (cycles == 0) return false;
        }
        if (cycles <= self.value) {
            self.value -= @intCast(cycles);
            if (self.value == 0 and self.ctrl & ctrl_bits.irq_enable != 0) {
                self.int_pending = 1;
                return true;
            }
            return false;
        }
        return self.overflowTick(cycles);
    }

    fn overflowTick(self: *Channel, cycles: u64) bool {
        var after = cycles - self.value;
        var fired = false;
        if (self.ctrl & ctrl_bits.irq_enable != 0) {
            self.int_pending = 1;
            fired = true;
        }
        if (self.reload == 0) {
            self.value = 0;
        } else {
            const period = @as(u64, self.reload) + 1;
            after -= 1;
            self.value = @intCast(self.reload - (after % period));
        }
        return fired;
    }

    pub fn irqAsserted(self: *const Channel) bool {
        return self.int_pending != 0 and (self.ctrl & ctrl_bits.irq_enable != 0);
    }
};

pub const Bank = struct {
    channels: [channel_count]Channel = @splat(.{}),

    pub fn tick(self: *Bank, cycles: u64) void {
        for (&self.channels) |*ch| {
            _ = ch.tickCycles(cycles);
        }
    }
};

fn indexFor(address: u32) ?usize {
    for (bases, 0..) |base, idx| {
        if (address >= base and address < base + window_size) return idx;
    }
    return null;
}

fn readThunk(context: *anyopaque, address: u32, _: u3) u32 {
    const ch: *const Channel = @ptrCast(@alignCast(context));
    const idx = indexFor(address) orelse return 0;
    return ch.read(address - bases[idx]);
}

fn peekThunk(context: *anyopaque, address: u32, _: u3) u32 {
    const ch: *const Channel = @ptrCast(@alignCast(context));
    const idx = indexFor(address) orelse return 0;
    return ch.read(address - bases[idx]);
}

fn writeThunk(context: *anyopaque, address: u32, _: u3, value: u32) void {
    const ch: *Channel = @ptrCast(@alignCast(context));
    const idx = indexFor(address) orelse return;
    ch.write(address - bases[idx], value);
}
