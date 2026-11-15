//! Control command syntax; transport options are parsed by session_ctl.
const command_types = @import("command.zig");
const ctl_branch = @import("branch.zig");
const ctl_nav = @import("nav.zig");
const ctl_write = @import("write.zig");
const events = @import("events.zig");
const proto = @import("ra8_rpc").session.rpc;
const std = @import("std");

const Command = command_types.Command;
const Folded = command_types.Folded;

/// What `regs` reads when it is given no names.
const default_regs = [_]proto.Register{
    .r0,
    .r1,
    .r2,
    .r3,
    .r4,
    .r5,
    .r6,
    .r7,
    .r8,
    .r9,
    .r10,
    .r11,
    .r12,
    .sp,
    .lr,
    .pc,
    .xpsr,
};
const max_regs = 32;

const Word = enum {
    branch,
    fork,
    diff,
    load,
    run,
    advance,
    play,
    seek,
    frame,
    iter,
    frames,
    nav,
    marker,
    rc,
    step,
    pause,
    map,
    stack,
    rtc,
    folded,
    periph,
    regs,
    speed,
    @"break",
    watch,
    events,
    plug,
    unplug,
    fault,
    snapshot,
    restore,
    mem,
};

pub fn command(allocator: std.mem.Allocator, name: []const u8, args: []const []const u8) !Command {
    if (try ctl_write.parseWord(allocator, name, args)) |cmd| return .{ .write_cmd = cmd };
    const word = std.meta.stringToEnum(Word, name) orelse return error.UnknownCommand;
    return switch (word) {
        .branch => .{ .branch_cmd = try ctl_branch.parseBranch(args) },
        .fork => .{ .branch_cmd = try ctl_branch.parseFork(args) },
        .diff => parseDiff(args),
        .load => .{ .load = try single(args) },
        .run => .{ .run = try parseBudget(args) },
        .advance => .{ .advance = try parseAdvance(try single(args)) },
        .play => .{ .play = try ctl_nav.parsePlay(args) },
        .seek => .{ .seek = try ctl_nav.parseSeek(allocator, args) },
        .frame => seek(allocator, "frame", args),
        .iter => seek(allocator, "iter", args),
        .frames => empty(args, .frame_status),
        .nav => .{ .nav = try ctl_nav.parseNav(args) },
        .marker => parseMarker(allocator, args),
        .rc => empty(args, .rc),
        .step => empty(args, .step),
        .pause => empty(args, .pause),
        .map => empty(args, .map),
        .stack => empty(args, .stack),
        .rtc => empty(args, .rtc),
        .folded => .{ .folded = try parseFolded(args) },
        .periph => .{ .periph = try optional(args) },
        .regs => .{ .regs = try parseRegs(allocator, args) },
        .speed => .{ .speed = try parseSpeed(try single(args)) },
        .@"break" => parseBreak(allocator, args),
        .watch => parseWatch(args),
        .events => .{ .events = try events.parse(args) },
        .plug => part(.plug, args),
        .unplug => part(.unplug, args),
        .fault => parseFault(args),
        .snapshot => files(.snapshot, args),
        .restore => files(.restore, args),
        .mem => parseMem(args),
    };
}

fn single(args: []const []const u8) ![]const u8 {
    if (args.len != 1) return error.BadArguments;
    return args[0];
}

fn optional(args: []const []const u8) ![]const u8 {
    if (args.len > 1) return error.BadArguments;
    return if (args.len == 1) args[0] else "";
}

fn empty(args: []const []const u8, value: Command) !Command {
    if (args.len != 0) return error.BadArguments;
    return value;
}

fn files(method: proto.Method, args: []const []const u8) !Command {
    return .{ .files = .{ .method = method, .path = try single(args) } };
}

fn parseDiff(args: []const []const u8) !Command {
    if (args.len != 2) return error.BadArguments;
    return .{ .diff_cmd = .{ .a = args[0], .b = args[1] } };
}

fn parseMarker(allocator: std.mem.Allocator, args: []const []const u8) !Command {
    if (args.len == 3 and std.mem.eql(u8, args[0], "set")) {
        return .{ .marker_set = .{ .name = args[1], .place = args[2] } };
    }
    return seek(allocator, "bm", args);
}

