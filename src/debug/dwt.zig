//! The DWT comparators as firmware programs them: DWT_COMPn and
//! DWT_FUNCTIONn, from 0xE000_1020 in steps of 16 bytes.
//!
//! This is the Armv8-M layout (DDI0553, DWT). A comparator holds an
//! address; its FUNCTION register says what to compare it against (MATCH),
//! what a match does (ACTION) and how many bytes the address covers
//! (DATAVSIZE). Every match sets FUNCTION.MATCHED, which a read clears.
//! A match whose ACTION is a debug event halts the core through the stop
//! machine, the same way a debugger watch does.
//!
//! The comparators only match while DEMCR.TRCENA is set, which the debug
//! core sees when the firmware stores DEMCR.
//!
//! DWT_CTRL and DWT_CYCCNT at the bottom of the block belong to
//! src/periph/clocks.zig and are not claimed here.
//!
//! FUNCTION.ID is read-only and says which MATCH kinds a comparator takes.
//! DDI0553B.y D1.2.64 lists the legal encodings. Comparator 0 must take
//! Cycle Counter when the cycle counter exists, which clocks.zig models, and
//! can never be the limit of a pair, so it reads 0b01011. The others read
//! 0b11010: they also take Instruction Address Limit and Data Address
//! Limit, which pair comparator n with comparator n-1 as an inclusive
//! range (E2.1.107 and E2.1.110). A range match is reported on comparator
//! n-1: its MATCHED is set and its ACTION applies.
//!
//! Not modelled yet: DWT_CTRL.NUMCOMP, the Cycle Counter match itself, and
//! the data value and linked data value match kinds.
const watch_table = @import("watch_table.zig");

pub const Access = watch_table.Access;

pub const base: u32 = 0xE000_1000;

pub const offsets = struct {
    pub const comp0: u32 = 0x020;
    pub const function0: u32 = 0x028;
    pub const stride: u32 = 0x010;
};

pub const limits = struct {
    /// Comparators modelled on each core.
    pub const comparators: usize = 8;
    /// One past the last comparator register, from `base`.
    pub const end: u32 = offsets.comp0 + comparators * offsets.stride;
};

/// DWT_FUNCTION.MATCH values this model compares.
pub const match = struct {
    pub const disabled: u32 = 0b0000;
    pub const instruction: u32 = 0b0010;
    pub const data: u32 = 0b0100;
    pub const data_write: u32 = 0b0101;
    pub const data_read: u32 = 0b0110;
    pub const instruction_limit: u32 = 0b0011;
    pub const data_limit: u32 = 0b0111;
};

pub const function_bits = struct {
    pub const match_mask: u32 = 0xF;
    pub const action_shift: u5 = 4;
    pub const action_mask: u32 = 0x3;
    /// ACTION: generate a debug event, which halts the core.
    pub const action_debug: u32 = 0b01;
    pub const size_shift: u5 = 10;
    pub const size_mask: u32 = 0x3;
    pub const matched: u32 = 1 << 24;
    /// MATCH, ACTION and DATAVSIZE; everything else is read-only.
    pub const writable: u32 = 0xC3F;
    pub const id_shift: u5 = 27;
};

/// DWT_FUNCTION.ID values (DDI0553B.y D1.2.64).
pub const id = struct {
    /// Cycle Counter, Instruction Address, Data Address, Data Address With Value.
    pub const cycles_instruction_data: u32 = 0b01011;
    /// Instruction Address and its Limit, Data Address and its Limit, Data
    /// Address With Value.
    pub const instruction_data_limits: u32 = 0b11010;

    /// The ID comparator `index` reads.
    pub fn of(index: usize) u32 {
        return if (index == 0) cycles_instruction_data else instruction_data_limits;
    }
};

