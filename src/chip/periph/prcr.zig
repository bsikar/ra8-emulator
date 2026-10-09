//! PRCR: the SYSC write-protection register, so a locked write vanishes.
//!
//! The RA8D2 gates *writes* to whole families of SYSC-adjacent registers behind
//! one 16-bit register at 0x4001_E3FA (HUM Ch 13 "Register Write Protection
//! Function", Table 13.1 p 520-521). A write issued to a protected register
//! while its group bit is 0 is discarded by the hardware with no fault and no
//! status flag: the register simply keeps its old value. Reads are never gated.
//!
//! That silence is the whole reason to model it. The C tree's issue #131 was a
//! driver writing the entire VBATT backup file with PRCR locked: on silicon
//! every write vanished and the demo reported rw=BAD, while the emulator, which
//! modelled no protection at all, reported rw=ok. The emulator passed where the
//! bench failed. Ported from board_periph_prcr.c on dev.
//!
//!   PRCR (+0x00, 16b)  PRKEY[15:8] write key, PRC0/1/3/4/5 group bits
//!
//! This block owns its window rather than snooping it, which is the one place
//! it diverges from dev: dev leaves PRCR reads to the sparse register file, so
//! a read-back there returns the whole word the firmware wrote, key byte and
//! all. HUM Ch 13.2.1 p 522 makes PRKEY write-only, so a read here returns the
//! retained group bits with the key reading zero.
const periph = @import("registry.zig");

/// PRCR geometry (HUM Ch 13.2.1 p 522): SYSC base 0x4001_E000 + 0x3FA.
pub const win_base: u32 = 0x4001_E3FA;
pub const win_span: u32 = 0x2;

/// PRKEY[7:0] lives in bits 15:8 and every write has to carry 0xA5.
pub const key = struct {
    pub const mask: u16 = 0xFF00;
    pub const value: u16 = 0xA500;
};

/// The group bits PRCR retains. Bit 2 and bits 7:6 are reserved and read zero.
pub const group = struct {
    /// PRC0: the clock generation circuit.
    pub const cgc: u16 = 0x0001;
    /// PRC1: low-power modes and the VBATT backup file.
    pub const lpm: u16 = 0x0002;
    /// PRC3: the power-voltage detector.
    pub const pvd: u16 = 0x0008;
    /// PRC4: security and privilege attribution.
    pub const sar: u16 = 0x0010;
    /// PRC5: reset control.
    pub const rst: u16 = 0x0020;
    pub const all: u16 = cgc | lpm | pvd | sar | rst;
};

/// The live unlock mask, plus the counters behind the end-of-run line.
pub const Prcr = struct {
    groups: u16 = 0,
    unlocks: u32 = 0,
    bad_key: u32 = 0,

    pub fn init() Prcr {
        return .{};
    }

    /// Untouched units stay out of the end-of-run report.
    pub fn quiet(self: *const Prcr) bool {
        return self.unlocks == 0 and self.bad_key == 0;
    }

    /// Whether every group in `mask` is write-enabled right now. This is the
    /// question a protected block asks before it accepts a store.
    pub fn unlocked(self: *const Prcr, mask: u16) bool {
        return self.groups & mask == mask;
    }

    pub fn read(self: *Prcr, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        // PRKEY is write-only, so only the group byte answers.
        const word: u16 = self.groups;
        if (width >= 2 and offset == 0) return word;
        const shift: u4 = @intCast((offset & 1) * 8);
        return (@as(u32, word) >> shift) & 0xFF;
    }

    pub fn write(self: *Prcr, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        // A byte store to the low half carries no key byte, so it can never
        // satisfy PRKEY and silicon drops it. Counting it as a bad key is the
        // honest answer: the firmware asked for an unlock it did not get.
        const word: u16 = if (width >= 2 and offset == 0)
            @truncate(value)
        else blk: {
            const shift: u4 = @intCast((offset & 1) * 8);
            break :blk @as(u16, @truncate(value & 0xFF)) << shift;
        };
        if (word & key.mask != key.value) {
            self.bad_key +%= 1;
            return;
        }
        self.groups = word & group.all;
        if (self.groups != 0) self.unlocks +%= 1;
    }

    pub fn block(self: *Prcr) periph.Block {
        return .{
            .name = "SYSC-PRCR",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Prcr = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Prcr = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The word a firmware writes to unlock exactly `mask` and nothing else.
pub fn unlockWord(mask: u16) u16 {
    return key.value | (mask & group.all);
}
