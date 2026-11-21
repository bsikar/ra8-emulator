//! RA4T1 Timers: `GPT16E0..5` (`0x4016_9000`, stride `0x100`) and
//! `AGT0..1` (`0x400E_8000`, stride `0x100`)
//! (R01UH0999EJ0140 Rev.1.40 Ch. 20 & Ch. 21; RA8EMU-A-71).
//!
//! Models 16-bit up-counting `GPT16E` channels with overflow ICU events
//! (`0x0C6 + 11 * ch`) and 16-bit down-counting `AGT` channels with underflow
//! ICU events (`0x040 + 3 * ch`).
const chip = @import("../../../root.zig");

const registry = chip.periph.registry;

pub const gpt_base: u32 = 0x4016_9000;
pub const gpt_channels: usize = 6;
pub const gpt_size: u32 = @intCast(gpt_channels * 0x100);

pub const agt_base: u32 = 0x400E_8000;
pub const agt_channels: usize = 2;
pub const agt_size: u32 = @intCast(agt_channels * 0x100);

pub const Due = struct {
    items: [16]u16 = @splat(0),
    len: usize = 0,

    pub fn push(self: *Due, event: u16) void {
        if (self.len < self.items.len) {
            self.items[self.len] = event;
            self.len += 1;
        }
    }

    pub fn slice(self: *const Due) []const u16 {
        return self.items[0..self.len];
    }
};

pub const gpt_ofs = struct {
    pub const gtwp: u32 = 0x00;
    pub const gtstr: u32 = 0x04;
    pub const gtstp: u32 = 0x08;
    pub const gtclr: u32 = 0x0C;
    pub const gtcr: u32 = 0x2C;
    pub const gtuddtyc: u32 = 0x30;
    pub const gtst: u32 = 0x3C;
    pub const gtcnt: u32 = 0x48;
    pub const gtccra: u32 = 0x4C;
    pub const gtccrb: u32 = 0x50;
    pub const gtpr: u32 = 0x64;
};

pub const agt_ofs = struct {
    pub const agt: u32 = 0x00;
    pub const agtcma: u32 = 0x02;
    pub const agtcmb: u32 = 0x04;
    pub const agtcr: u32 = 0x08;
    pub const agtmr1: u32 = 0x09;
    pub const agtmr2: u32 = 0x0A;
};

pub const GptChannel = struct {
    gtwp: u32 = 0,
    gtcr: u32 = 0,
    gtuddtyc: u32 = 1,
    gtst: u32 = 0,
    gtcnt: u16 = 0,
    gtccra: u16 = 0xFFFF,
    gtccrb: u16 = 0xFFFF,
    gtpr: u16 = 0xFFFF,
    wraps: u64 = 0,
    rem_ns: u64 = 0,

    pub fn running(self: *const GptChannel) bool {
        return (self.gtcr & 1) != 0;
    }

    pub fn writeProtected(self: *const GptChannel) bool {
        return (self.gtwp & 1) != 0;
    }

    pub fn prescaleShift(self: *const GptChannel) u5 {
        const tpcs: u3 = @truncate(self.gtcr >> 24);
        return switch (tpcs) {
            0 => 0,
            1 => 2,
            2 => 4,
            3 => 6,
            4 => 8,
            5 => 10,
            else => 0,
        };
    }

    pub fn tick(self: *GptChannel, elapsed_ns: u64, pclkd_hz: u32) bool {
        if (!self.running()) return false;
        const hz = @max(@as(u64, 1), pclkd_hz) >> self.prescaleShift();
        const scaled = self.rem_ns + elapsed_ns * @max(@as(u64, 1), hz);
        const ticks = scaled / 1_000_000_000;
        self.rem_ns = scaled % 1_000_000_000;
        if (ticks == 0) return false;
        const period: u64 = @as(u64, self.gtpr) + 1;
        const sum = @as(u64, self.gtcnt) + ticks;
        if (sum < period) {
            self.gtcnt = @intCast(sum);
            return false;
        }
        self.wraps +%= sum / period;
        self.gtcnt = @intCast(sum % period);
        self.gtst |= 1 << 6; // TCFPO
        return true;
    }
};

