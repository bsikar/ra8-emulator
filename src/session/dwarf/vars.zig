//! DWARF variable location classification, type resolution, scope lookup,
//! and frame-base evaluation for mutating locals and typed globals.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const Cursor = @import("cursor.zig").Cursor;
const dwarf_line = @import("line/line.zig");
const locals = @import("locals.zig");
const var_loc = @import("var_loc.zig");
const dwarf = std.dwarf;

pub const ReadOnlyReason = var_loc.ReadOnlyReason;
pub const Location = var_loc.Location;
pub const reasonText = var_loc.reasonText;
pub const frameBaseAddress = var_loc.frameBaseAddress;

pub const Encoding = enum {
    unknown,
    signed,
    unsigned,
    float,
    boolean,
    address,
    utf,
};

pub const TypeInfo = struct {
    name: []const u8 = "",
    size: u32 = 0,
    encoding: Encoding = .unknown,
    is_scalar: bool = false,
    is_const: bool = false,
    is_volatile: bool = false,
};

pub const Variable = struct {
    name: []const u8,
    scope: enum { local, global },
    location: Location,
    type_info: TypeInfo,
    frame_base_expr: []const u8 = "",
};

const UnitHeader = struct {
    version: u16,
    abbrev_off: u32,
    addr_size: u8,
    end: usize,
    dies_start: usize,
    cu_start: usize,
};

const ScopeFrame = struct {
    is_func: bool,
    active: bool,
    frame_base: []const u8,
};

const AttrRecord = struct {
    name: []const u8 = "",
    type_ref: ?u64 = null,
    low_pc: ?u64 = null,
    high_pc: ?u64 = null,
    high_is_len: bool = false,
    loc_form: ?u64 = null,
    loc_bytes: ?[]const u8 = null,
    has_const_val: bool = false,
    is_decl: bool = false,
    frame_base: ?[]const u8 = null,
    byte_size: ?u64 = null,
    encoding: ?u64 = null,
};

/// Return true when an ELF carries DWARF `.debug_info` and `.debug_abbrev`.
pub fn hasDebugInfo(sections: locals.Sections) bool {
    return sections.info.len > 0 and sections.abbrev.len > 0;
}

/// Return the raw `.debug_frame` section bytes for `image`, empty if absent.
pub fn frameSection(image: elf.Image) []const u8 {
    return dwarf_line.section(image, ".debug_frame");
}

/// Find the innermost in-scope local variable or parameter matching `wanted` at `pc`.
pub fn findLocal(sections: locals.Sections, pc: u32, wanted: []const u8) !?Variable {
    if (!hasDebugInfo(sections)) return null;
    var unit_pos: usize = 0;
    while (unit_pos < sections.info.len) {
        const unit = (try readUnitHeader(sections.info, unit_pos)) orelse break;
        unit_pos = unit.end;
        if (try searchUnitLocal(sections, unit, pc, wanted)) |found| return found;
    }
    return null;
}

/// Find a top-level DWARF global variable matching `wanted`.
pub fn findGlobal(sections: locals.Sections, wanted: []const u8) !?Variable {
    if (!hasDebugInfo(sections)) return null;
    var unit_pos: usize = 0;
    while (unit_pos < sections.info.len) {
        const unit = (try readUnitHeader(sections.info, unit_pos)) orelse break;
        unit_pos = unit.end;
        if (try searchUnitGlobal(sections, unit, wanted)) |found| return found;
    }
    return null;
}

