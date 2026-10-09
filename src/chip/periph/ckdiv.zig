//! The peripheral clock dividers that sit beside the source selects.
//!
//! Seven 8-bit registers, one per select modelled in ckcr.zig, scale the
//! branch after the source is chosen (ra8_system_regs.h, the
//! `k_ra8_sys_off_*ckdivcr` run):
//!
//!   SCICKDIVCR   (+0x054)  beside SCICKCR    (+0x055)
//!   USBCKDIVCR   (+0x06C)  beside USBCKCR    (+0x074)
//!   OCTACKDIVCR  (+0x06D)  beside OCTACKCR   (+0x075)  HUM Ch 9.2.40 p 357
//!   CANFDCKDIVCR (+0x06E)  beside CANFDCKCR  (+0x076)  HUM Ch 9.2.41 p 363
//!   USB60CKDIVCR (+0x06F)  beside USB60CKCR  (+0x077)
//!   ESWCKDIVCR   (+0x0D5)  beside ESWCKCR    (+0x0DB)
//!   ESWPCKDIVCR  (+0x0D6)  beside ESWPCKCR   (+0x0DC)
//!
//! CKDIV is bits 3:0 and the rest of the byte is reserved, so a read gives
//! back the code alone. The code is a ratio, not a shift: ra8_cgc.c calls
//! it "the same code-to-ratio map as PLODIV: code N selects /N+1 for codes
//! 0..5, /8 = 7, /9 = 8, /16 = 15", and ra8_cgc_eswclk.c's own enum agrees
//! for its half of the range. NO RATE IS DERIVED HERE: nothing downstream
//! of this model reads a frequency, so the code is retained, reported and
//! left at that. Naming the ratio would be inventing a clock tree.
//!
//! A DIVIDER IS WRITTEN INSIDE THE SWITCH WINDOW, NOT WHENEVER. The HUM
//! "Clock Selection Switching Procedure" puts it at step 3, between the
//! wait for SRDY = 1 and the write of SEL, and the firmware writes that
//! sequence out four separate times: ra8_cgc.h step 3 "Write ESWCKDIVCR"
//! and step 3 "Write USBCKDIVCR", both between the two waits;
//! ra8_cgc_eswclk.c's inline step 3 "Programme CKDIVCR (peripheral clock
//! now stopped)"; and internal_route_sciclk, which writes `*divcr` only
//! after ra8_hw_wait_flag_set8 has seen CKSRDY. ra8_cgc.h says what the
//! window is FOR in so many words: after reset "the source-select
//! handshake (CKSREQ -> CKSRDY) must still be exercised for the divider
//! write to take effect". So a store that arrives while the paired branch
//! is running does not take: it is counted and the code is left alone, and
//! the driver can come back inside the window. Reads are never gated.
//!
//! TWO IN-TREE CALLERS WRITE THEIRS EARLY, and the report names them rather
//! than hiding it: ra8_xspi.c internal_xspi_clock_block_init and
//! ra8_canfd.c internal_canfd_clock_block_init both set the divider before
//! they assert SREQ, not after SRDY. Both write 0, which is /1 and is the
//! reset code, so the branch ends up where they wanted it either way and
//! neither is broken today; ra8_cgc.h says the surrounding precondition is
//! needed "whenever USBCKDIVCR is moved off 1/1", which is exactly the case
//! these two avoid. The counter is what would catch the day one of them
//! moves off /1.
//!
//! PRC0 gates these the way it gates the selects: they are the same clock
//! generation family behind the same bit, so a store with PRCR locked is
//! dropped silently (ra8_lpm.h, "discarded silently by the hardware").
//! The order is protection first, then the window: a store nobody was
//! allowed to make never reaches the question of when it was made.
const ckcr = @import("ckcr.zig");
const periph = @import("registry.zig");
const prcr = @import("prcr.zig");

/// One divider: where it answers, what to call it, and the select whose
/// switch window it is written inside.
pub const Slot = struct {
    address: u32,
    name: []const u8,
    select: u32,
};

