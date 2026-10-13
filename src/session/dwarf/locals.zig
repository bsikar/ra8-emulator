//! Locals of a function from .debug_info: the DW_TAG_variable and
//! DW_TAG_formal_parameter DIEs under the frame's DW_TAG_subprogram,
//! with each one's name and location (RA8EMU-805).
//!
//! 32-bit DWARF 2 to 5 with 4-byte addresses, the same scope info.zig
//! reads. A location is taken only when it is exactly one of the four
//! shapes a stopped core can answer: an offset from the frame base
//! (DW_OP_fbreg), a register plus an offset (DW_OP_bregN), a register
//! (DW_OP_regN) or a fixed address (DW_OP_addr). Any other expression,
//! a multi-op one included, comes back with no location rather than a
//! guess, and the pane shows it as optimized out.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const dwarf_cursor = @import("cursor.zig");
const dwarf_info = @import("info.zig");
const dwarf_line = @import("line/line.zig");

const Cursor = dwarf_cursor.Cursor;
pub const Error = dwarf_cursor.Error;

/// The sections a locals walk reads.
pub const Sections = struct {
    info: []const u8 = &.{},
    abbrev: []const u8 = &.{},
    str: []const u8 = &.{},
};

/// The sections of an image, empty when it has none.
pub fn ofImage(image: elf.Image) Sections {
    return .{
        .info = dwarf_line.section(image, ".debug_info"),
        .abbrev = dwarf_line.section(image, ".debug_abbrev"),
        .str = dwarf_line.section(image, ".debug_str"),
    };
}

pub const tag = struct {
    pub const formal_parameter: u64 = 0x05;
    pub const variable: u64 = 0x34;
};

pub const attribute = struct {
    pub const location: u64 = 0x02;
    pub const name: u64 = 0x03;
    pub const byte_size: u64 = 0x0b;
    pub const type_ref: u64 = 0x49;
};

pub const form = struct {
    pub const addr: u64 = 0x01;
    pub const block2: u64 = 0x03;
    pub const block4: u64 = 0x04;
    pub const data2: u64 = 0x05;
    pub const data4: u64 = 0x06;
    pub const data8: u64 = 0x07;
    pub const string: u64 = 0x08;
    pub const block1: u64 = 0x0a;
    pub const data1: u64 = 0x0b;
    pub const flag_present: u64 = 0x19;
    pub const sdata: u64 = 0x0d;
    pub const strp: u64 = 0x0e;
    pub const udata: u64 = 0x0f;
    pub const indirect: u64 = 0x16;
    pub const exprloc: u64 = 0x18;
    pub const ref_addr: u64 = 0x10;
    pub const ref1: u64 = 0x11;
    pub const ref2: u64 = 0x12;
    pub const ref4: u64 = 0x13;
    pub const ref8: u64 = 0x14;
    pub const ref_udata: u64 = 0x15;
    pub const implicit_const: u64 = 0x21;
};

pub const op = struct {
    pub const addr: u8 = 0x03;
    pub const reg_base: u8 = 0x50;
    pub const breg_base: u8 = 0x70;
    pub const fbreg: u8 = 0x91;
};

/// Where a local lives, in a shape a stopped core can evaluate.
pub const Where = union(enum) {
    /// At an offset from the frame base (DW_OP_fbreg).
    frame: i64,
    /// In a register plus an offset (DW_OP_bregN).
    register: struct { reg: u8, offset: i64 },
    /// In a register outright (DW_OP_regN).
    in_register: u8,
    /// At a fixed address (DW_OP_addr).
    address: u32,
};

/// One local: its name and where it lives. `where` is null when the
/// location is a shape this reader does not take.
pub const Local = struct {
    name: []const u8,
    where: ?Where,
    /// The type's name and byte size when the image says both; empty
    /// and zero when the chain runs out before either.
    type_name: []const u8 = "",
    size: u32 = 0,
};

/// The locals of the function holding `address`, written into `into`,
/// and how many were written. Locals of nested lexical blocks count as
/// the function's; locals past `into`'s capacity are dropped.
pub fn inFunction(sections: Sections, address: u32, into: []Local) Error!usize {
    var written: usize = 0;
    var offset: usize = 0;
    while (offset < sections.info.len) {
        var cursor = Cursor{ .bytes = sections.info, .at = offset };
        const length = try cursor.int(u32);
        if (length >= 0xFFFF_FFF0) return Error.Unsupported;
        const end = cursor.at + length;
        if (end > sections.info.len) return Error.Truncated;
        cursor.bytes = sections.info[0..end];
        if (try dwarf_info.header(&cursor, sections.abbrev)) |table| {
            try scan(&cursor, table, sections, offset, address, into, &written);
        }
        offset = end;
    }
    return written;
}

