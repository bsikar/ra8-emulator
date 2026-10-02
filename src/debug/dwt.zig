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
//! Data Value (0b1000, 0b1001 writes, 0b1010 reads) compares the value
//! a store writes with DWT_COMPn, masked by DWT_VMASKn, in the byte lanes
//! DATAVSIZE picks (E2.1.109). Linked Data Value (0b1011) also needs
//! comparator n-1 to match the access's address. Only the odd comparators
//! take the value kinds (ID 0b11110); comparator 0 never links. Loads
//! and stores both carry their value to the DWT.
//!
//! DWT_CTRL.NUMCOMP [31:28] says how many comparators the core has, and is
//! read-only. The Cortex-M85 TRM (101924, DWT register summary) gives 8 in
//! the full set and 4 in the reduced set; the Cortex-M33 TRM (100230) gives
//! 4 and 2. Both cores are modelled with the full set and ITM trace, so
//! DWT_CTRL resets to 0x8000_0000 on CPU0 and 0x4000_0000 on CPU1. The
//! comparators past NUMCOMP read as zero and ignore writes.
//!
//! Not modelled yet: the Cycle Counter match itself.
const watch_table = @import("watch_table.zig");
const cpuid = @import("../periph/cpuid.zig");

pub const Access = watch_table.Access;

pub const base: u32 = 0xE000_1000;

pub const offsets = struct {
    pub const comp0: u32 = 0x020;
    pub const function0: u32 = 0x028;
    pub const vmask0: u32 = 0x02C;
    pub const stride: u32 = 0x010;
};

pub const limits = struct {
    /// Comparators modelled on each core.
    pub const comparators: usize = 8;
    /// One past the last comparator register, from `base`.
    pub const end: u32 = offsets.comp0 + comparators * offsets.stride;
};

/// DWT_CTRL fields the debug model owns. The rest belongs to clocks.zig.
pub const ctrl_bits = struct {
    pub const numcomp_shift: u5 = 28;
    pub const numcomp_mask: u32 = 0xF << numcomp_shift;
};

/// The comparators the core a CPUID word names has: 4 on a Cortex-M33,
/// 8 on the Cortex-M85 and anything unrecognised.
pub fn numcompOf(identity: u32) u4 {
    return if (cpuid.part(identity) == cpuid.partno.cortex_m33) 4 else limits.comparators;
}

/// DWT_CTRL at reset for that core: NUMCOMP, with every other bit clear.
pub fn ctrlReset(identity: u32) u32 {
    return @as(u32, numcompOf(identity)) << ctrl_bits.numcomp_shift;
}

/// DWT_FUNCTION.MATCH values this model compares.
pub const match = struct {
    pub const disabled: u32 = 0b0000;
    pub const instruction: u32 = 0b0010;
    pub const data: u32 = 0b0100;
    pub const data_write: u32 = 0b0101;
    pub const data_read: u32 = 0b0110;
    pub const instruction_limit: u32 = 0b0011;
    pub const data_limit: u32 = 0b0111;
    pub const data_value: u32 = 0b1000;
    pub const data_value_write: u32 = 0b1001;
    pub const data_value_read: u32 = 0b1010;
    pub const linked_data_value: u32 = 0b1011;
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
    /// All of the above plus Data Value and Linked Data Value.
    pub const instruction_data_values: u32 = 0b11110;
    /// ID<2>: the comparator takes Data Value and Linked Data Value.
    pub const value_bit: u32 = 1 << 2;

    /// The ID comparator `index` reads. Comparator 0 never links and Arm
    /// recommends the odd comparators link, so only those take values.
    pub fn of(index: usize) u32 {
        if (index == 0) return cycles_instruction_data;
        return if (index % 2 == 1) instruction_data_values else instruction_data_limits;
    }

    /// Whether comparator `index` takes the Data Value kinds.
    pub fn takesValues(index: usize) bool {
        return of(index) & value_bit != 0;
    }
};

