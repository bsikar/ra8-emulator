//! Mutate live/rewound variable state by symbol or DWARF local name using
//! Session.write / Session.setRegister and typed little-endian encoding.
const std = @import("std");
const Session = @import("api.zig").Session;
const Core = @import("api.zig").Core;
const core_view = @import("core_view.zig");
const elf = @import("ra8_board").image.elf;
const Cortex = core_view.Cortex;
const symbols = @import("symbols.zig");
const dwarf = @import("dwarf/dwarf.zig");
const vars = dwarf.vars;
const unwind = @import("unwind/unwind.zig");

pub const Status = enum(u8) {
    ok = 0,
    unknown_variable = 1,
    no_dwarf = 2,
    read_only = 3,
    invalid_value = 4,
    overflow = 5,
    unsupported_type = 6,
    frame_unavailable = 7,
    write_failed = 8,
};

pub const Scope = enum(u8) {
    none = 0,
    global = 1,
    local = 2,
};

pub const ScalarKind = enum {
    signed,
    unsigned,
    float,
    boolean,
    untyped,
};

pub const Result = struct {
    status: Status,
    scope: Scope = .none,
    address: u32 = 0,
    in_register: u8 = 0xff,
    size: u32 = 0,
    message: []const u8,
};

pub const EncodeError = error{
    InvalidValue,
    Overflow,
    UnsupportedWidth,
};

/// Map DWARF type info to the scalar encoding category used for input parsing.
pub fn inferKind(info: vars.TypeInfo) error{NonScalar}!ScalarKind {
    if (!info.is_scalar and info.encoding == .unknown) {
        if (info.size > 0 or info.name.len > 0) return error.NonScalar;
        return .untyped;
    }
    return switch (info.encoding) {
        .signed => .signed,
        .unsigned, .address, .utf => .unsigned,
        .float => .float,
        .boolean => .boolean,
        .unknown => .untyped,
    };
}

/// Encode `raw_value` as `width` little-endian bytes according to `kind`.
pub fn encodeValue(raw_value: []const u8, width: u32, kind: ScalarKind, out: *[8]u8) EncodeError![]const u8 {
    const val = std.mem.trim(u8, raw_value, " \t\r\n");
    if (val.len == 0) return error.InvalidValue;
    if (width != 1 and width != 2 and width != 4 and width != 8) return error.UnsupportedWidth;

    switch (kind) {
        .signed => return encodeSigned(val, width, out),
        .unsigned => return encodeUnsigned(val, width, out),
        .untyped => return encodeUntyped(val, width, out),
        .float => return encodeFloat(val, width, out),
        .boolean => return encodeBool(val, width, out),
    }
}

/// Resolve and write `name=value` against `core` and `frame_idx`.
pub fn set(session: *Session, core: Core, image: elf.Image, frame_idx: u32, name: []const u8, value: []const u8) !Result {
    const view = session.view(core) catch |err| switch (err) {
        error.CoreNotAttached => return fail(.frame_unavailable, .none, "core is not attached"),
        else => return fail(.frame_unavailable, .none, "core view unavailable"),
    };
    const regs = resolveFrameRegisters(session, core, image, view, frame_idx) catch {
        return fail(.frame_unavailable, .none, "requested stack frame is unavailable");
    };
    const sections = dwarf.locals.ofImage(image);
    const frame_bytes = vars.frameSection(image);
    const has_dwarf = vars.hasDebugInfo(sections);

    if (has_dwarf) {
        const lookup_pc = if (frame_idx == 0) regs[15] & ~@as(u32, 1) else (regs[15] & ~@as(u32, 1)) -| 1;
        if (try vars.findLocal(sections, lookup_pc, name)) |local| {
            return writeLocal(session, core, frame_idx, frame_bytes, regs, local, value);
        }
    }

    const sym = symbols.symbolOf(image, name);
    const dglob = if (has_dwarf) try vars.findGlobal(sections, name) else null;
    if (sym != null or dglob != null) {
        return writeGlobal(session, core, sym, dglob, value);
    }

    if (!has_dwarf) {
        return fail(.no_dwarf, .none, "variable not found in .symtab; locals not available (no DWARF debug info)");
    }
    return fail(.unknown_variable, .none, "unknown variable");
}

