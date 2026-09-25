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
const periph = @import("periph.zig");

/// DOC geometry (HUM Ch 57.2). The Non-secure alias is folded onto this base
/// by the bus before anything here sees it.
pub const win_base: u32 = 0x4031_1000;
pub const win_span: u32 = 0x20;

const off_docr: u32 = 0x00;
const off_dosr: u32 = 0x04;
const off_doscr: u32 = 0x08;
const off_dodir: u32 = 0x0C;
const off_dodsr0: u32 = 0x10;
const off_dodsr1: u32 = 0x14;

const oms_mask: u8 = 0x03;
const dobw_32: u8 = 0x08;
const dcsel_mask: u8 = 0x70;
const dcsel_shift: u3 = 4;
const dopcf: u8 = 0x01;

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

const docr_add_32: u32 = @intFromEnum(Mode.add) | dobw_32;
const docr_sub_32: u32 = @intFromEnum(Mode.subtract) | dobw_32;

test "an eight-entry add chain leaves the hardware sum in DODSR0" {
    var unit = Doc.init();
    unit.write(regAddress(off_docr), 1, docr_add_32);
    unit.write(regAddress(off_dodsr0), 4, 0);

    var expected: u32 = 0;
    const entries = [_]u32{ 1, 2, 3, 5, 8, 13, 21, 34 };
    for (entries) |entry| {
        unit.write(regAddress(off_dodir), 4, entry);
        expected += entry;
    }
    try std.testing.expectEqual(expected, unit.read(regAddress(off_dodsr0), 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(regAddress(off_dosr), 1));
    try std.testing.expectEqual(@as(u32, 8), unit.ops);
}

test "a seeded reference is the first operand, not a cleared accumulator" {
    var unit = Doc.init();
    unit.write(regAddress(off_docr), 1, docr_add_32);
    unit.write(regAddress(off_dodsr0), 4, 1000);
    unit.write(regAddress(off_dodir), 4, 24);
    try std.testing.expectEqual(@as(u32, 1024), unit.read(regAddress(off_dodsr0), 4));
}

test "a 16-bit add wraps at the width and latches DOPCF" {
    var unit = Doc.init();
    unit.write(regAddress(off_docr), 1, @intFromEnum(Mode.add)); // DOBW clear
    unit.write(regAddress(off_dodsr0), 4, 0xFFF0);
    unit.write(regAddress(off_dodir), 4, 0x0020);
    try std.testing.expectEqual(@as(u32, 0x0010), unit.read(regAddress(off_dodsr0), 4));
    try std.testing.expectEqual(@as(u32, dopcf), unit.read(regAddress(off_dosr), 1));
}

test "a 32-bit add carries out of bit 31, which the C tree could not see" {
    var unit = Doc.init();
    unit.write(regAddress(off_docr), 1, docr_add_32);
    unit.write(regAddress(off_dodsr0), 4, 0xFFFF_FFF0);
    unit.write(regAddress(off_dodir), 4, 0x20);
    try std.testing.expectEqual(@as(u32, 0x10), unit.read(regAddress(off_dodsr0), 4));
    try std.testing.expect(unit.flag);
}

test "DOPCF is sticky until DOSCR clears it" {
    var unit = Doc.init();
    unit.write(regAddress(off_docr), 1, @intFromEnum(Mode.add));
    unit.write(regAddress(off_dodsr0), 4, 0xFFFF);
    unit.write(regAddress(off_dodir), 4, 1); // carries
    try std.testing.expect(unit.flag);

    unit.write(regAddress(off_dodir), 4, 1); // does not carry
    try std.testing.expect(unit.flag); // still latched

    unit.write(regAddress(off_dosr), 1, 0); // read-only, no effect
    try std.testing.expect(unit.flag);

    unit.write(regAddress(off_doscr), 1, dopcf);
    try std.testing.expect(!unit.flag);
    try std.testing.expectEqual(@as(u32, 0), unit.read(regAddress(off_dosr), 1));
}

test "subtract borrows below zero and masks to the width" {
    var unit = Doc.init();
    unit.write(regAddress(off_docr), 1, docr_sub_32);
    unit.write(regAddress(off_dodsr0), 4, 100);
    unit.write(regAddress(off_dodir), 4, 40);
    try std.testing.expectEqual(@as(u32, 60), unit.read(regAddress(off_dodsr0), 4));
    try std.testing.expect(!unit.flag);

    unit.write(regAddress(off_dodir), 4, 100); // 60 - 100 borrows
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFD8), unit.read(regAddress(off_dodsr0), 4));
    try std.testing.expect(unit.flag);
}