fn parseMem(args: []const []const u8) !Command {
    if (args.len != 2) return error.BadArguments;
    const length = try std.fmt.parseInt(u32, args[1], 0);
    if (length == 0) return error.BadLength;
    return .{ .mem = .{ .address = try std.fmt.parseInt(u32, args[0], 0), .length = length } };
}

/// `folded`, `folded THREAD`, `folded FROM TO` or `folded THREAD FROM TO`.
fn parseFolded(args: []const []const u8) !Folded {
    var asked: Folded = .{};
    const window = switch (args.len) {
        0 => return asked,
        1 => return .{ .thread = try std.fmt.parseInt(u32, args[0], 0) },
        2 => args,
        3 => args[1..],
        else => return error.BadArguments,
    };
    if (args.len == 3) asked.thread = try std.fmt.parseInt(u32, args[0], 0);
    asked.from_ns = try std.fmt.parseInt(u64, window[0], 0);
    asked.to_ns = try std.fmt.parseInt(u64, window[1], 0);
    return asked;
}

/// A duration in events timeout syntax, converted to virtual nanoseconds.
fn parseAdvance(word: []const u8) !u64 {
    const ms: u64 = @intCast(try events.parseDuration(word));
    return ms * std.time.ns_per_ms;
}

fn parseBudget(args: []const []const u8) !u64 {
    if (args.len == 0) return 0;
    if (args.len == 2 and std.mem.eql(u8, args[0], "--budget")) return std.fmt.parseInt(u64, args[1], 0);
    return error.BadArguments;
}

/// `max`, or a positive factor of the default rate kept to thousandths.
fn parseSpeed(word: []const u8) !u64 {
    if (std.mem.eql(u8, word, "max")) return 0;
    const factor = try std.fmt.parseFloat(f64, word);
    if (!std.math.isFinite(factor) or factor < 0.001 or factor > 1e9) return error.BadSpeed;
    return @intFromFloat(@round(factor * 1000.0));
}

fn parseBreak(allocator: std.mem.Allocator, args: []const []const u8) !Command {
    if (args.len == 1) {
        if (std.fmt.parseInt(u32, args[0], 0)) |address| return .{ .set_break = address } else |_| {}
        return .{ .set_break_name = try allocator.dupe(u8, args[0]) };
    }
    if (args.len == 2 and
        std.mem.eql(u8, args[0], "--clear")) return .{ .clear_break = try std.fmt.parseInt(u32, args[1], 0) };
    return error.BadArguments;
}

fn parseWatch(args: []const []const u8) !Command {
    if (args.len != 2) return error.BadArguments;
    if (std.mem.eql(u8, args[0], "--clear")) return .{ .clear_watch = try std.fmt.parseInt(u32, args[1], 0) };
    const access = std.meta.stringToEnum(proto.Access, args[1]) orelse return error.UnknownAccess;
    return .{ .set_watch = .{ .address = try std.fmt.parseInt(u32, args[0], 0), .access = access } };
}

fn part(method: proto.Method, args: []const []const u8) !Command {
    if (args.len != 1) return error.BadArguments;
    return .{ .part = .{ .method = method, .text = args[0] } };
}

fn parseFault(args: []const []const u8) !Command {
    if (args.len == 2 and std.mem.eql(u8, args[0], "--clear")) return part(.clear_fault, args[1..]);
    return part(.set_fault, args);
}

fn parseRegs(allocator: std.mem.Allocator, names: []const []const u8) ![]const proto.Register {
    if (names.len == 0) return &default_regs;
    if (names.len > max_regs) return error.TooManyRegisters;
    const regs = try allocator.alloc(proto.Register, names.len);
    for (names, regs) |name, *reg| {
        reg.* = std.meta.stringToEnum(
            proto.Register,
            name,
        ) orelse return error.UnknownRegister;
    }
    return regs;
}

fn seek(allocator: std.mem.Allocator, prefix: []const u8, args: []const []const u8) !Command {
    if (args.len != 1) return error.BadArguments;
    return .{ .seek = try std.fmt.allocPrint(allocator, "{s} {s}", .{ prefix, args[0] }) };
}
