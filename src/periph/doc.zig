//! DOC: the Data Operation Circuit, so a hardware sum equals its own reference.
//!
//! The RA8D2 DOC lives at 0x4031_1000 (HUM Ch 57.2, ra8_doc_regs.h) and is one
//! accumulator with a comparator bolted to it. Until now it fell through to the
//! sparse register file, and a sparse cell cannot accumulate: `doc_demo` in the
//! C tree chains an eight-entry add through the unit and compares the hardware
//! sum against a portable software sum, so DODSR0 reading back a stand-in
//! latched LED2 every run. The `RA8_OFF_TARGET` shortcut in ra8_doc.c that
//! computes the result in software is compiled out of the cross-target image
//! the emulator actually runs, so the genuine "write DODIR, read DODSR0" path
//! has to work. Ported from board_periph_doc.c on dev.
//!
//!   DOCR   (+0x00, 8b)  OMS[1:0] mode, DOBW width, DCSEL[2:0] compare relation
//!   DOSR   (+0x04, 8b)  DOPCF, the latched carry / borrow / comparison flag
//!   DOSCR  (+0x08, 8b)  write DOPCFCL to clear the flag
//!   DODIR  (+0x0C)      write-only operand in: each write runs one operation
//!   DODSR0 (+0x10)      reference in, running result out, seedable
//!   DODSR1 (+0x14)      upper threshold, shadowed
//!
//! One DODIR write is one operation, and DOCR.OMS picks which:
//!   add      DODSR0 += DODIR, masked to the DOBW width, DOPCF on carry out
//!   subtract DODSR0 -= DODIR, masked, DOPCF on borrow
//!   compare  DODSR0 is left alone, DOPCF latches when the relation holds
//!
//! DOPCF latches: once set it stays set until DOSCR clears it, which is what
//! lets a driver run a whole block through the unit and check overflow once at
//! the end rather than after every operand.
const std = @import("std");
const periph = @import("registry.zig");

/// DOC geometry (HUM Ch 57.2). The Non-secure alias is folded onto this base
/// by the bus before anything here sees it.
pub const win_base: u32 = 0x4031_1000;
pub const win_span: u32 = 0x20;

pub const off_docr: u32 = 0x00;
pub const off_dosr: u32 = 0x04;
pub const off_doscr: u32 = 0x08;
pub const off_dodir: u32 = 0x0C;
pub const off_dodsr0: u32 = 0x10;
pub const off_dodsr1: u32 = 0x14;

const oms_mask: u8 = 0x03;
pub const dobw_32: u8 = 0x08;
const dcsel_mask: u8 = 0x70;
pub const dcsel_shift: u3 = 4;
pub const dopcf: u8 = 0x01;

/// DOCR.OMS: what a DODIR write does.
pub const Mode = enum(u8) {
    compare = 0,
    add = 1,
    subtract = 2,
    _,
};