test "compare leaves the accumulator alone and only moves the flag" {
    var match = Doc.init();
    match.write(regAddress(off_docr), 1, @intFromEnum(Mode.compare) | (1 << dcsel_shift) | dobw_32);
    match.write(regAddress(off_dodsr0), 4, 0xABCD_1234);
    match.write(regAddress(off_dodir), 4, 0xABCD_1234);
    try std.testing.expect(match.flag);
    try std.testing.expectEqual(@as(u32, 0xABCD_1234), match.read(regAddress(off_dodsr0), 4));

    var differ = Doc.init();
    differ.write(regAddress(off_docr), 1, @intFromEnum(Mode.compare) | dobw_32);
    differ.write(regAddress(off_dodsr0), 4, 7);
    differ.write(regAddress(off_dodir), 4, 7);
    try std.testing.expect(!differ.flag); // mismatch relation, operands match
    differ.write(regAddress(off_dodir), 4, 8);
    try std.testing.expect(differ.flag);
}

test "the reference and threshold take narrow writes and read back through aliases" {
    var unit = Doc.init();
    unit.write(regAddress(off_dodsr0), 4, 0xAABB_CCDD);
    try std.testing.expectEqual(@as(u32, 0xDD), unit.read(regAddress(off_dodsr0), 1));
    try std.testing.expectEqual(@as(u32, 0xAABB), unit.read(regAddress(off_dodsr0 + 2), 2));
    unit.write(regAddress(off_dodsr0 + 2), 2, 0x1234);
    try std.testing.expectEqual(@as(u32, 0x1234_CCDD), unit.read(regAddress(off_dodsr0), 4));

    unit.write(regAddress(off_dodsr1), 4, 0x0000_FFFF);
    try std.testing.expectEqual(@as(u32, 0xFFFF), unit.read(regAddress(off_dodsr1), 4));
    try std.testing.expect(unit.quiet());
}

test "DODIR and DOSCR read zero rather than a stand-in value" {
    var unit = Doc.init();
    unit.write(regAddress(off_docr), 1, docr_add_32);
    unit.write(regAddress(off_dodir), 4, 0x1234);
    try std.testing.expectEqual(@as(u32, 0), unit.read(regAddress(off_dodir), 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(regAddress(off_doscr), 1));
    try std.testing.expectEqual(@as(u32, docr_add_32), unit.read(regAddress(off_docr), 1));
    try std.testing.expectEqual(Mode.add, unit.mode());
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), unit.widthMask());
}

test "the unit answers on the bus, in both windows" {
    var bus = periph.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var unit = Doc.init();
    try bus.add(unit.block());

    bus.write(regAddress(off_docr), 1, docr_add_32);
    bus.write(regAddress(off_dodsr0), 4, 0);
    bus.write(periph.ns_base + (regAddress(off_dodir) - periph.base), 4, 0x2000);
    bus.write(regAddress(off_dodir), 4, 0x0024);
    try std.testing.expectEqual(@as(u32, 0x2024), bus.read(regAddress(off_dodsr0), 4));
    try std.testing.expectEqual(@as(usize, 0), bus.unmodelledAddresses());
}