/// One DIE's gathered attributes.
const Die = struct {
    low: ?u64 = null,
    high: ?u64 = null,
    high_is_end: bool = false,
    name: ?[]const u8 = null,
    location: ?[]const u8 = null,
    type_ref: ?u64 = null,
    type_global: bool = false,
    byte_size: ?u64 = null,

    fn take(self: *Die, name: u64, value: ?Attr) void {
        const seen = value orelse return;
        switch (name) {
            attribute.name => self.name = seen.text,
            attribute.location => self.location = seen.block,
            attribute.type_ref => {
                if (seen.number != 0) {
                    self.type_ref = seen.number;
                    self.type_global = seen.global;
                }
            },
            attribute.byte_size => self.byte_size = seen.number,
            dwarf_info.attribute.low_pc => {
                if (seen.address) self.low = seen.number;
            },
            dwarf_info.attribute.high_pc => {
                self.high = seen.number;
                self.high_is_end = seen.address;
            },
            else => {},
        }
    }

    /// Whether the DIE's [low, high) covers `address`.
    fn covers(self: Die, address: u32) bool {
        const low = self.low orelse return false;
        const high = self.high orelse return false;
        const end = if (self.high_is_end) high else low +| high;
        return address >= low and address < end;
    }
};

fn scan(cursor: *Cursor, table: []const u8, sections: Sections, unit: u64, address: u32, into: []Local, written: *usize) Error!void {
    var depth: usize = 0;
    var collect: ?usize = null;
    while (!cursor.done()) {
        const code = try cursor.uleb();
        if (code == 0) {
            if (depth > 0) {
                depth -= 1;
                if (collect != null and depth == collect.?) collect = null;
            }
            continue;
        }
        const spec = try specOf(table, code);
        var die = Die{};
        var abbrev_cursor = spec.cursor;
        while (true) {
            const name = try abbrev_cursor.uleb();
            const kind = try abbrev_cursor.uleb();
            if (name == 0 and kind == 0) break;
            const implicit: i64 = if (kind == form.implicit_const) try abbrev_cursor.sleb() else 0;
            die.take(name, try read(cursor, kind, implicit, sections.str));
        }
        if (collect != null) {
            if ((spec.tag == tag.variable or spec.tag == tag.formal_parameter) and written.* < into.len) {
                var local = Local{ .name = die.name orelse "", .where = if (die.location) |bytes| where(bytes) else null };
                if (die.type_ref) |ref| {
                    const found = describeType(sections, unit, ref, die.type_global, 0) catch null;
                    if (found) |kind| {
                        if (kind.name) |text| local.type_name = text;
                        if (kind.byte_size) |bytes| local.size = @truncate(bytes);
                    }
                }
                into[written.*] = local;
                written.* += 1;
            }
        } else if (spec.tag == dwarf_info.tag_subprogram and spec.children and die.covers(address)) {
            collect = depth;
        }
        if (spec.children) depth += 1;
    }
}

const Spec = struct { tag: u64, children: bool, cursor: Cursor };

/// The abbreviation `code`, its cursor on the first attribute spec.
fn specOf(abbrev: []const u8, code: u64) Error!Spec {
    var cursor = Cursor{ .bytes = abbrev };
    while (true) {
        const at = try cursor.uleb();
        if (at == 0) return Error.Unsupported;
        const spec_tag = try cursor.uleb();
        const children = (try cursor.byte()) != 0;
        if (at == code) return .{ .tag = spec_tag, .children = children, .cursor = cursor };
        while (true) {
            const name = try cursor.uleb();
            const kind = try cursor.uleb();
            if (name == 0 and kind == 0) break;
            if (kind == form.implicit_const) _ = try cursor.sleb();
        }
    }
}

const Attr = struct { number: u64 = 0, address: bool = false, global: bool = false, block: ?[]const u8 = null, text: ?[]const u8 = null };

