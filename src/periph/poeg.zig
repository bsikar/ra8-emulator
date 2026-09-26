//! POEG: Port Output Enable for GPT, the block that forces the timer outputs
//! into high impedance when something says stop.
//!
//! Four groups live at 0x4021_2000 with a 0x100 stride (HUM Ch 21.2.1 p 872,
//! ra8_poeg_regs.h). Each one carries a single 32-bit POEGG at offset 0 that
//! holds the request flags, and the read-only ST bit that says the outputs of
//! that group are currently disabled. A safe-shutoff image asserts a request,
//! reads back that the outputs went high-impedance, clears the request, and
//! reads back that they are driven again: ST is the whole observable, since
//! there is no pin to scope here.
//!
//! Ported from board_periph_poeg.c on dev, with two things that model does
//! not do.
//!
//! PIDF, IOCF and OSTPF ARE LATCHES A TRIGGER SOURCE SETS, NOT BITS FIRMWARE
//! WRITES. dev takes the incoming value wholesale for all four request flags,
//! so an image can store PIDF and watch the outputs shut off as though a pin
//! fault had happened, which is a shutoff it never actually proved. Here only
//! SSF, the software stop, is settable by a store; a 1 written to the other
//! three is discarded (counted as `faked`), and a 0 clears them, which is the
//! write-0-to-clear the block's own comment describes but its code does not
//! do. A real source reaches them through trigger().
//!
//! A NARROW WRITE ONLY TOUCHES THE BYTES IT NAMES. dev ignores the access
//! size and drops the whole 32-bit value in, so a byte store to the low byte
//! of POEGG, which is how a driver asserts SSF without disturbing the trigger
//! enables above it, wipes the rest of the register.
//!
//! NOT MODELLED, AND NOT GUESSED: the trigger enables and the noise filter
//! live in the upper half of POEGG, and no header for this part is in this
//! tree to say which bits they are. They are shadowed, so a read-modify-write
//! survives, and never interpreted. The group's POEG interrupt is not raised
//! either: that needs an ICU event number nothing here establishes. ST is
//! register state only, the same line dev draws, so the GPT counter model,
//! when it lands, is what has to read it.
const std = @import("std");
const periph = @import("registry.zig");

/// POEG geometry. The Non-secure alias is folded onto this base by the bus.
pub const win_base: u32 = 0x4021_2000;
pub const group_stride: u32 = 0x100;
pub const group_count: usize = 4;
pub const win_span: u32 = group_stride * @as(u32, group_count);

/// POEGG, the one register this model interprets.
pub const off_poegg: u32 = 0x00;

/// POEGG fields (HUM Ch 21.2.1 p 872).
pub const field = struct {
    pub const pidf: u32 = 0x0000_0001;
    pub const iocf: u32 = 0x0000_0002;
    pub const ostpf: u32 = 0x0000_0004;
    pub const ssf: u32 = 0x0000_0008;
    pub const st: u32 = 0x0001_0000;
    /// ST is the OR of these.
    pub const requests: u32 = pidf | iocf | ostpf | ssf;
    /// The three only a trigger source raises.
    pub const external: u32 = pidf | iocf | ostpf;
};

/// What asked for the shutoff.
pub const Source = enum {
    pin,
    output_short,
    oscillation_stop,

    pub fn mask(self: Source) u32 {
        return switch (self) {
            .pin => field.pidf,
            .output_short => field.iocf,
            .oscillation_stop => field.ostpf,
        };
    }
};

/// Words of POEGG's group window this model shadows rather than interprets.
const shadow_words: usize = group_stride / 4;

