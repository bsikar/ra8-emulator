//! The emulator as one module, so the build and the tests reach every file
//! through one name instead of a relative path apiece. `zig build test`
//! imports this as "ra8"; so does src/main.zig.
pub const core = struct {
    pub const c = @import("core/c.zig");
    pub const cli = @import("core/cli.zig");
    pub const disasm = @import("core/disasm.zig");
    pub const elf = @import("core/elf.zig");
    pub const engine = @import("core/engine.zig");
    pub const lob = @import("core/lob.zig");
    pub const lob_hook = @import("core/lob_hook.zig");
    pub const memmap = @import("core/memmap.zig");
    pub const reboot = @import("core/reboot.zig");
};

pub const periph = struct {
    pub const adc = @import("periph/adc.zig");
    pub const adc_scan = @import("periph/adc_scan.zig");
    pub const agt = @import("periph/agt.zig");
    pub const bkup = @import("periph/bkup.zig");
    pub const cac = @import("periph/cac.zig");
    pub const canfd = @import("periph/canfd.zig");
    pub const canfd_fifo = @import("periph/canfd_fifo.zig");
    pub const ceu = @import("periph/ceu.zig");
    pub const clocks = @import("periph/clocks.zig");
    pub const crc = @import("periph/crc.zig");
    pub const dac = @import("periph/dac.zig");
    pub const dma_bank = @import("periph/dma_bank.zig");
    pub const dmac = @import("periph/dmac.zig");
    pub const dmac_xfer = @import("periph/dmac_xfer.zig");
    pub const doc = @import("periph/doc.zig");
    pub const drw = @import("periph/drw.zig");
    pub const drw_blend = @import("periph/drw_blend.zig");
    pub const dtc = @import("periph/dtc.zig");
    pub const dtc_xfer = @import("periph/dtc_xfer.zig");
    pub const elc = @import("periph/elc.zig");
    pub const glcdc = @import("periph/glcdc.zig");
    pub const gpio = @import("periph/gpio.zig");
    pub const gpt = @import("periph/gpt.zig");
    pub const icu = @import("periph/icu.zig");
    pub const ipc = @import("periph/ipc.zig");
    pub const lvd = @import("periph/lvd.zig");
    pub const maci = @import("periph/maci.zig");
    pub const mram = @import("periph/mram.zig");
    pub const mram_otp = @import("periph/mram_otp.zig");
    pub const mstp = @import("periph/mstp.zig");
    pub const nvic = @import("periph/nvic.zig");
    pub const pdctr = @import("periph/pdctr.zig");
    pub const pdm = @import("periph/pdm.zig");
    pub const poeg = @import("periph/poeg.zig");
    pub const prcr = @import("periph/prcr.zig");
    pub const registry = @import("periph/registry.zig");
    pub const reset = @import("periph/reset.zig");
    pub const rtc = @import("periph/rtc.zig");
    pub const rtc_clock = @import("periph/rtc_clock.zig");
    pub const scb = @import("periph/scb.zig");
    pub const sci = @import("periph/sci.zig");
    pub const spi = @import("periph/spi.zig");
    pub const sram = @import("periph/sram.zig");
    pub const ssie = @import("periph/ssie.zig");
    pub const ulpt = @import("periph/ulpt.zig");
    pub const wdt = @import("periph/wdt.zig");
    pub const xspi = @import("periph/xspi.zig");
    pub const xspi_flash = @import("periph/xspi_flash.zig");
};

pub const board = struct {
    pub const Board = @import("board/board.zig").Board;
    pub const report = @import("board/report.zig");
};