/// An attribute's value when its form carries one this reader needs,
/// else an empty one once the cursor is past it.
fn read(cursor: *Cursor, kind: u64, implicit: i64, str: []const u8) Error!Attr {
    return switch (kind) {
        form.addr => .{ .number = try cursor.int(u32), .address = true },
        form.ref_addr => .{ .number = try cursor.int(u32), .global = true },
        form.ref1 => .{ .number = try cursor.byte() },
        form.ref2 => .{ .number = try cursor.int(u16) },
        form.ref4 => .{ .number = try cursor.int(u32) },
        form.ref8 => .{ .number = try cursor.int(u64) },
        form.ref_udata => .{ .number = try cursor.uleb() },
        form.data1 => .{ .number = try cursor.byte() },
        form.data2 => .{ .number = try cursor.int(u16) },
        form.data4 => .{ .number = try cursor.int(u32) },
        form.data8 => .{ .number = try cursor.int(u64) },
        form.udata => .{ .number = try cursor.uleb() },
        form.sdata => .{ .number = @bitCast(try cursor.sleb()) },
        form.implicit_const => .{ .number = @bitCast(implicit) },
        form.flag_present => .{ .number = 1 },
        form.string => .{ .text = try cursor.string() },
        form.strp => .{ .text = try dwarf_cursor.stringAt(str, try cursor.int(u32)) },
        form.exprloc => .{ .block = try cursor.take(std.math.cast(usize, try cursor.uleb()) orelse return Error.Truncated) },
        form.block1 => .{ .block = try cursor.take(try cursor.byte()) },
        form.block2 => .{ .block = try cursor.take(try cursor.int(u16)) },
        form.block4 => .{ .block = try cursor.take(try cursor.int(u32)) },
        form.indirect => read(cursor, try cursor.uleb(), implicit, str),
        else => {
            try dwarf_info.skip(cursor, kind);
            return .{};
        },
    };
}

/// Where an expression says, when it is exactly one shape.
fn where(bytes: []const u8) ?Where {
    var cursor = Cursor{ .bytes = bytes };
    const first = cursor.byte() catch return null;
    const found: Where = switch (first) {
        op.fbreg => .{ .frame = cursor.sleb() catch return null },
        op.breg_base...op.breg_base + 31 => .{ .register = .{ .reg = first - op.breg_base, .offset = cursor.sleb() catch return null } },
        op.reg_base...op.reg_base + 31 => .{ .in_register = first - op.reg_base },
        op.addr => .{ .address = cursor.int(u32) catch return null },
        else => return null,
    };
    if (!cursor.done()) return null;
    return found;
}

/// The type of a local, from the type DIE its DW_AT_type names: its own
/// name and byte size, or the nearest the chain of DW_AT_type links
/// carries, depth-bounded so a cycle answers empty. Absolute offsets
/// (DW_FORM_ref_addr) skip the unit arithmetic.
pub fn describeType(sections: Sections, unit: u64, offset: u64, global: bool, depth: usize) Error!?Type {
    if (depth >= 4) return null;
    const at = if (global) offset else unit + offset;
    if (at >= sections.info.len) return null;
    var cursor = Cursor{ .bytes = sections.info, .at = @intCast(at) };
    const code = try cursor.uleb();
    if (code == 0) return null;
    const spec = try specOf(sections.abbrev, code);
    var die = Die{};
    var abbrev_cursor = spec.cursor;
    while (true) {
        const name = try abbrev_cursor.uleb();
        const kind = try abbrev_cursor.uleb();
        if (name == 0 and kind == 0) break;
        const implicit: i64 = if (kind == form.implicit_const) try abbrev_cursor.sleb() else 0;
        die.take(name, try read(&cursor, kind, implicit, sections.str));
    }
    var found = Type{};
    if (die.name) |text| found.name = text;
    if (die.byte_size) |bytes| found.byte_size = bytes;
    if (die.type_ref) |ref| {
        const next = describeType(sections, unit, ref, die.type_global, depth + 1) catch null;
        if (next) |later| {
            if (found.name == null) found.name = later.name;
            if (found.byte_size == null) found.byte_size = later.byte_size;
        }
    }
    if (found.name == null and found.byte_size == null) return null;
    return found;
}

/// One type DIE's answer.
pub const Type = struct {
    name: ?[]const u8 = null,
    byte_size: ?u64 = null,
};
