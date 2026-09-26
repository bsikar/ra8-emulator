//! The test root. `zig build test` compiles this file, so every test file
//! under tests/ has to be listed here, and every test file mirrors the path
//! of the source file it covers (tests/periph/crc_test.zig covers
//! src/periph/crc.zig, tests/tools/gate_test.zig covers tools/gate.zig).
const std = @import("std");

test {
    _ = @import("board/board_test.zig");
    _ = @import("core/cli_test.zig");
    _ = @import("core/disasm_test.zig");
    _ = @import("core/elf_test.zig");
    _ = @import("core/engine_test.zig");
    _ = @import("core/lob_hook_test.zig");
    _ = @import("core/lob_test.zig");
    _ = @import("core/memmap_test.zig");
    _ = @import("core/part_test.zig");
    _ = @import("periph/adc_scan_test.zig");
    _ = @import("periph/adc_test.zig");
    _ = @import("periph/agt_test.zig");
    _ = @import("periph/bkup_test.zig");
    _ = @import("periph/cac_test.zig");
    _ = @import("periph/canfd_fifo_test.zig");
    _ = @import("periph/canfd_test.zig");
    _ = @import("periph/ceu_test.zig");
    _ = @import("periph/clocks_test.zig");
    _ = @import("periph/crc_test.zig");
    _ = @import("periph/dac_test.zig");
    _ = @import("periph/dma_bank_test.zig");
    _ = @import("periph/dmac_test.zig");
    _ = @import("periph/dmac_xfer_test.zig");
    _ = @import("periph/doc_test.zig");
    _ = @import("periph/drw_blend_test.zig");
    _ = @import("periph/drw_test.zig");
    _ = @import("periph/dtc_test.zig");
    _ = @import("periph/dtc_xfer_test.zig");
    _ = @import("periph/eink_test.zig");
    _ = @import("periph/eink_wire_test.zig");
    _ = @import("periph/elc_test.zig");
    _ = @import("periph/glcdc_test.zig");
    _ = @import("periph/gpio_test.zig");
    _ = @import("periph/gpt_test.zig");
    _ = @import("periph/gptp_test.zig");
    _ = @import("periph/gptp_timer_test.zig");
    _ = @import("periph/icu_test.zig");
    _ = @import("periph/lvd_test.zig");
    _ = @import("periph/maci_test.zig");
    _ = @import("periph/mram_otp_test.zig");
    _ = @import("periph/mram_test.zig");
    _ = @import("periph/mstp_test.zig");
    _ = @import("periph/npu_cmd_test.zig");
    _ = @import("periph/npu_test.zig");
    _ = @import("periph/nvic_test.zig");
    _ = @import("periph/pdctr_test.zig");
    _ = @import("periph/pdm_test.zig");
    _ = @import("periph/ipc_test.zig");
    _ = @import("periph/poeg_test.zig");
    _ = @import("periph/prcr_test.zig");
    _ = @import("periph/registry_test.zig");
    _ = @import("periph/reset_test.zig");
    _ = @import("periph/rtc_clock_test.zig");
    _ = @import("periph/rtc_test.zig");
    _ = @import("periph/scb_test.zig");
    _ = @import("periph/sci_test.zig");
    _ = @import("periph/sd_card_test.zig");
    _ = @import("periph/sd_crc_test.zig");
    _ = @import("periph/sd_image_test.zig");
    _ = @import("periph/sd_write_test.zig");
    _ = @import("periph/sdhi_card_test.zig");
    _ = @import("periph/sdhi_test.zig");
    _ = @import("periph/sdhi_xfer_test.zig");
    _ = @import("periph/spi_test.zig");
    _ = @import("periph/sram_test.zig");
    _ = @import("periph/ssie_test.zig");
    _ = @import("periph/ulpt_test.zig");
    _ = @import("periph/wdt_test.zig");
    _ = @import("periph/xspi_flash_test.zig");
    _ = @import("periph/xspi_test.zig");
    _ = @import("tools/gate_test.zig");

    const ra8 = @import("ra8");
    std.testing.refAllDecls(ra8.core);
    std.testing.refAllDecls(ra8.periph);
    std.testing.refAllDecls(ra8.board);
}
