//! Attach-time block-to-section mapping and micro-checkpoint capture/restore (Section 2.4).
//!
//! Maps peripheral address windows to snapshot sections. When a slot touches
//! peripheral MMIO, PPB/SCS, or Fabric state, only the touched sections are
//! serialized into a micro-checkpoint. Undo restores pre-state sections. Redo
//! restores pre-state, re-executes the slot, and verifies the Blake3 post-digest.
//!
//! Tracking is zero-cost and allocation-free when the window is disarmed.
const std = @import("std");
const Allocator = std.mem.Allocator;
const board_snap = @import("ra8_board").snapshot.run;
const file = board_snap.file;
const chip = @import("ra8_chip");
const registry = chip.periph.registry;
const memmap = chip.core.memmap;
const board_bus = chip.core.cpu.board_bus;

pub const TouchedHook = board_bus.TouchedHook;

pub const BlockSectionEntry = struct {
    base: u32,
    size: u32,
    section: file.Kind,
};

pub const max_entries: usize = 192;

pub const BlockSectionTable = struct {
    entries: [max_entries]BlockSectionEntry = undefined,
    count: usize = 0,

    pub fn register(self: *BlockSectionTable, base: u32, size: u32, section: file.Kind) !void {
        if (self.count >= max_entries) return error.TableFull;
        self.entries[self.count] = .{ .base = base, .size = size, .section = section };
        self.count += 1;
    }

    pub fn buildFromBus(self: *BlockSectionTable, bus: *const registry.Bus) void {
        for (bus.blocks[0..bus.count]) |block| {
            const kind = sectionForBlockName(block.name);
            self.register(block.base, block.size, kind) catch return;
        }
    }

    pub fn lookup(self: *const BlockSectionTable, address: u32) file.Kind {
        const canonical = registry.canonicalize(address);
        for (self.entries[0..self.count]) |entry| {
            if (canonical >= entry.base and canonical < @as(u64, entry.base) + entry.size) {
                return entry.section;
            }
        }
        if (board_bus.BoardBus.inWindow(address, 1)) return .registry;
        if (address >= memmap.ppb_base and address < memmap.ppb_base + 0x0010_0000) {
            return classifyPpb(address);
        }
        return .memory;
    }
};

pub fn classifyPpb(address: u32) file.Kind {
    if ((address >= 0xE000_E010 and address <= 0xE000_E01F) or
        (address >= 0xE002_E010 and address <= 0xE002_E01F))
    {
        return .systick;
    }
    if ((address >= 0xE000_ED90 and address <= 0xE000_EDC7) or
        (address >= 0xE000_EDD0 and address <= 0xE000_EDE0) or
        (address >= 0xE000_ED28 and address <= 0xE000_ED2F) or
        address == 0xE000_EDE4)
    {
        return .security;
    }
    if (address == 0xE000_ED88 or (address >= 0xE000_EF34 and address <= 0xE000_EF3C)) {
        return .cpu;
    }
    return .debug_units;
}

pub fn sectionForBlockName(name: []const u8) file.Kind {
    if (containsAny(name, &.{ "AGT", "RTC", "ULPT", "WDT", "IWDT", "PTP", "PWM", "GPT" })) return .timers;
    if (containsAny(name, &.{ "SCI", "UART" })) return .serial;
    if (containsAny(name, &.{ "SDHI", "SD" })) return .sd;
    if (containsAny(name, &.{ "RIIC", "I3C" })) return .wire;
    if (containsAny(name, &.{ "DRW", "RASTER" })) return .raster;
    if (containsAny(name, &.{ "GLCDC", "DISPLAY" })) return .display;
    if (containsAny(name, &.{ "EINK", "PANEL" })) return .panel;
    if (containsAny(name, &.{ "SYSC", "SOSC", "LOCO", "CKCR", "CKDIV", "PLL", "MOSC", "VSCR", "LPM", "DPS", "PDCTR" })) return .clocks;
    if (containsAny(name, &.{ "CPSCU", "PSCU", "IDAU", "SAU", "MPU" })) return .security;
    if (containsAny(name, &.{ "MSTP", "CPU_CTRL", "SDRAM", "MRMS", "GTCLKCR" })) return .controllers;
    if (containsAny(name, &.{ "XSPI", "FLASH", "OCTA", "OPTIONS" })) return .storage;
    if (containsAny(name, &.{ "PFS", "GPIO", "CRC", "DOC", "CAC", "ACMP", "POEG", "VBATT", "MONITOR", "CAUSE" })) return .signals;
    if (containsAny(name, &.{ "DMAC", "DMA", "DTC", "ELC", "ICU" })) return .datapath;
    if (containsAny(name, &.{ "CEU", "SSIE", "AUDIO", "PDM" })) return .media;
    if (containsAny(name, &.{ "SPI", "CAN", "MAILBOX", "ECC" })) return .wired;
    if (containsAny(name, &.{ "ADC", "DAC" })) return .channels;
    if (containsAny(name, &.{ "USBFS", "USBHS", "USB" })) return .usb;
    if (containsAny(name, &.{ "ETHA", "RMAC", "GWCA", "COMA", "RSWITCH", "GWARIRM", "ETH" })) return .rswitch;
    if (containsAny(name, &.{ "NPU", "ETHOS" })) return .npu;
    if (containsAny(name, &.{ "C6", "ESP" })) return .c6;
    return .registry;
}

