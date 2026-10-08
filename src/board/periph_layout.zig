//! Peripheral layouts (RA8EMU-818): the blocks a board mapped on its
//! peripheral bus, and the registers of a block, taken from the model's own
//! `off` namespace at comptime so the names and offsets cannot drift from
//! the code that serves them. The pairing table below names models, never
//! registers. A width comes from the model's `off_width` (one width for the
//! block) or `off_widths` (per register); a model that declares neither
//! gives 0, which prints as "?", never a guess from the offset spacing.
const std = @import("std");
const periph = @import("../periph/registry.zig");
const rtc = @import("../periph/rtc/rtc.zig");
const agt = @import("../periph/agt/agt.zig");
const iwdt = @import("../periph/iwdt/iwdt.zig");

pub const Register = struct { name: []const u8, offset: u32, width: u8 };

/// A block name and the registers its model declares.
pub const Layout = struct { block: []const u8, registers: []const Register };

const rtc_registers = registersOf(rtc);
const agt_registers = registersOf(agt);
const iwdt_registers = registersOf(iwdt);

/// Each paired block, under the name its model's block() reports.
pub const layouts = [_]Layout{
    .{ .block = "RTC", .registers = &rtc_registers },
    .{ .block = "AGT", .registers = &agt_registers },
    .{ .block = "IWDT", .registers = &iwdt_registers },
};

fn countOf(comptime model: type) usize {
    var count: usize = 0;
    for (@typeInfo(model.off).@"struct".decl_names) |name| {
        if (@TypeOf(@field(model.off, name)) == u32) count += 1;
    }
    return count;
}

fn widthOf(comptime model: type, comptime name: []const u8) u8 {
    if (@hasDecl(model, "off_widths") and @hasDecl(model.off_widths, name)) return @field(model.off_widths, name);
    if (@hasDecl(model, "off_width")) return model.off_width;
    return 0;
}

/// Every u32 in `model.off`, as a register, in offset order.
pub fn registersOf(comptime model: type) [countOf(model)]Register {
    @setEvalBranchQuota(20_000);
    comptime var out: [countOf(model)]Register = undefined;
    comptime var count: usize = 0;
    inline for (@typeInfo(model.off).@"struct".decl_names) |name| {
        const value = @field(model.off, name);
        if (@TypeOf(value) != u32) continue;
        out[count] = .{ .name = name, .offset = value, .width = widthOf(model, name) };
        count += 1;
    }
    comptime std.mem.sortUnstable(Register, &out, {}, byOffset);
    return out;
}

fn byOffset(_: void, a: Register, b: Register) bool {
    return a.offset < b.offset or (a.offset == b.offset and std.mem.lessThan(u8, a.name, b.name));
}

/// The blocks `bus` holds, in the order the board added them.
pub fn blocks(bus: *const periph.Bus) []const periph.Block {
    return bus.blocks[0..bus.count];
}

/// The registers of the block called `name`, or null when no model is paired.
pub fn registers(name: []const u8) ?[]const Register {
    for (layouts) |layout| {
        if (std.ascii.eqlIgnoreCase(layout.block, name)) return layout.registers;
    }
    return null;
}

/// One line per block: `NAME 0xBASE 0xSIZE`.
pub fn writeBlocks(bus: *const periph.Bus, out: []u8) error{NoSpaceLeft}![]const u8 {
    var writer: std.Io.Writer = .fixed(out);
    for (blocks(bus)) |block| {
        writer.print("{s} 0x{X:0>8} 0x{X}\n", .{ block.name, block.base, block.size }) catch return error.NoSpaceLeft;
    }
    return writer.buffered();
}

/// One line per register of `name`: `name 0xOFFSET WIDTH`, "?" for an
/// undeclared width.
pub fn writeRegisters(name: []const u8, out: []u8) error{ NoSpaceLeft, UnknownBlock }![]const u8 {
    const found = registers(name) orelse return error.UnknownBlock;
    var writer: std.Io.Writer = .fixed(out);
    for (found) |register| {
        writer.print("{s} 0x{X:0>2} ", .{ register.name, register.offset }) catch return error.NoSpaceLeft;
        if (register.width == 0) {
            writer.writeAll("?\n") catch return error.NoSpaceLeft;
        } else writer.print("{d}\n", .{register.width}) catch return error.NoSpaceLeft;
    }
    return writer.buffered();
}
