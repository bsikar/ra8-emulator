//! Direct non-circular inspection of all Board peripheral blocks, sparse MMIO
//! registry cells, virtual-time event queue, USB MSC cursors, and input queues
//! without production snapshot codecs.
const std = @import("std");
const ra8 = @import("ra8");
const hash = @import("common_hash.zig");

const Digest = hash.Digest;
const Hasher = hash.Hasher;
const Board = ra8.board.board.Board;

pub const board_included = .{
    "bus",             "modules",     "attribution",          "gpt_clock",      "time",       "events",           "links",
    "transfers",       "transfers1",  "transfer_attribution", "dma",            "dma_module", "pins",             "pinfunc",
    "checksum",        "dataops",     "accuracy",             "comparators",    "capture",    "analog",           "adc",
    "shutoff",         "protection",  "backup",               "battery_switch", "branches",   "chip_attribution", "sram_attribution",
    "memory_monitors", "idau",        "second_core",          "memory_rates",   "memory_ecc", "sdram",            "ratios",
    "oscillators",     "subclk",      "loco",                 "tree",           "low_power",  "standby_cancel",   "plls",
    "voltage",         "brownout",    "domains",              "display",        "raster",     "serial",           "c6",
    "console_input",   "touch_input", "input_script",         "wire",           "rswitch",    "usb",              "spi",
    "panel",           "modem",       "trace",                "sd",             "options",    "flash",            "nor",
    "octa",            "cipher",      "card",                 "host_card",      "ecc",        "audio",            "microphone",
    "clock",           "can",         "mailbox",              "npu",            "lowpower",   "interval",         "pwm",
    "pwm_delay",       "ptp",         "monitors",             "watchdog",       "heartbeat",  "link",             "receiver",
    "host",            "causes",      "control",              "clears",         "caches",     "regions",          "regions_ns",
    "guard",           "partitions",  "reboot",               "part",
};

pub const board_excluded = .{
    .{ .name = "run_hook", .reason = "Host pacing and soak callback wiring" },
    .{ .name = "external_memory", .reason = "Root fabric geometry checked in fabricDigest" },
    .{ .name = "cpu1", .reason = "Guest store handle checked in CPU1 spaces" },
    .{ .name = "asks", .reason = "Startup attachment asks checked in attachmentsDigest" },
    .{ .name = "sd_line", .reason = "Stable line wrapper pointing to board.sd" },
    .{ .name = "sd_volume", .reason = "Startup formatting report metadata" },
    .{ .name = "event_sink", .reason = "Session event publication callback" },
    .{ .name = "frame_tap", .reason = "Passive boundary frame tap pointer" },
    .{ .name = "frame_taps", .reason = "Passive boundary frame tap fan-out" },
    .{ .name = "input_landing", .reason = "History input landing observer callback" },
    .{ .name = "panel_vsync", .reason = "Root vsync config; live phase is in display.output.vsync" },
};

comptime {
    if (!hash.classified(Board, board_included, board_excluded)) {
        @compileError("COMMON board oracle missing or duplicate Board field classification");
    }
}

pub fn hashPanel(h: *Hasher, panel: *const ra8.components.eink.Panel) void {
    h.autoExcept(panel.*, .{ "planes", "refresh_hook", "refresh_log_hook", "event_hook" });
    h.autoExcept(panel.planes, .{ "allocator", "image", "glass", "obs" });
    inline for (.{ panel.planes.image, panel.planes.glass }) |plane| {
        h.int(plane.width);
        h.int(plane.height);
        h.bytes(plane.pixels);
    }
}

pub fn hashModem(h: *Hasher, modem: *const ra8.components.modem_at.Modem) void {
    var copy = modem.*;
    const clamped = @min(copy.len, copy.line.len);
    @memset(copy.line[clamped..], 0);
    h.auto(copy);
}

pub fn hashC6(h: *Hasher, part: *const ra8.components.esp_hosted.C6) void {
    var copy = part.*;
    const rx_off = @min(copy.wire.offset, copy.wire.rx.len);
    @memset(copy.wire.rx[rx_off..], 0);
    if (copy.wire.offset == 0) @memset(&copy.wire.tx, 0);
    const slot_count = copy.wire.queue.slots.len;
    const head = copy.wire.queue.head % slot_count;
    for (&copy.wire.queue.slots, 0..) |*slot, idx| {
        const dist = (idx + slot_count - head) % slot_count;
        if (dist >= copy.wire.queue.len) @memset(slot, 0);
    }
    h.autoExcept(copy, .{ "pins", "wire.bridge" });
}