pub const Dwt = struct {
    comps: [limits.comparators]u32 = [_]u32{0} ** limits.comparators,
    functions: [limits.comparators]u32 = [_]u32{0} ** limits.comparators,
    /// A register changed since memory last showed the register file.
    changed: bool = false,
    /// DEMCR.TRCENA: with it clear the DWT is off and nothing matches.
    trcena: bool = false,

    /// The register at `offset` from `base`, without a read's side
    /// effects, or null when the offset is not a comparator register.
    pub fn peek(self: *const Dwt, offset: u32) ?u32 {
        const slot = Slot.of(offset) orelse return null;
        if (!slot.function) return self.comps[slot.index];
        return self.functions[slot.index] | id.of(slot.index) << function_bits.id_shift;
    }

    /// Write the register at `offset`. False when it is not one of the
    /// comparator registers, so the caller can treat it as unclaimed.
    pub fn write(self: *Dwt, offset: u32, value: u32) bool {
        const slot = Slot.of(offset) orelse return false;
        if (slot.function) {
            const kept = self.functions[slot.index] & function_bits.matched;
            self.functions[slot.index] = kept | (value & function_bits.writable);
        } else {
            self.comps[slot.index] = value;
        }
        self.changed = true;
        return true;
    }

    /// The firmware read the register at `offset`: a FUNCTION read clears
    /// MATCHED once the read has seen it.
    pub fn loaded(self: *Dwt, offset: u32) void {
        const slot = Slot.of(offset) orelse return;
        if (!slot.function or self.functions[slot.index] & function_bits.matched == 0) return;
        self.functions[slot.index] &= ~function_bits.matched;
        self.changed = true;
    }

    /// The halting comparator an instruction fetch at `pc` matches.
    pub fn matchesPc(self: *Dwt, pc: u32) ?usize {
        return self.firstMatch(pc & ~@as(u32, 1), 2, null);
    }

    /// The halting comparator a data access matches. Every comparator it
    /// matches has MATCHED set, halting or not.
    pub fn access(self: *Dwt, address: u32, width: u8, kind: Access) ?usize {
        return self.firstMatch(address, width, kind);
    }

    fn firstMatch(self: *Dwt, address: u32, width: u32, kind: ?Access) ?usize {
        if (!self.trcena) return null;
        var halting: ?usize = null;
        for (0..limits.comparators) |index| {
            const owner = self.reporter(index, address, width, kind) orelse continue;
            self.functions[owner] |= function_bits.matched;
            self.changed = true;
            const action = (self.functions[owner] >> function_bits.action_shift) & function_bits.action_mask;
            if (halting == null and action == function_bits.action_debug) halting = owner;
        }
        return halting;
    }

    /// The comparator that reports a match made by comparator `index`: itself,
    /// or the lower half of a range when `index` is its limit. Null when
    /// `index` makes no match. A comparator that a limit pairs with matches
    /// only as part of that range.
    fn reporter(self: *const Dwt, index: usize, address: u32, width: u32, kind: ?Access) ?usize {
        const limit = if (kind == null) match.instruction_limit else match.data_limit;
        if (self.code(index) == limit) return self.rangeLower(index, address, width, kind);
        if (index + 1 < limits.comparators and self.code(index + 1) == limit) return null;
        if (!covers(self.functions[index], kind)) return null;
        if (!overlaps(self.comps[index], self.functions[index], address, width)) return null;
        return index;
    }

    /// Comparator `index - 1` when the access falls in the inclusive range
    /// from its address up to comparator `index`'s, which is a limit.
    fn rangeLower(self: *const Dwt, index: usize, address: u32, width: u32, kind: ?Access) ?usize {
        if (index == 0) return null;
        const lower = index - 1;
        const code_lower = self.code(lower);
        const paired = if (kind == null) code_lower == match.instruction else isDataAddress(code_lower);
        if (!paired or !covers(self.functions[lower], kind)) return null;
        const start = self.comps[lower] & ~(width - 1);
        if (address < start or address > self.comps[index]) return null;
        return lower;
    }

    fn code(self: *const Dwt, index: usize) u32 {
        return self.functions[index] & function_bits.match_mask;
    }
};

fn isDataAddress(code: u32) bool {
    return code == match.data or code == match.data_write or code == match.data_read;
}

const Slot = struct {
    index: usize,
    function: bool,

    fn of(offset: u32) ?Slot {
        if (offset < offsets.comp0 or offset >= limits.end) return null;
        const from = offset - offsets.comp0;
        const within = from % offsets.stride;
        if (within != 0 and within != offsets.function0 - offsets.comp0) return null;
        return .{ .index = from / offsets.stride, .function = within != 0 };
    }
};

/// Whether a comparator set up as `function` looks at this kind of
/// access; a null kind is an instruction fetch.
fn covers(function: u32, kind: ?Access) bool {
    const code = function & function_bits.match_mask;
    const seen = kind orelse return code == match.instruction;
    return switch (seen) {
        .read => code == match.data or code == match.data_read,
        .write => code == match.data or code == match.data_write,
    };
}

/// Whether `width` bytes at `address` touch the bytes the comparator
/// covers: DATAVSIZE gives the size, and the address is aligned to it.
fn overlaps(comp: u32, function: u32, address: u32, width: u32) bool {
    const size = @as(u32, 1) << @intCast((function >> function_bits.size_shift) & function_bits.size_mask);
    const start = comp & ~(size - 1);
    return address < start +% size and start < address +% width;
}