fn searchUnitLocal(sections: locals.Sections, unit: UnitHeader, pc: u32, wanted: []const u8) !?Variable {
    if (unit.abbrev_off >= sections.abbrev.len) return null;
    const cu_abbrev = sections.abbrev[unit.abbrev_off..];
    var cur = Cursor{ .bytes = sections.info[0..unit.end], .at = unit.dies_start };
    var scopes: [32]ScopeFrame = undefined;
    var depth: usize = 0;
    var matched: ?Variable = null;

    while (!cur.done()) {
        const code = try cur.uleb();
        if (code == 0) {
            if (depth > 0) depth -= 1;
            continue;
        }
        const ab = locals.specOf(cu_abbrev, code) catch return null;
        const attrs = try readAttrs(&cur, ab, unit, sections);
        const parent_active = depth == 0 or scopes[depth - 1].active;

        if (ab.tag == dwarf.TAG.subprogram or ab.tag == dwarf.TAG.lexical_block) {
            const in_range = rangeContains(attrs, pc);
            const active = parent_active and (in_range orelse (ab.tag == dwarf.TAG.lexical_block and attrs.low_pc == null));
            if (ab.children and depth < scopes.len) {
                const fb = if (ab.tag == dwarf.TAG.subprogram) (attrs.frame_base orelse "") else if (depth > 0) scopes[depth - 1].frame_base else "";
                scopes[depth] = .{ .is_func = ab.tag == dwarf.TAG.subprogram, .active = active, .frame_base = fb };
                depth += 1;
            }
            continue;
        }
        if (hasActiveFunc(scopes[0..depth]) and parent_active and !attrs.is_decl and
            (ab.tag == dwarf.TAG.variable or ab.tag == dwarf.TAG.formal_parameter) and
            std.mem.eql(u8, attrs.name, wanted))
        {
            const ti = if (attrs.type_ref) |ref| try resolveType(sections, unit, ref, 0) else TypeInfo{};
            matched = .{
                .name = attrs.name,
                .scope = .local,
                .location = var_loc.classify(attrs.loc_form, attrs.loc_bytes, attrs.has_const_val, unit.addr_size),
                .type_info = ti,
                .frame_base_expr = activeFrameBase(scopes[0..depth]),
            };
        }
        if (ab.children and depth < scopes.len) {
            const unit_root = ab.tag == dwarf.TAG.compile_unit or ab.tag == dwarf.TAG.partial_unit or ab.tag == dwarf.TAG.namespace;
            scopes[depth] = .{ .is_func = false, .active = parent_active and unit_root, .frame_base = "" };
            depth += 1;
        }
    }
    return matched;
}

fn searchUnitGlobal(sections: locals.Sections, unit: UnitHeader, wanted: []const u8) !?Variable {
    if (unit.abbrev_off >= sections.abbrev.len) return null;
    const cu_abbrev = sections.abbrev[unit.abbrev_off..];
    var cur = Cursor{ .bytes = sections.info[0..unit.end], .at = unit.dies_start };
    var depth: usize = 0;

    while (!cur.done()) {
        const code = try cur.uleb();
        if (code == 0) {
            if (depth > 0) depth -= 1;
            continue;
        }
        const ab = locals.specOf(cu_abbrev, code) catch return null;
        const attrs = try readAttrs(&cur, ab, unit, sections);
        if (depth == 1 and ab.tag == dwarf.TAG.variable and !attrs.is_decl and std.mem.eql(u8, attrs.name, wanted)) {
            const ti = if (attrs.type_ref) |ref| try resolveType(sections, unit, ref, 0) else TypeInfo{};
            return .{
                .name = attrs.name,
                .scope = .global,
                .location = var_loc.classify(attrs.loc_form, attrs.loc_bytes, attrs.has_const_val, unit.addr_size),
                .type_info = ti,
            };
        }
        if (ab.children) depth += 1;
    }
    return null;
}

fn readUnitHeader(bytes: []const u8, offset: usize) !?UnitHeader {
    if (offset + 4 > bytes.len) return null;
    var cur = Cursor{ .bytes = bytes, .at = offset };
    const raw_len = try cur.int(u32);
    if (raw_len == 0 or raw_len >= 0xffff_fff0) return null;
    const end = @min(cur.at + raw_len, bytes.len);
    const version = try cur.int(u16);
    if (version >= 5) _ = try cur.byte();
    const addr_size = if (version >= 5) try cur.byte() else 0;
    const abbrev_off = try cur.int(u32);
    const actual_addr = if (version >= 5) addr_size else try cur.byte();
    if (actual_addr != 4 and actual_addr != 8) return error.BadAddrSize;
    return .{
        .version = version,
        .abbrev_off = abbrev_off,
        .addr_size = actual_addr,
        .end = end,
        .dies_start = cur.at,
        .cu_start = offset,
    };
}

fn readAttrs(cur: *Cursor, spec: locals.Spec, unit: UnitHeader, sections: locals.Sections) !AttrRecord {
    var rec: AttrRecord = .{};
    var sc = spec.cursor;
    while (true) {
        const name = try sc.uleb();
        const kind = try sc.uleb();
        if (name == 0 and kind == 0) break;
        const implicit: i64 = if (kind == dwarf.FORM.implicit_const) try sc.sleb() else 0;
        const val = try locals.readAttr(cur, kind, implicit, sections.str);
        switch (name) {
            dwarf.AT.name => rec.name = val.text orelse "",
            dwarf.AT.type => rec.type_ref = if (val.global) val.number else unit.cu_start + val.number,
            dwarf.AT.low_pc => if (val.address) {
                rec.low_pc = val.number;
            },
            dwarf.AT.high_pc => if (val.address or kind != dwarf.FORM.addr) {
                rec.high_pc = val.number;
                rec.high_is_len = !val.address;
            },
            dwarf.AT.location => {
                rec.loc_form = kind;
                rec.loc_bytes = val.block;
            },
            dwarf.AT.frame_base => rec.frame_base = val.block,
            dwarf.AT.const_value => rec.has_const_val = true,
            dwarf.AT.declaration => rec.is_decl = val.number != 0,
            dwarf.AT.byte_size => rec.byte_size = val.number,
            dwarf.AT.encoding => rec.encoding = val.number,
            else => {},
        }
    }
    return rec;
}

