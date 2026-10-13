//! Line-by-line parser for GUI interaction scripts (RA8EMU-1120).
const std = @import("std");
const action_mod = @import("action.zig");

pub const Action = action_mod.Action;
pub const Item = action_mod.Item;
pub const TimeSpec = action_mod.TimeSpec;
pub const Target = action_mod.Target;
pub const NamedTarget = action_mod.NamedTarget;

pub const ParseError = error{
    BadTiming,
    BadAction,
    BadTarget,
    BadCoordinates,
    InvalidSyntax,
    InvalidNumber,
    OutOfMemory,
};

pub const Script = struct {
    items: std.ArrayListUnmanaged(Item) = .empty,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Script) void {
        for (self.items.items) |item| {
            if (item.action == .type_text) {
                self.allocator.free(item.action.type_text);
            }
        }
        self.items.deinit(self.allocator);
    }
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!Script {
    var script = Script{ .allocator = allocator };
    errdefer script.deinit();

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or std.mem.startsWith(u8, line, "//")) continue;
        const item = try parseLine(allocator, line);
        try script.items.append(allocator, item);
    }
    return script;
}

fn parseLine(allocator: std.mem.Allocator, line: []const u8) ParseError!Item {
    var tokens = std.mem.tokenizeAny(u8, line, " \t");
    const first = tokens.next() orelse return error.InvalidSyntax;
    if (!std.mem.eql(u8, first, "at")) {
        if (std.mem.eql(u8, first, "quit") or std.mem.eql(u8, first, "exit")) {
            return .{ .at = .{ .frame = 0 }, .action = .quit };
        }
        return error.BadAction;
    }

    const time_tok = tokens.next() orelse return error.BadTiming;
    const at = if (std.mem.eql(u8, time_tok, "frame")) blk: {
        const frame_tok = tokens.next() orelse return error.BadTiming;
        const frame = std.fmt.parseInt(u32, frame_tok, 10) catch return error.BadTiming;
        break :blk TimeSpec{ .frame = frame };
    } else blk: {
        const ns = parseTime(time_tok) catch return error.BadTiming;
        break :blk TimeSpec{ .time_ns = ns };
    };

    const action_tok = tokens.next() orelse return error.BadAction;
    const act = try parseAction(allocator, action_tok, &tokens, line);
    return .{ .at = at, .action = act };
}

fn parseTime(tok: []const u8) ParseError!u64 {
    if (std.mem.endsWith(u8, tok, "ms")) {
        const num = std.fmt.parseInt(u64, tok[0 .. tok.len - 2], 10) catch return error.BadTiming;
        return num * std.time.ns_per_ms;
    }
    if (std.mem.endsWith(u8, tok, "us")) {
        const num = std.fmt.parseInt(u64, tok[0 .. tok.len - 2], 10) catch return error.BadTiming;
        return num * std.time.ns_per_us;
    }
    if (std.mem.endsWith(u8, tok, "ns")) {
        return std.fmt.parseInt(u64, tok[0 .. tok.len - 2], 10) catch error.BadTiming;
    }
    if (std.mem.endsWith(u8, tok, "s")) {
        const num_str = tok[0 .. tok.len - 1];
        const val = std.fmt.parseFloat(f64, num_str) catch return error.BadTiming;
        if (val < 0) return error.BadTiming;
        return @intFromFloat(val * 1_000_000_000.0);
    }
    return error.BadTiming;
}

fn parseAction(allocator: std.mem.Allocator, act_tok: []const u8, tokens: *std.mem.TokenIterator(u8, .any), line: []const u8) ParseError!Action {
    if (std.mem.eql(u8, act_tok, "click")) {
        return parseClick(tokens);
    }
    if (std.mem.eql(u8, act_tok, "drag")) {
        return parseDrag(tokens);
    }
    if (std.mem.eql(u8, act_tok, "type")) {
        return parseType(allocator, line);
    }
    if (std.mem.eql(u8, act_tok, "key")) {
        return parseKey(tokens);
    }
    if (std.mem.eql(u8, act_tok, "quit") or std.mem.eql(u8, act_tok, "exit")) {
        return .quit;
    }
    return error.BadAction;
}