fn containsAny(text: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.mem.indexOf(u8, text, n) != null) return true;
    }
    return false;
}

pub const TouchedTracker = struct {
    armed: bool = false,
    touched_mask: u64 = 0,
    table: *const BlockSectionTable,

    pub fn init(table: *const BlockSectionTable) TouchedTracker {
        return .{ .table = table };
    }

    pub fn arm(self: *TouchedTracker) void {
        self.armed = true;
        self.touched_mask = 0;
    }

    pub fn disarm(self: *TouchedTracker) void {
        self.armed = false;
    }

    pub fn clear(self: *TouchedTracker) void {
        self.touched_mask = 0;
    }

    pub fn touch(self: *TouchedTracker, kind: file.Kind) void {
        if (!self.armed) return;
        const k: u32 = @backingInt(kind);
        if (k < 64) {
            self.touched_mask |= (@as(u64, 1) << @intCast(k));
        }
    }

    pub fn isTouched(self: *const TouchedTracker, kind: file.Kind) bool {
        const k: u32 = @backingInt(kind);
        if (k >= 64) return false;
        return (self.touched_mask & (@as(u64, 1) << @intCast(k))) != 0;
    }

    pub fn hasTouched(self: *const TouchedTracker) bool {
        return self.touched_mask != 0;
    }

    pub fn touchedCount(self: *const TouchedTracker) usize {
        return @popCount(self.touched_mask);
    }

    fn onTouch(ctx: *anyopaque, address: u32, is_write: bool) void {
        _ = is_write;
        const self: *TouchedTracker = @ptrCast(@alignCast(ctx));
        if (!self.armed) return;
        const kind = self.table.lookup(address);
        self.touch(kind);
    }

    pub fn hook(self: *TouchedTracker) TouchedHook {
        return .{
            .context = self,
            .touchFn = onTouch,
        };
    }
};