fn hashClocksAndSecurity(h: *Hasher, board: *const Board) void {
    inline for (.{
        "clock",       "interval",       "pwm",          "pwm_delay",        "ptp",
        "protection",  "standby_cancel", "attribution",  "sram_attribution", "memory_monitors",
        "second_core", "control",        "clears",       "caches",           "regions",
        "regions_ns",  "partitions",     "memory_rates", "memory_ecc",       "sdram",
        "cipher",      "ecc",
    }) |name| h.auto(@field(board, name));

    h.autoExcept(board.watchdog, .{"event_hook"});
    h.autoExcept(board.heartbeat, .{"event_hook"});

    h.autoExcept(board.branches, .{"protection"});
    h.autoExcept(board.ratios, .{ "protection", "branches" });
    h.autoExcept(board.oscillators, .{"protection"});
    h.autoExcept(board.subclk, .{"protection"});
    h.autoExcept(board.loco, .{"protection"});
    h.autoExcept(board.tree, .{ "protection", "oscillators", "brownout" });
    h.autoExcept(board.plls, .{ "protection", "oscillators" });
    h.autoExcept(board.voltage, .{"protection"});
    h.autoExcept(board.brownout, .{"voltage"});
    h.autoExcept(board.low_power, .{"protection"});
    h.autoExcept(board.gpt_clock, .{"modules"});
    h.autoExcept(board.octa, .{"clocks"});
    h.autoExcept(board.modules, .{ "attribution", "bus", "octa", "last_gated", "dropped" });
    h.autoExcept(board.transfer_attribution, .{"protection"});
    h.autoExcept(board.chip_attribution, .{"protection"});
    h.autoExcept(board.idau, .{ "sram", "banks" });
    h.autoExcept(board.causes, .{"masks"});
    h.autoExcept(board.causes.masks, .{ "protection", "watchdog_armed", "heartbeat_armed" });
    h.autoExcept(board.guard, .{"unit"});
}

fn hashDatapathAndMedia(h: *Hasher, board: *const Board) void {
    inline for (.{
        "links",       "pinfunc", "checksum", "dataops",  "accuracy",
        "comparators", "analog",  "adc",      "shutoff",  "dma_module",
        "microphone",  "can",     "lowpower", "monitors", "link",
        "receiver",    "host",
    }) |name| h.auto(@field(board, name));

    h.autoExcept(board.events, .{"issuer"});
    h.autoExcept(board.transfers, .{ "twin", "issuer" });
    h.autoExcept(board.transfers1, .{ "twin", "issuer" });
    h.autoExcept(board.dma, .{ "memory", "bank" });
    h.autoExcept(board.pins, .{ "observer", "event_tap", "wired", "pull_ups" });
    h.autoExcept(board.backup, .{"protection"});
    h.autoExcept(board.battery_switch, .{"protection"});
    h.autoExcept(board.capture, .{ "memory", "source", "clock" });
    h.autoExcept(board.mailbox, .{"attrib"});
    h.autoExcept(board.mailbox.attrib, .{"protection"});
    hashModem(h, &board.modem);
    h.autoExcept(board.trace, .{"memory"});
    h.autoExcept(board.domains.graphics, .{"protection"});
    h.autoExcept(board.domains.eswm, .{"protection"});
    h.autoExcept(board.audio, .{"channels.listener"});
    h.autoExcept(board.spi, .{"channels.device"});
    h.autoExcept(board.npu, .{"memory"});
    h.autoExcept(board.raster, .{ "domain", "memory" });
    h.autoExcept(board.rswitch, .{
        "ports.domain", "ports.mdio",          "gateway.fwpc",
        "queues.mode",  "queues.rings.memory", "queues.rings.link",
    });
}

fn hashUsbStickCursor(h: *Hasher, target: *const ra8.components.usb.stick.Target, cursor: []const u8) void {
    if (cursor.len == 0) {
        h.byte(0);
        return;
    }
    const at = @intFromPtr(cursor.ptr);
    const bases = .{
        .{ @as(u8, 1), target.disk },
        .{ @as(u8, 2), @as([]const u8, &target.scratch) },
        .{ @as(u8, 3), @as([]const u8, &ra8.components.usb.stick.inquiry_data) },
    };
    inline for (bases) |entry| {
        const lo = @intFromPtr(entry[1].ptr);
        if (at >= lo and at + cursor.len <= lo + entry[1].len) {
            h.byte(entry[0]);
            h.int(@as(u32, @intCast(at - lo)));
            h.int(@as(u32, @intCast(cursor.len)));
            return;
        }
    }
    h.byte(0xff);
    h.bytes(cursor);
}