fn resolveType(sections: locals.Sections, unit: UnitHeader, sec_offset: u64, depth: usize) anyerror!TypeInfo {
    if (depth > 16 or sec_offset >= sections.info.len) return .{};
    const target_unit = (try unitContaining(sections.info, sec_offset)) orelse unit;
    if (target_unit.abbrev_off >= sections.abbrev.len) return .{};
    if (sec_offset < target_unit.dies_start or sec_offset >= target_unit.end) return .{};
    const cu_abbrev = sections.abbrev[target_unit.abbrev_off..];
    var cur = Cursor{ .bytes = sections.info[0..target_unit.end], .at = @intCast(sec_offset) };
    const code = cur.uleb() catch return .{};
    if (code == 0) return .{};
    const ab = locals.specOf(cu_abbrev, code) catch return .{};
    const attrs = readAttrs(&cur, ab, target_unit, sections) catch return .{};

    return switch (ab.tag) {
        dwarf.TAG.base_type => .{
            .name = attrs.name,
            .size = @intCast(@min(attrs.byte_size orelse 0, std.math.maxInt(u32))),
            .encoding = mapEncoding(attrs.encoding),
            .is_scalar = true,
        },
        dwarf.TAG.pointer_type => .{
            .name = if (attrs.name.len > 0) attrs.name else "*",
            .size = @intCast(attrs.byte_size orelse target_unit.addr_size),
            .encoding = .address,
            .is_scalar = true,
        },
        dwarf.TAG.enumeration_type => .{
            .name = attrs.name,
            .size = @intCast(@min(attrs.byte_size orelse 0, std.math.maxInt(u32))),
            .encoding = .unsigned,
            .is_scalar = attrs.byte_size != null,
        },
        dwarf.TAG.typedef, dwarf.TAG.const_type, dwarf.TAG.volatile_type, dwarf.TAG.restrict_type, dwarf.TAG.atomic_type => {
            var inner = if (attrs.type_ref) |ref| try resolveType(sections, target_unit, ref, depth + 1) else TypeInfo{};
            if (ab.tag == dwarf.TAG.typedef and attrs.name.len > 0) inner.name = attrs.name;
            if (ab.tag == dwarf.TAG.const_type) inner.is_const = true;
            if (ab.tag == dwarf.TAG.volatile_type) inner.is_volatile = true;
            return inner;
        },
        else => .{
            .name = attrs.name,
            .size = @intCast(@min(attrs.byte_size orelse 0, std.math.maxInt(u32))),
            .is_scalar = false,
        },
    };
}

fn unitContaining(info_bytes: []const u8, offset: u64) !?UnitHeader {
    var pos: usize = 0;
    while (pos < info_bytes.len) {
        const unit = (try readUnitHeader(info_bytes, pos)) orelse break;
        if (offset >= pos and offset < unit.end) return unit;
        pos = unit.end;
    }
    return null;
}

fn mapEncoding(raw: ?u64) Encoding {
    const code = raw orelse return .unknown;
    return switch (code) {
        dwarf.ATE.address => .address,
        dwarf.ATE.boolean => .boolean,
        dwarf.ATE.float => .float,
        dwarf.ATE.signed, dwarf.ATE.signed_char => .signed,
        dwarf.ATE.unsigned, dwarf.ATE.unsigned_char => .unsigned,
        dwarf.ATE.UTF => .utf,
        else => .unknown,
    };
}

fn rangeContains(attrs: AttrRecord, pc: u32) ?bool {
    const low = attrs.low_pc orelse return null;
    const high_raw = attrs.high_pc orelse return null;
    const high = if (attrs.high_is_len) low +| high_raw else high_raw;
    return pc >= low and pc < high;
}

fn hasActiveFunc(scopes: []const ScopeFrame) bool {
    for (scopes) |s| if (s.is_func and s.active) return true;
    return false;
}

fn activeFrameBase(scopes: []const ScopeFrame) []const u8 {
    var i = scopes.len;
    while (i > 0) {
        i -= 1;
        if (scopes[i].is_func and scopes[i].active) return scopes[i].frame_base;
    }
    return "";
}
