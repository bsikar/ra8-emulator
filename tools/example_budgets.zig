//! Per-image instruction budgets for the example table (RA8EMU-71).
//!
//! The table runs every image at one budget, the emulator's default unless
//! the caller names another. Most examples print their verdict long before
//! that. A few do real work first: ra8_io_swap_demo programs and reads back
//! the octal flash through a few thousand XSPI commands and only reaches its
//! "two-backend swap (ram + xs) PASS" line at around 12M instructions, so at
//! the default it reads "budget" with the swap still running. threadx_cpu1
//! waits on ten ThreadX ticks on CPU1, which CPU1's share of 2M never reaches.
//!
//! An override here is a floor, not a replacement: an image runs at the
//! larger of its own budget and the caller's, so asking the whole table for
//! more never gives a listed image less.
const std = @import("std");

pub const Override = struct {
    image: []const u8,
    instructions: []const u8,
};

/// Images that need more than the default to reach their verdict, and the
/// budget each was seen to finish inside.
pub const overrides = [_]Override{
    .{ .image = "ra8_io_swap_demo.elf", .instructions = "20000000" },
    // CPU1's ThreadX kernel needs 10 SysTick ticks (about 2.5M CPU1 cycles at
    // 250 MHz) before the M85 prints "10 ticks PASS" (RA8EMU-40).
    .{ .image = "threadx_cpu1.elf", .instructions = "40000000" },
    // The module on CPU1 has to run ten times, each a tx_thread_sleep(1),
    // before the M85 prints "module ran 10 times PASS" (RA8EMU-302).
    .{ .image = "txm_manager_cpu1.elf", .instructions = "60000000" },
    // The fault, the kill and ten manager ticks after it (RA8EMU-313).
    .{ .image = "txm_fault_cpu1.elf", .instructions = "60000000" },
    // The SD examples provision, mount and read back a FAT card (RA8EMU-82).
    // Each budget is the first doubling from 5M seen to reach the PASS line on
    // both backends; epub_toc needs 80M on --cpu zig (RA8EMU-123).
    .{ .image = "epub_open.elf", .instructions = "20000000" },
    .{ .image = "epub_toc.elf", .instructions = "80000000" },
    .{ .image = "ra8_io_sd_demo.elf", .instructions = "10000000" },
    .{ .image = "tz_secure_only_sd.elf", .instructions = "20000000" },
    // RSA/ECC signature checks in software mbedtls bignum code (RA8EMU-285);
    // PASS seen at 200M on both backends, not at 100M.
    .{ .image = "rot_verify_hil.elf", .instructions = "200000000" },
};

pub fn find(image: []const u8) ?Override {
    for (overrides) |entry| {
        if (std.mem.eql(u8, entry.image, image)) return entry;
    }
    return null;
}

/// The budget to run `image` at, given the caller's (null means the
/// emulator's default). A caller budget that does not parse is passed
/// through untouched for the emulator to reject.
pub fn pick(image: []const u8, default: ?[]const u8) ?[]const u8 {
    const own = find(image) orelse return default;
    const given = default orelse return own.instructions;
    const asked = std.fmt.parseInt(u64, given, 0) catch return given;
    const floor = std.fmt.parseInt(u64, own.instructions, 10) catch return given;
    return if (floor > asked) own.instructions else given;
}
