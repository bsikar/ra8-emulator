//! Versioned board composition files: fitted devices, external memory and
//! front-panel parts (RA8EMU-1151).
const std = @import("std");
const request = @import("ra8_components").request;
const external = @import("external/memory.zig");
const panels = @import("panels.zig");
const chip_gpio = @import("ra8_chip").periph.gpio;
const board_switches = @import("switches.zig");

pub const max_fits: usize = 4;
pub const max_leds: usize = 8;
pub const max_switches: usize = 8;

/// The shipped EK-RA8D2 profile, the board a run gets when it names none.
pub const ek_ra8d2 = @embedFile("ek_ra8d2.board");

pub const Led = struct {
    port: u8,
    pin: u4,
    rgb565: u16,
    label: []const u8,
};

pub const Switch = struct {
    port: u8,
    pin: u4,
    label: []const u8,
};

pub const Profile = struct {
    fits: [max_fits]request.Request = undefined,
    count: usize = 0,
    memory: external.Config = .{},
    leds: [max_leds]Led = undefined,
    led_count: usize = 0,
    switches: [max_switches]Switch = undefined,
    switch_count: usize = 0,
    panel: ?panels.Panel = null,

    /// The LED entry for the chip's LED at `port`.`pin`, or null (RA8EMU-1151).
    pub fn ledAt(self: Profile, port: u8, pin: u4) ?Led {
        for (self.leds[0..self.led_count]) |led| if (led.port == port and led.pin == pin) return led;
        return null;
    }

    /// The switch entry for `port`.`pin`, or null (RA8EMU-1151).
    pub fn switchAt(self: Profile, port: u8, pin: u4) ?Switch {
        for (self.switches[0..self.switch_count]) |one| if (one.port == port and one.pin == pin) return one;
        return null;
    }
};

const Where = struct { port: u8, pin: u4 };

pub const Error = error{
    BadVersion,
    BadEntry,
    TooManyFits,
    BadMemory,
    DuplicateMemory,
    BadLed,
    BadSwitch,
    BadPanel,
    UntrackedLed,
    UntrackedSwitch,
    TooManyLeds,
    TooManySwitches,
} || request.Error || external.Error;

/// Read the stable version-1 profile. Memory and front-panel keys are
/// optional so existing profiles retain the generous defaults; unknown and
/// duplicate keys fail closed rather than silently selecting a different
/// board.
pub fn parse(text: []const u8) Error!Profile {
    var result: Profile = .{};
    var has_version = false;
    var has_ospi = false;
    var has_sdram = false;
    var has_window = false;
    var has_panel = false;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "version=")) {
            if (has_version or !std.mem.eql(u8, line["version=".len..], "1")) return Error.BadVersion;
            has_version = true;
        } else if (std.mem.startsWith(u8, line, "ospi=")) {
            if (has_ospi) return Error.DuplicateMemory;
            result.memory.ospi = try parseRegion(line["ospi=".len..]);
            has_ospi = true;
        } else if (std.mem.startsWith(u8, line, "sdram=")) {
            if (has_sdram) return Error.DuplicateMemory;
            result.memory.sdram = try parseRegion(line["sdram=".len..]);
            has_sdram = true;
        } else if (std.mem.startsWith(u8, line, "memory_window_cycles=")) {
            if (has_window) return Error.DuplicateMemory;
            result.memory.window_cycles = std.fmt.parseInt(u32, line["memory_window_cycles=".len..], 10) catch return Error.BadMemory;
            has_window = true;
        } else if (std.mem.startsWith(u8, line, "led=")) {
            try addLed(&result, line["led=".len..]);
        } else if (std.mem.startsWith(u8, line, "switch=")) {
            try addSwitch(&result, line["switch=".len..]);
        } else if (std.mem.startsWith(u8, line, "panel=")) {
            if (has_panel) return Error.BadPanel;
            has_panel = true;
            const stem = line["panel=".len..];
            if (!std.mem.eql(u8, stem, "none")) result.panel = panels.byName(stem) orelse return Error.BadPanel;
        } else if (std.mem.startsWith(u8, line, "sensor=")) {
            try addFit(&result, line["sensor=".len..]);
        } else if (std.mem.startsWith(u8, line, "companion=")) {
            try addFit(&result, line["companion=".len..]);
        } else return Error.BadEntry;
    }
    if (!has_version) return Error.BadVersion;
    try result.memory.validate();
    return result;
}