pub const MicroCheckpoint = struct {
    bytes: []u8,
    touched_mask: u64,

    pub fn deinit(self: *MicroCheckpoint, allocator: Allocator) void {
        if (self.bytes.len > 0) allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn capture(
        allocator: Allocator,
        board: anytype,
        tracker: *const TouchedTracker,
    ) !MicroCheckpoint {
        if (!tracker.hasTouched()) {
            return .{ .bytes = &.{}, .touched_mask = 0 };
        }
        var stream: std.Io.Writer.Allocating = .init(allocator);
        defer stream.deinit();
        try file.writeHeader(&stream.writer);

        var bit: u7 = 1;
        while (bit < 64) : (bit += 1) {
            if ((tracker.touched_mask & (@as(u64, 1) << @intCast(bit))) != 0) {
                const kind: file.Kind = @fromBackingInt(@intCast(bit));
                try saveBoardSection(board, kind, &stream.writer);
            }
        }
        return .{
            .bytes = try allocator.dupe(u8, stream.written()),
            .touched_mask = tracker.touched_mask,
        };
    }

    pub fn restore(self: *const MicroCheckpoint, board: anytype) !void {
        if (self.bytes.len == 0) return;
        var reader = try file.Reader.open(self.bytes);
        while (try reader.next()) |section| {
            try loadBoardSection(board, section.kind, self.bytes);
        }
    }
};

pub fn saveBoardSection(board: anytype, kind: file.Kind, writer: anytype) !void {
    const B = @TypeOf(board.*);
    if (@hasDecl(B, "saveSection")) {
        return board.saveSection(kind, writer);
    }
    switch (kind) {
        .registry => if (@hasField(B, "bus")) {
            var counter: std.Io.Writer.Discarding = .init(&.{});
            try board.bus.saveSnapshot(&counter.writer);
            try file.writeSectionHeader(writer, .registry, counter.fullCount());
            try board.bus.saveSnapshot(writer);
        },
        .timers => if (@hasField(B, "clock")) {
            try @import("ra8_chip").snapshot.timers.save(board, writer);
        },
        .serial => if (@hasField(B, "serial")) {
            try @import("ra8_chip").periph.sci.snapshot.save(board, writer);
        },
        .sd => if (@hasField(B, "sd")) {
            try @import("ra8_board").snapshot.sd.save(board, writer);
        },
        .wire => if (@hasField(B, "wire")) {
            try @import("ra8_board").snapshot.wire.save(board, writer);
        },
        .raster => if (@hasField(B, "raster")) {
            try @import("ra8_chip").periph.drw.snapshot.save(board, writer);
        },
        .display => if (@hasField(B, "display")) {
            try @import("ra8_chip").periph.glcdc.snapshot.save(board, writer);
        },
        .panel => if (@hasField(B, "panel")) {
            try @import("ra8_components").eink.snapshot.save(board, writer);
        },
        .clocks => if (@hasField(B, "branches")) {
            try @import("ra8_chip").snapshot.clocks.save(board, writer);
        },
        .security => if (@hasField(B, "attribution")) {
            try @import("ra8_chip").snapshot.security.save(board, writer);
        },
        .controllers => if (@hasField(B, "modules")) {
            try @import("ra8_chip").snapshot.controllers.save(board, writer);
        },
        .storage => if (@hasField(B, "flash")) {
            try @import("ra8_board").snapshot.storage.save(board, writer);
        },
        .signals => if (@hasField(B, "pins")) {
            try @import("ra8_chip").snapshot.signals.save(board, writer);
        },
        .datapath => if (@hasField(B, "events")) {
            try @import("ra8_chip").snapshot.datapath.save(board, writer);
        },
        .media => if (@hasField(B, "capture")) {
            try @import("ra8_chip").snapshot.media.save(board, writer);
        },
        .wired => if (@hasField(B, "spi")) {
            try @import("ra8_board").snapshot.wired.save(board, writer);
        },
        .channels => if (@hasField(B, "analog")) {
            try @import("ra8_chip").snapshot.channels.save(board, writer);
        },
        .usb => if (@hasField(B, "usb")) {
            try @import("ra8_board").snapshot.usb.save(board, writer);
        },
        .rswitch => if (@hasField(B, "rswitch")) {
            try @import("ra8_board").snapshot.rswitch.save(board, writer);
        },
        .npu => if (@hasField(B, "npu")) {
            try @import("ra8_chip").periph.npu.snapshot.save(board, writer);
        },
        .c6 => if (@hasField(B, "c6")) {
            try @import("ra8_components").esp_hosted.snapshot.save(board, writer);
        },
        else => {},
    }
}

pub fn loadBoardSection(board: anytype, kind: file.Kind, bytes: []const u8) !void {
    const B = @TypeOf(board.*);
    if (@hasDecl(B, "loadSection")) {
        return board.loadSection(kind, bytes);
    }
    switch (kind) {
        .registry => if (@hasField(B, "bus")) {
            const sec = try file.Reader.find(bytes, .registry) orelse return error.Missing;
            try board.bus.loadSnapshot(sec.payload);
        },
        .timers => if (@hasField(B, "clock")) {
            try @import("ra8_chip").snapshot.timers.load(board, bytes);
        },
        .serial => if (@hasField(B, "serial")) {
            try @import("ra8_chip").periph.sci.snapshot.load(board, bytes);
        },
        .sd => if (@hasField(B, "sd")) {
            try @import("ra8_board").snapshot.sd.load(board, bytes);
        },
        .wire => if (@hasField(B, "wire")) {
            try @import("ra8_board").snapshot.wire.load(board, bytes);
        },
        .raster => if (@hasField(B, "raster")) {
            try @import("ra8_chip").periph.drw.snapshot.load(board, bytes);
        },
        .display => if (@hasField(B, "display")) {
            try @import("ra8_chip").periph.glcdc.snapshot.load(board, bytes);
        },
        .panel => if (@hasField(B, "panel")) {
            try @import("ra8_components").eink.snapshot.load(board, bytes);
        },
        .clocks => if (@hasField(B, "branches")) {
            try @import("ra8_chip").snapshot.clocks.load(board, bytes);
        },
        .security => if (@hasField(B, "attribution")) {
            try @import("ra8_chip").snapshot.security.load(board, bytes);
        },
        .controllers => if (@hasField(B, "modules")) {
            try @import("ra8_chip").snapshot.controllers.load(board, bytes);
        },
        .storage => if (@hasField(B, "flash")) {
            try @import("ra8_board").snapshot.storage.load(board, bytes);
        },
        .signals => if (@hasField(B, "pins")) {
            try @import("ra8_chip").snapshot.signals.load(board, bytes);
        },
        .datapath => if (@hasField(B, "events")) {
            try @import("ra8_chip").snapshot.datapath.load(board, bytes);
        },
        .media => if (@hasField(B, "capture")) {
            try @import("ra8_chip").snapshot.media.load(board, bytes);
        },
        .wired => if (@hasField(B, "spi")) {
            try @import("ra8_board").snapshot.wired.load(board, bytes);
        },
        .channels => if (@hasField(B, "analog")) {
            try @import("ra8_chip").snapshot.channels.load(board, bytes);
        },
        .usb => if (@hasField(B, "usb")) {
            try @import("ra8_board").snapshot.usb.load(board, bytes);
        },
        .rswitch => if (@hasField(B, "rswitch")) {
            try @import("ra8_board").snapshot.rswitch.load(board, bytes);
        },
        .npu => if (@hasField(B, "npu")) {
            try @import("ra8_chip").periph.npu.snapshot.load(board, bytes);
        },
        .c6 => if (@hasField(B, "c6")) {
            try @import("ra8_components").esp_hosted.snapshot.load(board, bytes);
        },
        else => {},
    }
}
