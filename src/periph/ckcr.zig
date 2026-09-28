//! The peripheral clock source selects and the SREQ -> SRDY handshake.
//!
//! Four 8-bit registers sit together near the top of the SYSC window and pick
//! the source clock for a peripheral that runs off its own branch rather than
//! off PCLK:
//!
//!   USBCKCR    (+0x074)  USB-FS module clock
//!   OCTACKCR   (+0x075)  Octal-SPI clock        (HUM Ch 9.2.45 p 360)
//!   CANFDCKCR  (+0x076)  CAN-FD core clock      (HUM Ch 9.2.46 p 366)
//!   USB60CKCR  (+0x077)  USBHS 60 MHz clock
//!
//! They share one layout, and the firmware says so by sharing one set of bit
//! constants for all of them: ra8_xspi.c and ra8_canfd.c both reach for
//! `k_ra8_usbckcr_bit_sreq` and `k_ra8_usbckcr_bit_srdy` rather than defining
//! their own. SEL is bits 3:0, SREQ is bit 6, and SRDY is bit 7 and is read
//! only.
//!
//! A SOURCE IS NOT SWITCHED BY WRITING SEL. HUM Ch 9 "Clock Selection
//! Switching Procedure" makes it a handshake, and ra8_cgc.h writes the steps
//! out: assert SREQ, WAIT FOR SRDY TO READ 1 (the branch is now gated and
//! therefore switchable), write the divider, write SEL with SREQ still set,
//! drop SREQ, then WAIT FOR SRDY TO READ 0 (the new source is running). Both
//! waits are bounded spins: ra8_cgc_usb.c gives each 200,000 iterations and
//! returns k_ra8_err_hw_timeout when they run out.
//!
//! Nothing modelled these four registers, so they fell through to the sparse
//! register file, which answers the last word written. SRDY is bit 7 and no
//! driver ever writes it, so it read 0 forever: the first wait, for SRDY = 1,
//! spun out its whole budget and every one of these paths returned a hardware
//! timeout before it reached the second wait. ra8_cgc_usbfs_clock_enable,
//! ra8_cgc_usbhs_clock_enable, the XSPI clock bring-up in ra8_xspi.c and the
//! CAN-FD one in ra8_canfd.c all failed the same way and for the same reason.
//! That is the third bounded wait loop in this tree that could never be
//! satisfied, after MSUINITR and the USB PHY PLL lock.
//!
//! SRDY simply follows SREQ here: the branch gates and ungates in no time, so
//! a driver polling for 1 and then for 0 makes progress on both, and a driver
//! that reads SRDY without having asked for anything still reads 0.
//!
//! NOT MODELLED, AND NOT GUESSED: the module-stop precondition. HUM Ch 9
//! requires the dependent peripheral to be in module-stop before SREQ is
//! asserted when the divider is changing, and ra8_cgc_usb.c says in so many
//! words that "if the caller has already released MSTPB12 (USBHS) the
//! SREQ->SRDY handshake silently hangs". Honouring that needs the module-stop
//! bit for each of these four branches, and src/periph/mstp.zig carries no
//! family for either USB controller, so a hang modelled here would be a guess
//! for half the window. No clock RATE is derived from SEL either: the value is
//! retained and reported, nothing downstream reads it, and the dividers at
//! +0x06C and +0x06F are not in this window.
const periph = @import("registry.zig");
const prcr = @import("prcr.zig");

/// Window geometry: SYSC base 0x4001_E000 + 0x074, four 8-bit registers.
pub const win_base: u32 = 0x4001_E074;
pub const win_span: u32 = 0x4;

/// The one layout all four share (ra8_system_regs.h, ra8_usbckcr_bit_t).
pub const field = struct {
    /// SEL, bits 3:0: the source clock codepoint.
    pub const sel: u8 = 0x0F;
    /// SREQ, bit 6: ask for a switch.
    pub const sreq: u8 = 0x40;
    /// SRDY, bit 7: read-only, the branch is gated and switchable.
    pub const srdy: u8 = 0x80;
};

/// The group these sit behind: PRC0, the clock generation circuit.
pub const guard: u16 = prcr.group.cgc;

/// Which register a byte offset names, and what to call it in the report.
pub const names = [_][]const u8{ "USBCKCR", "OCTACKCR", "CANFDCKCR", "USB60CKCR" };

/// One clock source select: the retained bits, and what the handshake did.
pub const Select = struct {
    sel: u8 = 0,
    requested: bool = false,
    /// Times SREQ went up, which is one half-handshake each.
    requests: u32 = 0,
    /// Times SREQ came back down, which is the moment the new source runs.
    switches: u32 = 0,

    /// SRDY is not stored: it is what SREQ means right now.
    pub fn ready(self: *const Select) bool {
        return self.requested;
    }

    pub fn value(self: *const Select) u8 {
        var out = self.sel;
        if (self.requested) out |= field.sreq | field.srdy;
        return out;
    }

    /// SEL lands either way, which is what lets the driver write source and
    /// SREQ together in one store and then drop SREQ in the next.
    pub fn store(self: *Select, written: u8) void {
        const wants = written & field.sreq != 0;
        if (wants and !self.requested) self.requests +%= 1;
        if (!wants and self.requested) self.switches +%= 1;
        self.sel = written & field.sel;
        self.requested = wants;
    }
};

/// The four registers as one block, with PRC0 asked before any store.
pub const Ckcr = struct {
    /// The board's live protection model, not a copy of it.
    protection: *const prcr.Prcr,
    selects: [win_span]Select = .{Select{}} ** win_span,
    /// Stores dropped because PRCR.PRC0 was locked.
    dropped_locked: u32 = 0,

    pub fn init(protection: *const prcr.Prcr) Ckcr {
        return .{ .protection = protection };
    }

    /// A run that never switched a branch has nothing to narrate.
    pub fn quiet(self: *const Ckcr) bool {
        if (self.dropped_locked != 0) return false;
        for (&self.selects) |*one| {
            if (one.requests != 0 or one.switches != 0) return false;
        }
        return true;
    }

    pub fn read(self: *Ckcr, address: u32, width: u3) u32 {
        _ = width;
        return self.selects[address -% win_base].value();
    }

    pub fn write(self: *Ckcr, address: u32, width: u3, value: u32) void {
        _ = width;
        if (!self.protection.unlocked(guard)) {
            self.dropped_locked +%= 1;
            return;
        }
        self.selects[address -% win_base].store(@truncate(value));
    }

    pub fn block(self: *Ckcr) periph.Block {
        return .{
            .name = "CKCR",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Ckcr = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Ckcr = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
