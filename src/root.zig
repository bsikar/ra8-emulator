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
};

pub const periph = struct {
    pub const bkup = @import("periph/bkup.zig");
    pub const cac = @import("periph/cac.zig");
    pub const clocks = @import("periph/clocks.zig");
    pub const crc = @import("periph/crc.zig");
    pub const doc = @import("periph/doc.zig");
    pub const gpio = @import("periph/gpio.zig");
    pub const mstp = @import("periph/mstp.zig");
    pub const nvic = @import("periph/nvic.zig");
    pub const prcr = @import("periph/prcr.zig");
    pub const registry = @import("periph/registry.zig");
};