/// The unit: two operand registers, a mode byte and a sticky flag.
pub const Doc = struct {
    docr: u8 = 0,
    flag: bool = false,
    dodsr0: u32 = 0,
    dodsr1: u32 = 0,
    ops: u32 = 0,

    pub fn init() Doc {
        return .{};
    }

    pub fn mode(self: *const Doc) Mode {
        return @enumFromInt(self.docr & oms_mask);
    }

    /// DOCR.DOBW picks the arithmetic width: clear is 16-bit, set is 32-bit.
    pub fn widthMask(self: *const Doc) u32 {
        return if (self.docr & dobw_32 != 0) 0xFFFF_FFFF else 0x0000_FFFF;
    }

    /// Untouched units stay out of the end-of-run report.
    pub fn quiet(self: *const Doc) bool {
        return self.ops == 0;
    }

    /// Run one operation with `operand` as the DODIR value.
    pub fn apply(self: *Doc, operand: u32) void {
        const mask = self.widthMask();
        const in = operand & mask;
        const current = self.dodsr0 & mask;
        switch (self.mode()) {
            .add => {
                // Widened on purpose: a 32-bit add that carries out of bit 31
                // wraps in a u32, and the C tree's `sum & ~mask` test can
                // therefore never fire in 32-bit mode. Silicon latches DOPCF
                // whenever the sum leaves the selected width, so the sum is
                // computed a width up and the carry read off the top.
                const sum = @as(u64, current) + @as(u64, in);
                if (sum & ~@as(u64, mask) != 0) self.flag = true;
                self.dodsr0 = @truncate(sum & mask);
            },
            .subtract => {
                if (in > current) self.flag = true;
                self.dodsr0 = (current -% in) & mask;
            },
            else => {
                // Compare leaves the accumulator alone; only the flag moves.
                // DCSEL=1 latches on a match, every other encoding latches on
                // a mismatch, which is how dev models it: no in-tree app
                // selects the remaining relations, so inventing them here
                // would be inventing behaviour nothing checks.
                const dcsel = (self.docr & dcsel_mask) >> dcsel_shift;
                const equal = in == current;
                const hit = if (dcsel == 1) equal else !equal;
                if (hit) self.flag = true;
            },
        }
        self.ops +%= 1;
    }

    pub fn read(self: *Doc, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        if (offset == off_docr) return self.docr;
        if (offset == off_dosr) return if (self.flag) dopcf else 0;
        if (offset >= off_dodsr0 and offset < off_dodsr0 + 4) {
            const shift: u5 = @intCast((offset - off_dodsr0) * 8);
            return trim(self.dodsr0 >> shift, width);
        }
        if (offset >= off_dodsr1 and offset < off_dodsr1 + 4) {
            const shift: u5 = @intCast((offset - off_dodsr1) * 8);
            return trim(self.dodsr1 >> shift, width);
        }
        // DODIR is write-only and DOSCR is a clear strobe: both read zero on
        // silicon, and zero beats the sparse file's alternating stand-in. A
        // driver polling here is reading a register with no value to give.
        return 0;
    }

    pub fn write(self: *Doc, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        if (offset == off_docr) {
            self.docr = @truncate(value);
            return;
        }
        if (offset == off_doscr) {
            if (@as(u8, @truncate(value)) & dopcf != 0) self.flag = false;
            return;
        }
        if (offset == off_dodir) {
            self.apply(value);
            return;
        }
        if (offset >= off_dodsr0 and offset < off_dodsr0 + 4) {
            self.dodsr0 = merge(self.dodsr0, offset - off_dodsr0, width, value);
            return;
        }
        if (offset >= off_dodsr1 and offset < off_dodsr1 + 4) {
            self.dodsr1 = merge(self.dodsr1, offset - off_dodsr1, width, value);
            return;
        }
        // DOSR.DOPCF is read-only: it is cleared through DOSCR, never by
        // writing the status register.
    }

    pub fn block(self: *Doc) periph.Block {
        return .{
            .name = "DOC",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn trim(value: u32, width: u3) u32 {
    return switch (width) {
        1 => value & 0xFF,
        2 => value & 0xFFFF,
        else => value,
    };
}

/// Fold a narrow write into a 32-bit register without disturbing the bytes the
/// access does not name.
fn merge(current: u32, byte_offset: u32, width: u3, value: u32) u32 {
    if (width >= 4 and byte_offset == 0) return value;
    const shift: u5 = @intCast(byte_offset * 8);
    const window = trim(0xFFFF_FFFF, width) << shift;
    return (current & ~window) | ((value << shift) & window);
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Doc = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Doc = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The address of one DOC register, so a test or a later slice does not have
/// to do the arithmetic itself.
pub fn regAddress(offset: u32) u32 {
    return win_base + offset;
}

pub const reg_docr = off_docr;
pub const reg_dosr = off_dosr;
pub const reg_doscr = off_doscr;
pub const reg_dodir = off_dodir;
pub const reg_dodsr0 = off_dodsr0;
pub const reg_dodsr1 = off_dodsr1;
