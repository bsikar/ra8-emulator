//! RA4T1 on-chip peripheral composition and board wiring helpers
//! (`R7FA4T1BB3CFM` / `FPB-RA4T1`, R01UH0999EJ0140 Rev.1.40; RA8EMU-A-71).
const chip = @import("../../../root.zig");

const Guest = chip.core.cpu.memory.guest.Guest;
const registry = chip.periph.registry;

pub const fcache = @import("fcache.zig");
pub const flash_ctrl = @import("flash_ctrl.zig");
pub const icu = @import("icu.zig");
pub const machine = @import("machine.zig").machine;
pub const mstp = @import("mstp.zig");
pub const port = @import("port.zig");
pub const pscu = @import("pscu.zig");
pub const sci = @import("sci.zig");
pub const snapshot = @import("snapshot.zig");
pub const sysc = @import("sysc.zig");
pub const timers = @import("timers.zig");

pub const part_number_text = "R7FA4T1BB3CFM   ";

pub const rom_addr = struct {
    pub const code_flash: u32 = 0x0000_0000;
    pub const code_flash_size: u32 = 256 * 1024;
    pub const factory_flash: u32 = 0x0100_80F0;
    pub const factory_flash_size: u32 = 0xC4;
    pub const uidr0: u32 = 0x0100_8190;
    pub const mcuver: u32 = 0x0100_81B0;
    pub const option_memory: u32 = 0x0100_A100;
    pub const option_memory_size: u32 = 0x200;
    pub const data_flash: u32 = 0x0800_0000;
    pub const data_flash_size: u32 = 4 * 1024;
};

pub const State = struct {
    sysc: sysc.Sysc = .{},
    fcache: fcache.Fcache = .{},
    pscu: pscu.Pscu = .{},
    mstp: mstp.Mstp = .{},
    port: port.Port = .{},
    sci: sci.Sci = .{},
    icu: icu.Icu = .{},
    timers: timers.Timers = .{},
    flash_ctrl: flash_ctrl.FlashCtrl = .{},

    /// Bind internal guard pointers (`PRCR.PRC4`) to the live address of `self`.
    pub fn bindSelf(self: *State) void {
        self.pscu.protection = &self.sysc;
        self.fcache.protection = &self.sysc;
        self.port.protection = &self.sysc;
    }

    pub fn bindIrq(self: *State) void {
        self.sci.irq_sink = .{
            .context = self,
            .raiseFn = sciEventThunk,
        };
    }

    fn sciEventThunk(ctx: *anyopaque, event_no: u16) void {
        const self: *State = @ptrCast(@alignCast(ctx));
        self.timers.due.push(event_no);
    }

    pub fn attachToBus(self: *State, bus: *registry.Bus) !void {
        self.bindSelf();
        self.bindIrq();
        bus.gate = self.mstp.gate();
        try bus.add(self.mstp.block());
        try bus.add(self.sysc.block());
        try bus.add(self.fcache.block());
        try bus.add(self.pscu.block());
        try bus.add(self.port.portBlock());
        try bus.add(self.port.pfsBlock());
        try bus.add(self.sci.block0());
        try bus.add(self.sci.block9());
        try bus.add(self.icu.block());
        try bus.add(self.timers.gptBlock());
        try bus.add(self.timers.agtBlock());
        try bus.add(self.flash_ctrl.cmdBlock());
        try bus.add(self.flash_ctrl.regBlock());
        try bus.add(self.flash_ctrl.sramBlock());
    }
};

/// Populate erased flash defaults (`0xFF`), Option-Setting Memory (`0xFF`),
/// and read-only Factory Flash (`PNR0..3` `"R7FA4T1BB3CFM   "`, `UIDR`, `MCUVER`).
pub fn seedRom(memory: Guest) !void {
    try fillErased(memory, rom_addr.code_flash, rom_addr.code_flash_size);
    try fillErased(memory, rom_addr.data_flash, rom_addr.data_flash_size);
    try fillErased(memory, rom_addr.option_memory, rom_addr.option_memory_size);
    try fillErased(memory, rom_addr.factory_flash, rom_addr.factory_flash_size);
    try memory.program(rom_addr.factory_flash, part_number_text);
    try memory.program(rom_addr.uidr0, "RA4T1-EMU-000001");
    try memory.program(rom_addr.mcuver, &.{0x01});
}

fn fillErased(memory: Guest, base: u32, size: u32) !void {
    const ff: [4096]u8 = @splat(0xFF);
    var offset: u32 = 0;
    while (offset < size) {
        const chunk = @min(size - offset, ff.len);
        try memory.program(base + offset, ff[0..chunk]);
        offset += chunk;
    }
}