fn hashBusesDisplayAndStorage(h: *Hasher, board: *const Board) void {
    for (board.serial.channels) |ch| h.autoExcept(ch, .{"device"});
    h.autoExcept(board.serial.line, .{ "sink", "mute" });

    for (board.wire.controller.channels) |ch| {
        h.autoExcept(ch, .{"rx"});
        h.autoExcept(ch.rx, .{"clock"});
    }
    h.boolean(board.wire.controller.devices.held_low);
    h.autoExcept(board.wire.touchline, .{"devices"});
    h.boolean(board.wire.touchline.devices.held_low);
    inline for (.{ "expander", "sensor", "panel", "imu", "gauge" }) |sub| {
        h.auto(@field(board.wire, sub));
    }

    h.autoExcept(board.display, .{ "domain", "memory", "output", "event_hook" });
    h.autoExcept(board.display.output, .{ "capture", "vsync" });
    h.boolean(board.display.output.vsync != null);
    if (board.display.output.vsync) |vs| {
        h.autoExcept(vs, .{"sink"});
    }

    hashPanel(h, &board.panel);
    hashC6(h, &board.c6);

    h.autoExcept(board.sd, .{"img"});
    h.autoExcept(board.sd.img, .{ "allocator", "blocks", "obs" });
    h.autoExcept(board.card, .{"card"});
    h.autoExcept(board.host_card, .{"img"});
    h.autoExcept(board.host_card.img, .{ "allocator", "blocks", "obs" });

    h.autoExcept(board.options, .{ "otp", "memory" });
    h.autoExcept(board.flash, .{ "part", "octa" });
    h.int(board.nor.capacity);
    h.int(board.nor.live());

    h.autoExcept(board.usb, .{ "host.xfer.far", "echo.storage", "cable", "bridge", "stick" });
    h.autoExcept(board.usb.stick, .{ "disk", "data", "sink", "obs" });
    hashUsbStickCursor(h, &board.usb.stick, board.usb.stick.data);
    hashUsbStickCursor(h, &board.usb.stick, board.usb.stick.sink);
}

fn hashBusRegistryAndInputs(allocator: std.mem.Allocator, h: *Hasher, board: *const Board) !void {
    h.auto(board.bus.counters);
    h.boolean(board.bus.nonsecure);
    h.auto(board.bus.issuer);
    const keys = try allocator.alloc(u32, board.bus.cells.count());
    defer allocator.free(keys);
    var it = board.bus.cells.keyIterator();
    var idx: usize = 0;
    while (it.next()) |k| : (idx += 1) keys[idx] = k.*;
    std.mem.sort(u32, keys, {}, std.sort.asc(u32));
    h.int(@as(u32, @intCast(keys.len)));
    for (keys) |k| {
        h.int(k);
        h.auto(board.bus.cells.get(k).?);
    }

    h.autoExcept(board.input_script, .{"events"});
    const ev_len = @min(board.input_script.len, board.input_script.events.len);
    for (board.input_script.events[0..ev_len]) |ev| h.auto(ev);

    h.autoExcept(board.touch_input, .{ "source", "switches", "line" });
    const touch_len = @min(board.touch_input.len, board.touch_input.line.len);
    h.bytes(board.touch_input.line[0..touch_len]);

    h.autoExcept(board.console_input.reply, .{ "prompt", "text" });
    h.boolean(board.reboot != null);
    if (board.reboot) |reb| h.auto(reb.*);
}

pub fn peripheralsDigest(allocator: std.mem.Allocator, board: *const Board) !Digest {
    var h: Hasher = .{};
    h.auto(board.part);
    h.auto(board.time.base);
    h.int(board.time.queue.next_seq);
    const q_count = @min(board.time.queue.count, board.time.queue.items.len);
    h.int(@as(u8, @intCast(q_count)));
    for (board.time.queue.items[0..q_count]) |ev| h.auto(ev);

    hashClocksAndSecurity(&h, board);
    hashDatapathAndMedia(&h, board);
    hashBusesDisplayAndStorage(&h, board);
    try hashBusRegistryAndInputs(allocator, &h, board);
    return h.final();
}