fn writeLocal(
    session: *Session,
    core: Core,
    frame_idx: u32,
    frame_bytes: []const u8,
    regs: unwind.Registers,
    local: vars.Variable,
    value: []const u8,
) Result {
    switch (local.location) {
        .read_only => |reason| return fail(.read_only, .local, vars.reasonText(reason)),
        else => {},
    }
    const kind = inferKind(local.type_info) catch return fail(.unsupported_type, .local, "non-scalar local cannot be set");
    const width = local.type_info.size;
    var buf: [8]u8 = undefined;
    const encoded = encodeValue(value, width, kind, &buf) catch |err| return mapEncodeError(err, .local);

    switch (local.location) {
        .in_register => |reg_num| {
            if (frame_idx > 0) return fail(.read_only, .local, "register local in non-top frame cannot be written directly");
            const reg = dwarfToProtoReg(reg_num) orelse return fail(.read_only, .local, "extended register cannot be written");
            if (width == 8) return fail(.unsupported_type, .local, "8-byte value does not fit in one 32-bit register");
            const val_u32 = decodeToU32(encoded, kind == .signed);
            session.setRegister(core, reg, val_u32) catch |err| return mapWriteError(err, .local);
            return .{ .status = .ok, .scope = .local, .in_register = reg_num, .size = width, .message = "updated local register" };
        },
        .frame => |fb_off| {
            const base = vars.frameBaseAddress(frame_bytes, local.frame_base_expr, regs) catch {
                return fail(.read_only, .local, vars.reasonText(.missing_frame_base));
            };
            const addr = addSigned(base, fb_off);
            session.write(core, addr, encoded) catch |err| return mapWriteError(err, .local);
            return .{ .status = .ok, .scope = .local, .address = addr, .size = width, .message = "updated local variable" };
        },
        .register_offset => |ro| {
            if (ro.reg >= regs.len) return fail(.read_only, .local, "register base unavailable for local variable");
            const addr = addSigned(regs[ro.reg], ro.offset);
            session.write(core, addr, encoded) catch |err| return mapWriteError(err, .local);
            return .{ .status = .ok, .scope = .local, .address = addr, .size = width, .message = "updated local variable" };
        },
        .address => |addr| {
            session.write(core, addr, encoded) catch |err| return mapWriteError(err, .local);
            return .{ .status = .ok, .scope = .local, .address = addr, .size = width, .message = "updated static local variable" };
        },
        .read_only => unreachable,
    }
}

fn writeGlobal(
    session: *Session,
    core: Core,
    sym: ?symbols.Named,
    dglob: ?vars.Variable,
    value: []const u8,
) Result {
    if (sym) |s| {
        if (s.kind == symbols.symbol_type.func) {
            return fail(.unsupported_type, .global, "symbol is a function, not a writable variable");
        }
    }
    if (dglob) |g| {
        switch (g.location) {
            .read_only => |reason| if (sym == null) return fail(.read_only, .global, vars.reasonText(reason)),
            else => {},
        }
    }
    const type_info = if (dglob) |g| g.type_info else vars.TypeInfo{};
    const kind = inferKind(type_info) catch return fail(.unsupported_type, .global, "non-scalar global cannot be set");
    const width = if (sym != null and sym.?.size > 0) sym.?.size else type_info.size;
    if (width == 0) return fail(.unsupported_type, .global, "global symbol has zero byte width");

    const addr = if (sym) |s| s.value else switch (dglob.?.location) {
        .address => |a| a,
        else => return fail(.read_only, .global, "global variable has no mutable memory address"),
    };
    var buf: [8]u8 = undefined;
    const encoded = encodeValue(value, width, kind, &buf) catch |err| return mapEncodeError(err, .global);
    session.write(core, addr, encoded) catch |err| return mapWriteError(err, .global);
    return .{ .status = .ok, .scope = .global, .address = addr, .size = width, .message = "updated global variable" };
}

fn encodeSigned(val: []const u8, width: u32, out: *[8]u8) EncodeError![]const u8 {
    const parsed = std.fmt.parseInt(i64, val, 0) catch |err| return if (err == error.Overflow) error.Overflow else error.InvalidValue;
    const ok = switch (width) {
        1 => parsed >= std.math.minInt(i8) and parsed <= std.math.maxInt(i8),
        2 => parsed >= std.math.minInt(i16) and parsed <= std.math.maxInt(i16),
        4 => parsed >= std.math.minInt(i32) and parsed <= std.math.maxInt(i32),
        8 => true,
        else => unreachable,
    };
    if (!ok) return error.Overflow;
    std.mem.writeInt(i64, out, parsed, .little);
    return out[0..width];
}

fn encodeUnsigned(val: []const u8, width: u32, out: *[8]u8) EncodeError![]const u8 {
    if (val[0] == '-') return error.Overflow;
    const parsed = std.fmt.parseInt(u64, val, 0) catch |err| return if (err == error.Overflow) error.Overflow else error.InvalidValue;
    const limit: u64 = switch (width) {
        1 => std.math.maxInt(u8),
        2 => std.math.maxInt(u16),
        4 => std.math.maxInt(u32),
        8 => std.math.maxInt(u64),
        else => unreachable,
    };
    if (parsed > limit) return error.Overflow;
    std.mem.writeInt(u64, out, parsed, .little);
    return out[0..width];
}