fn addFit(profile: *Profile, entry: []const u8) Error!void {
    if (profile.count == profile.fits.len) return Error.TooManyFits;
    profile.fits[profile.count] = try request.parse(entry);
    profile.count += 1;
}

/// `P600,0x001F,LED1 BLUE`: a chip-tracked LED pad, its colour and label.
fn addLed(profile: *Profile, entry: []const u8) Error!void {
    var fields = std.mem.splitScalar(u8, entry, ',');
    const where = parsePin(nextField(&fields)) catch return Error.BadLed;
    const rgb565 = std.fmt.parseInt(u16, nextField(&fields), 0) catch return Error.BadLed;
    const label = std.mem.trim(u8, nextField(&fields), " \t");
    if (label.len == 0 or fields.next() != null) return Error.BadLed;
    try checkedAdd(profile.leds[0..], &profile.led_count, max_leds, Error.TooManyLeds, where, Error.BadLed, isTrackedLed(where), Error.UntrackedLed);
    profile.leds[profile.led_count - 1] = .{ .port = where.port, .pin = where.pin, .rgb565 = rgb565, .label = label };
}

/// `P009,SW1`: a chip-tracked switch pad and its label.
fn addSwitch(profile: *Profile, entry: []const u8) Error!void {
    var fields = std.mem.splitScalar(u8, entry, ',');
    const where = parsePin(nextField(&fields)) catch return Error.BadSwitch;
    const label = std.mem.trim(u8, nextField(&fields), " \t");
    if (label.len == 0 or fields.next() != null) return Error.BadSwitch;
    try checkedAdd(profile.switches[0..], &profile.switch_count, max_switches, Error.TooManySwitches, where, Error.BadSwitch, isTrackedSwitch(where), Error.UntrackedSwitch);
    profile.switches[profile.switch_count - 1] = .{ .port = where.port, .pin = where.pin, .label = label };
}

fn nextField(fields: *std.mem.SplitIterator(u8, .scalar)) []const u8 {
    return fields.next() orelse "";
}

fn checkedAdd(
    slots: anytype,
    count: *usize,
    cap: usize,
    too_many: Error,
    where: Where,
    duplicate: Error,
    tracked: bool,
    untracked: Error,
) Error!void {
    for (slots[0..count.*]) |one| {
        if (one.port == where.port and one.pin == where.pin) return duplicate;
    }
    if (count.* == cap) return too_many;
    if (!tracked) return untracked;
    count.* += 1;
}

/// A pad name: `P600` is port 6 pin 0, `PA07` is port 10 pin 7.
fn parsePin(text: []const u8) error{BadPin}!Where {
    if (text.len != 4 or text[0] != 'P') return error.BadPin;
    const port: u8 = switch (text[1]) {
        '0'...'9' => text[1] - '0',
        'A'...'F' => text[1] - 'A' + 10,
        else => return error.BadPin,
    };
    const pin = std.fmt.parseInt(u4, text[2..4], 16) catch return error.BadPin;
    return .{ .port = port, .pin = pin };
}

fn isTrackedLed(where: Where) bool {
    for (chip_gpio.leds) |led| {
        if (led.port == where.port and led.pin == where.pin) return true;
    }
    return false;
}

fn isTrackedSwitch(where: Where) bool {
    for (board_switches.user) |one| {
        if (one.port == where.port and one.pin == where.pin) return true;
    }
    return false;
}

fn parseRegion(text: []const u8) Error!external.RegionConfig {
    const names = [_][]const u8{ "size:", "width:", "clock_hz:", "latency_cycles:", "burst:" };
    var values: [names.len][]const u8 = undefined;
    var fields = std.mem.splitScalar(u8, text, ',');
    for (names, 0..) |name, index| {
        const field = fields.next() orelse return Error.BadMemory;
        if (!std.mem.startsWith(u8, field, name) or field.len == name.len) return Error.BadMemory;
        values[index] = field[name.len..];
    }
    if (fields.next() != null) return Error.BadMemory;
    return .{
        .size = std.fmt.parseInt(u32, values[0], 10) catch return Error.BadMemory,
        .width = std.fmt.parseInt(u8, values[1], 10) catch return Error.BadMemory,
        .clock_hz = std.fmt.parseInt(u32, values[2], 10) catch return Error.BadMemory,
        .latency_cycles = std.fmt.parseInt(u8, values[3], 10) catch return Error.BadMemory,
        .burst = external.Burst.parse(values[4]) orelse return Error.BadMemory,
    };
}
