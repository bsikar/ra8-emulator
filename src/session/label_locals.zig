//! Resolve labels only for DWARF locals that are active in the selected frame.
const std = @import("std");

const labels = @import("labels.zig");
const locals = @import("dwarf/locals.zig");
const vars = @import("dwarf/vars.zig");

pub fn keyOf(view: labels.View, local: vars.Variable) ?labels.Key {
    const die = std.math.cast(u32, local.die_offset) orelse return null;
    var scope: labels.Scope = .{ .entry = die, .storage = .address };
    const address = switch (local.location) {
        .address => |address| address,
        .frame => |offset| blk: {
            scope.storage = .frame_offset;
            break :blk offsetKey(offset) orelse return null;
        },
        .in_register => |reg| blk: {
            scope.storage = .register;
            break :blk reg;
        },
        .register_offset => |location| blk: {
            scope.storage = .register_offset;
            scope.register = location.reg;
            break :blk offsetKey(location.offset) orelse return null;
        },
        .read_only => return null,
    };
    return .{ .core = view.core, .address = address, .frame = scope };
}

fn offsetKey(offset: i64) ?u32 {
    const signed = std.math.cast(i32, offset) orelse return null;
    return @bitCast(signed);
}

pub fn nameOf(view: labels.View, local: vars.Variable) ?[]const u8 {
    const key = keyOf(view, local) orelse return null;
    const entry = view.map.at(key) orelse return null;
    return entry.name();
}

pub fn byName(view: labels.View, sections: locals.Sections, pc: u32, wanted: []const u8) !?vars.Variable {
    if (!hasLocalName(view, wanted)) return null;
    var rows: [64]locals.Local = undefined;
    const count = try locals.inFunction(sections, pc, &rows);
    var found: ?vars.Variable = null;
    for (rows[0..count]) |row| {
        const variable = (try vars.findLocal(sections, pc, row.name)) orelse continue;
        const name = nameOf(view, variable) orelse continue;
        if (!std.mem.eql(u8, name, wanted)) continue;
        if (found) |prior| {
            if (prior.die_offset != variable.die_offset) return error.AmbiguousLabel;
        }
        found = variable;
    }
    return found;
}

fn hasLocalName(view: labels.View, wanted: []const u8) bool {
    for (view.map.entries[0..view.map.len]) |*entry| {
        if (entry.key.core != view.core or entry.key.frame == null) continue;
        if (std.mem.eql(u8, entry.name(), wanted)) return true;
    }
    return false;
}

pub fn hasLocals(view: labels.View) bool {
    for (view.map.entries[0..view.map.len]) |entry| {
        if (entry.key.core == view.core and entry.key.frame != null) return true;
    }
    return false;
}