pub const Dwt = struct {
    comps: [limits.comparators]u32 = [_]u32{0} ** limits.comparators,
    functions: [limits.comparators]u32 = [_]u32{0} ** limits.comparators,
    vmasks: [limits.comparators]u32 = [_]u32{0} ** limits.comparators,
    /// DWT_CTRL.NUMCOMP: the comparators this core has. Those past it are
    /// absent, so they read as zero, ignore writes and never match.
    numcomp: u4 = limits.comparators,
    /// A register changed since memory last showed the register file.
    changed: bool = false,
    /// DEMCR.TRCENA: with it clear the DWT is off and nothing matches.
    trcena: bool = false,

    /// The register at `offset` from `base`, without a read's side
    /// effects, or null when the offset is not a comparator register.
    pub fn peek(self: *const Dwt, offset: u32) ?u32 {
        const slot = Slot.of(offset) orelse return null;
        if (slot.index >= self.numcomp) return 0;
        return switch (slot.register) {
            .comp => self.comps[slot.index],
            .function => self.functions[slot.index] | id.of(slot.index) << function_bits.id_shift,
            .vmask => if (id.takesValues(slot.index) and isDataValue(self.code(slot.index))) self.vmasks[slot.index] else 0,
        };
    }

    /// Write the register at `offset`. False when it is not one of the
    /// comparator registers, so the caller can treat it as unclaimed.
    pub fn write(self: *Dwt, offset: u32, value: u32) bool {
        const slot = Slot.of(offset) orelse return false;
        if (slot.index >= self.numcomp) return true;
        switch (slot.register) {
            .comp => self.comps[slot.index] = value,
            .function => {
                const kept = self.functions[slot.index] & function_bits.matched;
                self.functions[slot.index] = kept | (value & function_bits.writable);
            },
            .vmask => self.vmasks[slot.index] = value,
        }
        self.changed = true;
        return true;
    }

    /// A DWT_CTRL word as a read sees it: NUMCOMP is read-only, so a store
    /// keeps every other bit and NUMCOMP stays this core's count.
    pub fn ctrlWord(self: *const Dwt, value: u32) u32 {
        return (value & ~ctrl_bits.numcomp_mask) | @as(u32, self.numcomp) << ctrl_bits.numcomp_shift;
    }

    /// The firmware read the register at `offset`: a FUNCTION read clears
    /// MATCHED once the read has seen it.
    pub fn loaded(self: *Dwt, offset: u32) void {
        const slot = Slot.of(offset) orelse return;
        if (slot.register != .function or self.functions[slot.index] & function_bits.matched == 0) return;
        self.functions[slot.index] &= ~function_bits.matched;
        self.changed = true;
    }

    /// The halting comparator an instruction fetch at `pc` matches.
    pub fn matchesPc(self: *Dwt, pc: u32) ?usize {
        return self.firstMatch(pc & ~@as(u32, 1), 2, null, null);
    }

    /// The halting comparator a data access matches. Every comparator it
    /// matches has MATCHED set, halting or not. `value` is what the access
    /// moved, when known; without it no Data Value comparator matches.
    pub fn access(self: *Dwt, address: u32, width: u8, kind: Access, value: ?u32) ?usize {
        return self.firstMatch(address, width, kind, value);
    }

    fn firstMatch(self: *Dwt, address: u32, width: u32, kind: ?Access, value: ?u32) ?usize {
        if (!self.trcena) return null;
        var halting: ?usize = null;
        for (0..self.numcomp) |index| {
            const owner = self.reporter(index, address, width, kind, value) orelse continue;
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
    fn reporter(self: *const Dwt, index: usize, address: u32, width: u32, kind: ?Access, value: ?u32) ?usize {
        if (isDataValue(self.code(index))) {
            const seen = kind orelse return null;
            return if (self.valueMatches(index, address, width, seen, value orelse return null)) index else null;
        }
        const limit = if (kind == null) match.instruction_limit else match.data_limit;
        if (self.code(index) == limit) return self.rangeLower(index, address, width, kind);
        if (index + 1 < self.numcomp and self.code(index + 1) == limit) return null;
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

    /// DWT_DataValueMatch (E2.1.109): the bytes of `value` that DATAVSIZE
    /// and the access select, after VMASK, against the same lanes of
    /// DWT_COMPn. A Linked Data Value comparator also needs comparator n-1,
    /// a Data Address comparator of the same DATAVSIZE, to match the access,
    /// and takes its read or write filter and byte lanes from it.
    fn valueMatches(self: *const Dwt, index: usize, address: u32, width: u32, kind: Access, value: u32) bool {
        if (!id.takesValues(index) or width > 4) return false;
        const code_now = self.code(index);
        if (code_now == match.data_value_write and kind != .write) return false;
        if (code_now == match.data_value_read and kind != .read) return false;
        const vsize = sizeOf(self.functions[index]);
        if (vsize > width) return false;
        var lanes: u32 = (@as(u32, 1) << @intCast(width)) - 1;
        if (code_now == match.linked_data_value) {
            if (index == 0) return false;
            const lower = index - 1;
            if (!isDataAddress(self.code(lower)) or !covers(self.functions[lower], kind)) return false;
            if (sizeOf(self.functions[lower]) != vsize) return false;
            if (!overlaps(self.comps[lower], self.functions[lower], address, width)) return false;
            lanes = linkedLanes(vsize, width, self.comps[lower]) orelse return false;
        }
        const masked = value & ~self.vmasks[index];
        var equal: [4]bool = undefined;
        for (&equal, 0..) |*lane, n| {
            const shift: u5 = @intCast(n * 8);
            const used = lanes >> @intCast(n) & 1 != 0;
            lane.* = used and (masked >> shift) & 0xFF == (self.comps[index] >> shift) & 0xFF;
        }
        return switch (vsize) {
            1 => equal[0] or equal[1] or equal[2] or equal[3],
            2 => (equal[3] and equal[2]) or (equal[1] and equal[0]),
            else => equal[0] and equal[1] and equal[2] and equal[3],
        };
    }

    fn code(self: *const Dwt, index: usize) u32 {
        return self.functions[index] & function_bits.match_mask;
    }
};

/// DATAVSIZE in bytes.
fn sizeOf(function: u32) u32 {
    return @as(u32, 1) << @intCast((function >> function_bits.size_shift) & function_bits.size_mask);
}

/// The byte lanes a Linked Data Value comparator looks at, picked by the
/// low bits of the linked address (the byte_mask cases of E2.1.109). Null
/// when DATAVSIZE is wider than the access.
fn linkedLanes(vsize: u32, width: u32, linked_address: u32) ?u32 {
    const low: u5 = @intCast(linked_address & 0b11);
    return switch (vsize * 8 + width) {
        1 * 8 + 1 => 0b0001,
        1 * 8 + 2 => @as(u32, 1) << (low & 1),
        1 * 8 + 4 => @as(u32, 1) << low,
        2 * 8 + 2 => 0b0011,
        2 * 8 + 4 => @as(u32, 0b11) << (low & 0b10),
        4 * 8 + 4 => 0b1111,
        else => null,
    };
}

/// MATCH 0b10xx: Data Value, its read and write forms, and Linked Data
/// Value.
fn isDataValue(code: u32) bool {
    return code >> 2 == 0b10;
}

fn isDataAddress(code: u32) bool {
    return code == match.data or code == match.data_write or code == match.data_read;
}

const Register = enum { comp, function, vmask };

const Slot = struct {
    index: usize,
    register: Register,

    fn of(offset: u32) ?Slot {
        if (offset < offsets.comp0 or offset >= limits.end) return null;
        const from = offset - offsets.comp0;
        const register: Register = switch (from % offsets.stride) {
            0 => .comp,
            offsets.function0 - offsets.comp0 => .function,
            offsets.vmask0 - offsets.comp0 => .vmask,
            else => return null,
        };
        return .{ .index = from / offsets.stride, .register = register };
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