/// One group: the live request flags, the uninterpreted rest of its window,
/// and what the run should be told about it.
pub const Group = struct {
    requests: u32 = 0,
    /// The bits of POEGG this model does not interpret: the trigger enables
    /// and the noise filter, whichever bits they are on this part. Kept so a
    /// read-modify-write of the register survives, never read by anything.
    others: u32 = 0,
    shadow: [shadow_words]u32 = .{0} ** shadow_words,
    asserts: u32 = 0,
    clears: u32 = 0,
    faked: u32 = 0,
    shadow_writes: u32 = 0,

    pub fn disabled(self: *const Group) bool {
        return self.requests & field.requests != 0;
    }

    /// POEGG as firmware reads it: the live flags, the bits this model only
    /// stores, and ST derived from the flags.
    pub fn poegg(self: *const Group) u32 {
        return self.requests | self.others | (if (self.disabled()) field.st else 0);
    }

    pub fn quiet(self: *const Group) bool {
        return self.asserts == 0 and self.clears == 0 and self.faked == 0;
    }

    /// Move to a new set of request flags, counting the ST edges a safe
    /// shutoff is judged by.
    fn settle(self: *Group, next: u32) void {
        const was = self.disabled();
        self.requests = next & field.requests;
        const now = self.disabled();
        if (!was and now) self.asserts +%= 1;
        if (was and !now) self.clears +%= 1;
    }
};

pub const Poeg = struct {
    groups: [group_count]Group = .{Group{}} ** group_count,

    pub fn init() Poeg {
        return .{};
    }

    pub fn quiet(self: *const Poeg) bool {
        for (&self.groups) |*group| {
            if (!group.quiet()) return false;
        }
        return true;
    }

    /// A trigger source raises its request on a group. Nothing inside this
    /// file can do it: PIDF, IOCF and OSTPF belong to a pin, the output-short
    /// detector and the oscillation-stop detector, and this is the seam they
    /// come in through once one of them is modelled.
    pub fn trigger(self: *Poeg, group: usize, source: Source) void {
        if (group >= group_count) return;
        const unit = &self.groups[group];
        unit.settle(unit.requests | source.mask());
    }

    pub fn read(self: *Poeg, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        const group = offset / group_stride;
        if (group >= group_count) return 0;
        const unit = &self.groups[group];
        const inner = offset % group_stride;
        if (inner < 4) return part(unit.poegg(), inner, width);
        return part(unit.shadow[inner / 4], inner % 4, width);
    }

    pub fn write(self: *Poeg, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        const group = offset / group_stride;
        if (group >= group_count) return;
        const unit = &self.groups[group];
        const inner = offset % group_stride;
        if (inner < 4) {
            self.writePoegg(group, merge(unit.poegg(), inner, width, value));
            return;
        }
        const word = inner / 4;
        unit.shadow[word] = merge(unit.shadow[word], inner % 4, width, value);
        unit.shadow_writes +%= 1;
    }

    /// The store rules, in one place. ST is read-only and is re-derived, the
    /// three external flags can only be cleared, and SSF does what it is
    /// written.
    fn writePoegg(self: *Poeg, group: usize, candidate: u32) void {
        const unit = &self.groups[group];
        const wanted = candidate & field.external;
        const held = unit.requests & field.external;
        unit.faked +%= @popCount(wanted & ~held);
        unit.others = candidate & ~(field.requests | field.st);
        unit.settle((held & wanted) | (candidate & field.ssf));
    }

    pub fn block(self: *Poeg) periph.Block {
        return .{
            .name = "POEG",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// The part of a 32-bit register a narrow access names.
fn part(value: u32, byte_offset: u32, width: u3) u32 {
    if (width >= 4) return value;
    const shift: u5 = @intCast(byte_offset * 8);
    const shifted = value >> shift;
    return if (width == 1) shifted & 0xFF else shifted & 0xFFFF;
}

/// Fold a narrow write into a 32-bit register, leaving the bytes the access
/// does not name where they were.
fn merge(current: u32, byte_offset: u32, width: u3, value: u32) u32 {
    if (width >= 4) return value;
    const shift: u5 = @intCast(byte_offset * 8);
    const bits: u32 = if (width == 1) 0xFF else 0xFFFF;
    const window: u32 = bits << shift;
    return (current & ~window) | ((value & bits) << shift);
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Poeg = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Poeg = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The address of one group's POEGG, so a test or a later slice does not do
/// the arithmetic itself.
pub fn groupAddress(group: usize) u32 {
    return win_base + @as(u32, @intCast(group)) * group_stride;
}