pub const AgtChannel = struct {
    agt: u16 = 0xFFFF,
    reload: u16 = 0xFFFF,
    agtcma: u16 = 0xFFFF,
    agtcmb: u16 = 0xFFFF,
    agtcr: u8 = 0,
    agtmr1: u8 = 0,
    agtmr2: u8 = 0,
    underflows: u64 = 0,
    rem_ns: u64 = 0,

    pub fn running(self: *const AgtChannel) bool {
        return (self.agtcr & 0x01) != 0;
    }

    pub fn tick(self: *AgtChannel, elapsed_ns: u64, pclkb_hz: u32) bool {
        if (!self.running()) return false;
        const src_hz = self.sourceHz(pclkb_hz);
        const scaled = self.rem_ns + elapsed_ns * src_hz;
        const ticks = scaled / 1_000_000_000;
        self.rem_ns = scaled % 1_000_000_000;
        if (ticks == 0) return false;
        const period: u64 = @as(u64, self.reload) + 1;
        if (ticks <= self.agt) {
            self.agt -= @intCast(ticks);
            return false;
        }
        const past = ticks - @as(u64, self.agt) - 1;
        self.underflows +%= 1 + (past / period);
        self.agt = @intCast(self.reload - (past % period));
        self.agtcr |= 1 << 5; // TUNDF
        return true;
    }

    fn sourceHz(self: *const AgtChannel, pclkb_hz: u32) u64 {
        const tck: u3 = @truncate((self.agtmr1 >> 4) & 0x07);
        const base_hz: u64 = switch (tck) {
            0 => @max(@as(u64, 1), pclkb_hz),
            1 => @max(@as(u64, 1), pclkb_hz / 8),
            3 => @max(@as(u64, 1), pclkb_hz / 2),
            4, 6 => 32_768,
            else => @max(@as(u64, 1), pclkb_hz),
        };
        const cks: u3 = @truncate(self.agtmr2 & 0x07);
        return @max(@as(u64, 1), base_hz >> cks);
    }
};

