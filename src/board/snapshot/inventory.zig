//! Reflected ownership map for board snapshot sections and embedding wiring.
const fields = @import("ra8_snapshot").fields;
pub const saved = .{
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
pub const omitted = .{
    .{ .name = "run_hook", .reason = "Embedding pacing and soak callbacks" },
    .{ .name = "external_memory", .reason = "Root configuration; memory section validates the fabric layout" },
    .{ .name = "cpu1", .reason = "Guest handle; CPU1 bytes saved by the run owner" },
    .{ .name = "asks", .reason = "Owner-validated topology and guest objects saved by outer Files attachment graph; unowned startup APIs refuse" },
    .{ .name = "sd_line", .reason = "Stable pointer to the saved SPI SD card" },
    .{ .name = "sd_volume", .reason = "Formatting report, not mutable card contents" },
    .{ .name = "event_sink", .reason = "Embedding event callback" },
    .{ .name = "frame_tap", .reason = "Passive frame tap wiring" },
    .{ .name = "frame_taps", .reason = "Passive frame tap subscriber fan-out" },
    .{ .name = "input_landing", .reason = "Input landing observer wiring" },
    .{ .name = "panel_vsync", .reason = "Root configuration; the display's vsync section carries the clock state" },
};
pub fn complete(comptime Board: type) bool {
    return fields.complete(Board, saved, omitted);
}