fn parseClick(tokens: *std.mem.TokenIterator(u8, .any)) ParseError!Action {
    const target_tok = tokens.next() orelse return error.BadCoordinates;
    if (std.mem.eql(u8, target_tok, "bar:run")) {
        return .{ .click = .{ .named = .bar_run } };
    }
    if (std.mem.eql(u8, target_tok, "bar:pause")) {
        return .{ .click = .{ .named = .bar_pause } };
    }
    if (std.mem.eql(u8, target_tok, "bar:step")) {
        return .{ .click = .{ .named = .bar_step } };
    }
    if (std.mem.eql(u8, target_tok, "bar:speed")) {
        return .{ .click = .{ .named = .bar_speed } };
    }
    if (std.mem.eql(u8, target_tok, "camera:allow_once")) {
        return .{ .click = .{ .named = .camera_allow_once } };
    }
    if (std.mem.eql(u8, target_tok, "camera:always")) {
        return .{ .click = .{ .named = .camera_always } };
    }
    if (std.mem.eql(u8, target_tok, "camera:cam")) {
        return .{ .click = .{ .named = .camera_cam } };
    }
    if (std.mem.eql(u8, target_tok, "camera:grd")) {
        return .{ .click = .{ .named = .camera_grd } };
    }
    if (std.mem.eql(u8, target_tok, "board:sw1")) {
        return .{ .click = .{ .named = .board_sw1 } };
    }
    if (std.mem.eql(u8, target_tok, "board:sw2")) {
        return .{ .click = .{ .named = .board_sw2 } };
    }
    if (std.mem.eql(u8, target_tok, "board:touch")) {
        const x_tok = tokens.next() orelse return error.BadCoordinates;
        const y_tok = tokens.next() orelse return error.BadCoordinates;
        const x = std.fmt.parseInt(u16, x_tok, 10) catch return error.BadCoordinates;
        const y = std.fmt.parseInt(u16, y_tok, 10) catch return error.BadCoordinates;
        return .{ .click = .{ .touch = .{ .x = x, .y = y } } };
    }
    if (std.mem.indexOfScalar(u8, target_tok, ':') != null) {
        return error.BadTarget;
    }

    const x = std.fmt.parseInt(i32, target_tok, 10) catch return error.BadTarget;
    const y_tok = tokens.next() orelse return error.BadCoordinates;
    const y = std.fmt.parseInt(i32, y_tok, 10) catch return error.BadCoordinates;
    return .{ .click = .{ .coord = .{ .x = x, .y = y } } };
}

fn parseDrag(tokens: *std.mem.TokenIterator(u8, .any)) ParseError!Action {
    const fx_tok = tokens.next() orelse return error.BadCoordinates;
    const fy_tok = tokens.next() orelse return error.BadCoordinates;
    const tx_tok = tokens.next() orelse return error.BadCoordinates;
    const ty_tok = tokens.next() orelse return error.BadCoordinates;
    const dur_tok = tokens.next() orelse return error.BadTiming;

    const from_x = std.fmt.parseInt(i32, fx_tok, 10) catch return error.BadCoordinates;
    const from_y = std.fmt.parseInt(i32, fy_tok, 10) catch return error.BadCoordinates;
    const to_x = std.fmt.parseInt(i32, tx_tok, 10) catch return error.BadCoordinates;
    const to_y = std.fmt.parseInt(i32, ty_tok, 10) catch return error.BadCoordinates;

    const dur_clean = if (std.mem.endsWith(u8, dur_tok, "ms")) dur_tok[0 .. dur_tok.len - 2] else dur_tok;
    const duration_ms = std.fmt.parseInt(u32, dur_clean, 10) catch return error.BadTiming;

    return .{ .drag = .{
        .from_x = from_x,
        .from_y = from_y,
        .to_x = to_x,
        .to_y = to_y,
        .duration_ms = duration_ms,
    } };
}

fn parseType(allocator: std.mem.Allocator, line: []const u8) ParseError!Action {
    const quote_start = std.mem.indexOfScalar(u8, line, '"') orelse return error.InvalidSyntax;
    const quote_end = std.mem.lastIndexOfScalar(u8, line, '"') orelse return error.InvalidSyntax;
    if (quote_end <= quote_start) return error.InvalidSyntax;
    const raw_text = line[quote_start + 1 .. quote_end];
    const duped = allocator.dupe(u8, raw_text) catch return error.OutOfMemory;
    return .{ .type_text = duped };
}

fn parseKey(tokens: *std.mem.TokenIterator(u8, .any)) ParseError!Action {
    const key_tok = tokens.next() orelse return error.BadTarget;
    if (std.ascii.eqlIgnoreCase(key_tok, "Return") or std.ascii.eqlIgnoreCase(key_tok, "Enter")) {
        return .{ .key = .{ .code = 0x0D } };
    }
    if (std.ascii.eqlIgnoreCase(key_tok, "Escape") or std.ascii.eqlIgnoreCase(key_tok, "Esc")) {
        return .{ .key = .{ .code = 0x1B } };
    }
    if (std.ascii.eqlIgnoreCase(key_tok, "Space")) {
        return .{ .key = .{ .code = 0x20 } };
    }
    if (std.ascii.eqlIgnoreCase(key_tok, "Tab")) {
        return .{ .key = .{ .code = 0x09 } };
    }
    if (std.ascii.eqlIgnoreCase(key_tok, "Backspace")) {
        return .{ .key = .{ .code = 0x08 } };
    }
    if (key_tok.len == 1) {
        return .{ .key = .{ .code = key_tok[0] } };
    }
    return error.BadTarget;
}