fn encodeUntyped(val: []const u8, width: u32, out: *[8]u8) EncodeError![]const u8 {
    if (val[0] == '-') return encodeSigned(val, width, out);
    return encodeUnsigned(val, width, out);
}

fn encodeFloat(val: []const u8, width: u32, out: *[8]u8) EncodeError![]const u8 {
    const wants_inf = std.ascii.eqlIgnoreCase(val, "inf") or std.ascii.eqlIgnoreCase(val, "+inf") or std.ascii.eqlIgnoreCase(val, "-inf");
    switch (width) {
        4 => {
            const f = std.fmt.parseFloat(f32, val) catch return error.InvalidValue;
            if (!wants_inf and std.math.isInf(f)) return error.Overflow;
            std.mem.writeInt(u32, out[0..4], @bitCast(f), .little);
            return out[0..4];
        },
        8 => {
            const f = std.fmt.parseFloat(f64, val) catch return error.InvalidValue;
            if (!wants_inf and std.math.isInf(f)) return error.Overflow;
            std.mem.writeInt(u64, out, @bitCast(f), .little);
            return out[0..8];
        },
        else => return error.UnsupportedWidth,
    }
}

fn encodeBool(val: []const u8, width: u32, out: *[8]u8) EncodeError![]const u8 {
    @memset(out, 0);
    if (std.ascii.eqlIgnoreCase(val, "true")) {
        out[0] = 1;
        return out[0..width];
    }
    if (std.ascii.eqlIgnoreCase(val, "false")) {
        out[0] = 0;
        return out[0..width];
    }
    const parsed = std.fmt.parseInt(i64, val, 0) catch |err| return if (err == error.Overflow) error.Overflow else error.InvalidValue;
    if (parsed != 0 and parsed != 1) return error.Overflow;
    out[0] = @intCast(parsed);
    return out[0..width];
}

const Reader = struct {
    session: *Session,
    core: Core,
    pub fn readWord(self: Reader, address: u32) !u32 {
        var bytes: [4]u8 = undefined;
        try self.session.read(self.core, address, &bytes);
        return std.mem.readInt(u32, &bytes, .little);
    }
};

fn resolveFrameRegisters(session: *Session, core: Core, image: elf.Image, view: core_view.View, frame_idx: u32) !unwind.Registers {
    var regs = try unwind.registersOf(view);
    if (frame_idx == 0) return regs;
    const frame_bytes = vars.frameSection(image);
    const reader: Reader = .{ .session = session, .core = core };
    var idx: u32 = 0;
    while (idx < frame_idx) : (idx += 1) {
        regs = (unwind.caller(frame_bytes, regs, idx == 0, reader) catch return error.FrameUnavailable) orelse {
            return error.FrameUnavailable;
        };
    }
    return regs;
}

fn dwarfToProtoReg(reg: u8) ?Cortex {
    return switch (reg) {
        0 => .r0,
        1 => .r1,
        2 => .r2,
        3 => .r3,
        4 => .r4,
        5 => .r5,
        6 => .r6,
        7 => .r7,
        8 => .r8,
        9 => .r9,
        10 => .r10,
        11 => .r11,
        12 => .r12,
        13 => .sp,
        14 => .lr,
        15 => .pc,
        else => null,
    };
}

fn decodeToU32(bytes: []const u8, signed: bool) u32 {
    return switch (bytes.len) {
        1 => if (signed) @bitCast(@as(i32, @as(i8, @bitCast(bytes[0])))) else bytes[0],
        2 => if (signed) @bitCast(@as(i32, std.mem.readInt(i16, bytes[0..2], .little))) else std.mem.readInt(u16, bytes[0..2], .little),
        4 => std.mem.readInt(u32, bytes[0..4], .little),
        else => 0,
    };
}

fn mapEncodeError(err: EncodeError, scope: Scope) Result {
    return switch (err) {
        error.Overflow => fail(.overflow, scope, "value overflows target variable type/width"),
        error.InvalidValue => fail(.invalid_value, scope, "invalid value syntax for variable type"),
        error.UnsupportedWidth => fail(.unsupported_type, scope, "unsupported variable byte width (expected 1, 2, 4, or 8)"),
    };
}

fn mapWriteError(err: anyerror, scope: Scope) Result {
    return switch (err) {
        error.ForkNeedsConfirmation => fail(.write_failed, scope, "fork needs confirmation before writing state"),
        else => fail(.write_failed, scope, "memory or register write refused (read-only or unmapped target)"),
    };
}

fn fail(status: Status, scope: Scope, message: []const u8) Result {
    return .{ .status = status, .scope = scope, .message = message };
}

fn addSigned(base: u32, delta: i64) u32 {
    const wrapped: i64 = @as(i64, base) + delta;
    return @truncate(@as(u64, @bitCast(wrapped)));
}
