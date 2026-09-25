//! The test root. `zig build test` compiles this file, so every test file
//! under tests/ has to be listed here, and every test file mirrors the path
//! of the source file it covers (tests/periph/crc_test.zig covers
//! src/periph/crc.zig).
const std = @import("std");

test {
    _ = @import("core/cli_test.zig");
    _ = @import("core/disasm_test.zig");
    _ = @import("core/elf_test.zig");
    _ = @import("core/engine_test.zig");
    _ = @import("core/memmap_test.zig");
    _ = @import("periph/clocks_test.zig");
    _ = @import("periph/crc_test.zig");
    _ = @import("periph/doc_test.zig");
    _ = @import("periph/gpio_test.zig");
    _ = @import("periph/mstp_test.zig");
    _ = @import("periph/nvic_test.zig");
    _ = @import("periph/registry_test.zig");

    const ra8 = @import("ra8");
    std.testing.refAllDecls(ra8.core);
    std.testing.refAllDecls(ra8.periph);
}