/// Every divider this model answers for, in address order.
pub const slots = [_]Slot{
    .{ .address = 0x4001_E054, .name = "SCICKDIVCR", .select = 0x4001_E055 },
    .{ .address = 0x4001_E06C, .name = "USBCKDIVCR", .select = 0x4001_E074 },
    .{ .address = 0x4001_E06D, .name = "OCTACKDIVCR", .select = 0x4001_E075 },
    .{ .address = 0x4001_E06E, .name = "CANFDCKDIVCR", .select = 0x4001_E076 },
    .{ .address = 0x4001_E06F, .name = "USB60CKDIVCR", .select = 0x4001_E077 },
    .{ .address = 0x4001_E0D5, .name = "ESWCKDIVCR", .select = 0x4001_E0DB },
    .{ .address = 0x4001_E0D6, .name = "ESWPCKDIVCR", .select = 0x4001_E0DC },
};

/// A run of adjacent dividers, which is what goes on the bus. The gaps
/// belong to other registers, the selects among them, and are left alone.
pub const Window = struct {
    base: u32,
    span: u32,
};

pub const windows = [_]Window{
    .{ .base = 0x4001_E054, .span = 1 },
    .{ .base = 0x4001_E06C, .span = 4 },
    .{ .base = 0x4001_E0D5, .span = 2 },
};

/// Which divider answers at an address, if any.
pub fn indexOf(address: u32) ?usize {
    for (&slots, 0..) |one, index| {
        if (one.address == address) return index;
    }
    return null;
}

pub const field = struct {
    /// CKDIV, bits 3:0. The rest of the byte is reserved and reads zero.
    pub const ckdiv: u8 = 0x0F;
};

/// The group these sit behind: PRC0, the clock generation circuit.
pub const guard: u16 = ckcr.guard;

/// One divider: the retained code and what the run did to it.
pub const Divider = struct {
    /// Reset is 0, which is /1 on the shared code-to-ratio map.
    code: u8 = 0,
    /// Stores that landed inside the paired branch's switch window.
    writes: u32 = 0,
    /// Stores that arrived while the branch was running, which do not take.
    ungated: u32 = 0,

    pub fn value(self: *const Divider) u8 {
        return self.code & field.ckdiv;
    }

    pub fn store(self: *Divider, written: u8) void {
        self.code = written & field.ckdiv;
        self.writes +%= 1;
    }
};

/// Every divider as one model. It asks PRCR before a store and the paired
/// select afterwards, so it holds both rather than copies of either.
pub const Ckdiv = struct {
    protection: *const prcr.Prcr,
    /// The selects, so a store can ask whether its branch is gated.
    branches: *const ckcr.Ckcr,
    dividers: [slots.len]Divider = @splat(Divider{}),
    /// Stores dropped because PRCR.PRC0 was locked.
    dropped_locked: u32 = 0,

    pub fn init(protection: *const prcr.Prcr, branches: *const ckcr.Ckcr) Ckdiv {
        return .{ .protection = protection, .branches = branches };
    }

    /// A run that never touched a divider has nothing to narrate.
    pub fn quiet(self: *const Ckdiv) bool {
        if (self.dropped_locked != 0) return false;
        for (&self.dividers) |*one| {
            if (one.writes != 0 or one.ungated != 0) return false;
        }
        return true;
    }

    /// Is the branch this divider belongs to gated and therefore
    /// switchable right now? That is SRDY, which is what SREQ means.
    pub fn gated(self: *const Ckdiv, index: usize) bool {
        const which = ckcr.indexOf(slots[index].select) orelse return false;
        return self.branches.selects[which].ready();
    }

    pub fn read(self: *Ckdiv, address: u32, width: u3) u32 {
        _ = width;
        const index = indexOf(address) orelse return 0;
        return self.dividers[index].value();
    }

    pub fn write(self: *Ckdiv, address: u32, width: u3, value: u32) void {
        _ = width;
        const index = indexOf(address) orelse return;
        if (!self.protection.unlocked(guard)) {
            self.dropped_locked +%= 1;
            return;
        }
        if (!self.gated(index)) {
            self.dividers[index].ungated +%= 1;
            return;
        }
        self.dividers[index].store(@truncate(value));
    }

    /// One bus entry per run of adjacent dividers.
    pub fn block(self: *Ckdiv, which: usize) periph.Block {
        return .{
            .name = "CKDIVCR",
            .base = windows[which].base,
            .size = windows[which].span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Ckdiv = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Ckdiv = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