pub const Timers = struct {
    gpt: [gpt_channels]GptChannel = @splat(.{}),
    agt: [agt_channels]AgtChannel = @splat(.{}),
    due: Due = .{},

    pub fn init() Timers {
        return .{};
    }

    pub fn gptBlock(self: *Timers) registry.Block {
        return .{
            .name = "RA4T1 GPT16E",
            .base = gpt_base,
            .size = gpt_size,
            .context = self,
            .readFn = readGptThunk,
            .writeFn = writeGptThunk,
            .peekFn = readGptThunk,
        };
    }

    pub fn agtBlock(self: *Timers) registry.Block {
        return .{
            .name = "RA4T1 AGT",
            .base = agt_base,
            .size = agt_size,
            .context = self,
            .readFn = readAgtThunk,
            .writeFn = writeAgtThunk,
            .peekFn = readAgtThunk,
        };
    }

    pub fn tick(self: *Timers, elapsed_ns: u64, pclkd_hz: u32, pclkb_hz: u32) void {
        for (&self.gpt, 0..) |*ch, idx| {
            if (ch.tick(elapsed_ns, pclkd_hz)) {
                self.due.push(@intCast(0x0C6 + idx * 11));
            }
        }
        for (&self.agt, 0..) |*ch, idx| {
            if (ch.tick(elapsed_ns, pclkb_hz)) {
                self.due.push(@intCast(0x040 + idx * 3));
            }
        }
    }

    pub fn takeEvents(self: *Timers) Due {
        const snapshot = self.due;
        self.due = .{};
        return snapshot;
    }

    fn readGptThunk(ctx: *anyopaque, address: u32, width: u3) u32 {
        const self: *const Timers = @ptrCast(@alignCast(ctx));
        return self.readGpt(address, width);
    }

    fn writeGptThunk(ctx: *anyopaque, address: u32, width: u3, value: u32) void {
        const self: *Timers = @ptrCast(@alignCast(ctx));
        self.writeGpt(address, width, value);
    }

    pub fn readGpt(self: *const Timers, address: u32, _: u3) u32 {
        if (address < gpt_base or address - gpt_base >= gpt_size) return 0;
        const off = address - gpt_base;
        const idx = off >> 8;
        if (idx >= gpt_channels) return 0;
        const reg = off & 0xFF;
        const ch = &self.gpt[idx];
        return switch (reg) {
            gpt_ofs.gtwp => ch.gtwp,
            gpt_ofs.gtstr => self.runningMask(),
            gpt_ofs.gtcr => ch.gtcr,
            gpt_ofs.gtuddtyc => ch.gtuddtyc,
            gpt_ofs.gtst => ch.gtst,
            gpt_ofs.gtcnt => ch.gtcnt,
            gpt_ofs.gtccra => ch.gtccra,
            gpt_ofs.gtccrb => ch.gtccrb,
            gpt_ofs.gtpr => ch.gtpr,
            else => 0,
        };
    }

    fn runningMask(self: *const Timers) u32 {
        var mask: u32 = 0;
        for (self.gpt, 0..) |ch, i| {
            if (ch.running()) mask |= @as(u32, 1) << @intCast(i);
        }
        return mask;
    }

    pub fn writeGpt(self: *Timers, address: u32, _: u3, value: u32) void {
        if (address < gpt_base or address - gpt_base >= gpt_size) return;
        const off = address - gpt_base;
        const idx = off >> 8;
        if (idx >= gpt_channels) return;
        const reg = off & 0xFF;
        const ch = &self.gpt[idx];
        if (reg == gpt_ofs.gtwp) {
            if ((value >> 8) == 0xA5) ch.gtwp = value & 0x01;
            return;
        }
        if (ch.writeProtected()) return;
        self.writeGptReg(ch, reg, value);
    }

    fn writeGptReg(self: *Timers, ch: *GptChannel, reg: u32, value: u32) void {
        switch (reg) {
            gpt_ofs.gtstr => self.setRunningMask(value, true),
            gpt_ofs.gtstp => self.setRunningMask(value, false),
            gpt_ofs.gtclr => self.clearMask(value),
            gpt_ofs.gtcr => ch.gtcr = value,
            gpt_ofs.gtuddtyc => ch.gtuddtyc = value,
            gpt_ofs.gtst => ch.gtst &= value,
            gpt_ofs.gtcnt => ch.gtcnt = @truncate(value),
            gpt_ofs.gtccra => ch.gtccra = @truncate(value),
            gpt_ofs.gtccrb => ch.gtccrb = @truncate(value),
            gpt_ofs.gtpr => ch.gtpr = @truncate(value),
            else => {},
        }
    }

    fn setRunningMask(self: *Timers, mask: u32, start: bool) void {
        for (&self.gpt, 0..) |*ch, i| {
            if ((mask & (@as(u32, 1) << @intCast(i))) == 0) continue;
            if (start) ch.gtcr |= 1 else ch.gtcr &= ~@as(u32, 1);
        }
    }

    fn clearMask(self: *Timers, mask: u32) void {
        for (&self.gpt, 0..) |*ch, i| {
            if ((mask & (@as(u32, 1) << @intCast(i))) == 0) continue;
            ch.gtcnt = 0;
        }
    }

    fn readAgtThunk(ctx: *anyopaque, address: u32, width: u3) u32 {
        const self: *const Timers = @ptrCast(@alignCast(ctx));
        return self.readAgt(address, width);
    }

    fn writeAgtThunk(ctx: *anyopaque, address: u32, width: u3, value: u32) void {
        const self: *Timers = @ptrCast(@alignCast(ctx));
        self.writeAgt(address, width, value);
    }

    pub fn readAgt(self: *const Timers, address: u32, width: u3) u32 {
        if (address < agt_base or address - agt_base >= agt_size) return 0;
        const off = address - agt_base;
        const idx = off >> 8;
        if (idx >= agt_channels) return 0;
        const ch = &self.agt[idx];
        const val: u32 = switch (off & 0xFF) {
            agt_ofs.agt => ch.agt,
            agt_ofs.agtcma => ch.agtcma,
            agt_ofs.agtcmb => ch.agtcmb,
            agt_ofs.agtcr => ch.agtcr,
            agt_ofs.agtmr1 => ch.agtmr1,
            agt_ofs.agtmr2 => ch.agtmr2,
            else => 0,
        };
        return if (width == 1) val & 0xFF else val & 0xFFFF;
    }

    pub fn writeAgt(self: *Timers, address: u32, _: u3, value: u32) void {
        if (address < agt_base or address - agt_base >= agt_size) return;
        const off = address - agt_base;
        const idx = off >> 8;
        if (idx >= agt_channels) return;
        const ch = &self.agt[idx];
        switch (off & 0xFF) {
            agt_ofs.agt => {
                ch.reload = @truncate(value);
                if (!ch.running()) ch.agt = ch.reload;
            },
            agt_ofs.agtcma => ch.agtcma = @truncate(value),
            agt_ofs.agtcmb => ch.agtcmb = @truncate(value),
            agt_ofs.agtcr => self.writeAgtCr(ch, @truncate(value)),
            agt_ofs.agtmr1 => ch.agtmr1 = @truncate(value),
            agt_ofs.agtmr2 => ch.agtmr2 = @truncate(value),
            else => {},
        }
    }

    fn writeAgtCr(_: *Timers, ch: *AgtChannel, byte: u8) void {
        if ((byte & 0x04) != 0) {
            ch.agtcr &= ~@as(u8, 0x03);
            ch.agt = ch.reload;
            return;
        }
        const run_bits = if ((byte & 0x01) != 0) @as(u8, 0x03) else @as(u8, 0x00);
        const kept_flags = ch.agtcr & (byte & 0xE0);
        ch.agtcr = kept_flags | run_bits;
    }
};
