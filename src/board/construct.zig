//! The initial value of every block the board holds.
//!
//! board.zig is the list of what a board is made of, and wiring.zig is the
//! order those blocks go onto the bus. This file is the third question and
//! the least interesting one: what each block starts as before anything has
//! been wired or run. It is here rather than in board.zig because the list
//! of parts and the construction of them are two subjects, and the list is
//! the one worth reading first.
//!
//! A field left `undefined` here is one that cannot exist yet: it needs a
//! pointer into the board that is still being built, so wiring.zig fills it
//! in during attach(). The comment on the field in board.zig says which.
const std = @import("std");

const Board = @import("board.zig").Board;

const periph = @import("../periph/registry.zig");
const acmphs = @import("../periph/acmphs/acmphs.zig");
const adc = @import("../periph/adc/adc.zig");
const agt = @import("../periph/agt/agt.zig");
const cac = @import("../periph/cac.zig");
const cache = @import("../periph/cache/cache.zig");
const canfd = @import("../periph/canfd/canfd.zig");
const ceu = @import("../periph/ceu.zig");
const crc = @import("../periph/crc.zig");
const dac = @import("../periph/dac/dac.zig");
const doc = @import("../periph/doc/doc.zig");
const dotf = @import("../periph/dotf/dotf.zig");
const dtc = @import("../periph/dtc/dtc.zig");
const elc = @import("../periph/elc/elc.zig");
const gpio = @import("../periph/gpio/gpio.zig");
const gpt = @import("../periph/gpt/gpt.zig");
const gptp = @import("../periph/gptp/gptp.zig");
const icu = @import("../periph/icu/icu.zig");
const ipc = @import("../periph/ipc/ipc.zig");
const iwdt = @import("../periph/iwdt/iwdt.zig");
const lvd = @import("../periph/lvd/lvd.zig");
const mipi_csi = @import("../periph/mipi/mipi_csi.zig");
const mipi_dsi = @import("../periph/mipi/mipi_dsi.zig");
const mipi_phy = @import("../periph/mipi/mipi_phy.zig");
const mpu = @import("../periph/mpu/mpu.zig");
const mpu_guard = @import("../core/mpu_guard.zig");
const mram = @import("../periph/mram/mram.zig");
const npu = @import("../periph/npu/npu.zig");
const pdm = @import("../periph/pdm.zig");
const pfs = @import("../periph/pfs/pfs.zig");
const poeg = @import("../periph/poeg.zig");
const prcr = @import("../periph/prcr.zig");
const reset = @import("../periph/reset.zig");
const rtc = @import("../periph/rtc/rtc.zig");
const sau = @import("../periph/sau.zig");
const scb = @import("../periph/scb.zig");
const fault_clear = @import("../periph/fault_clear.zig");
const sci = @import("../periph/sci/sci.zig");
const sd_card = @import("../periph/sd/sd_card.zig");
const sdhi = @import("../periph/sdhi/sdhi.zig");
const spi = @import("../periph/spi/spi.zig");
const sram = @import("../periph/sram/sram.zig");
const ssie = @import("../periph/ssie/ssie.zig");
const ulpt = @import("../periph/ulpt/ulpt.zig");
const wdt = @import("../periph/wdt/wdt.zig");
const xspi = @import("../periph/xspi/xspi.zig");

/// A fresh board, with nothing on the bus yet.
pub fn build(allocator: std.mem.Allocator) Board {
    return .{
        .bus = periph.Bus.init(allocator),
        .events = icu.Icu.init(),
        .links = elc.Elc.init(),
        .transfers = dtc.Dtc.init(),
        .transfers1 = dtc.Dtc.init(),
        .transfer_attribution = undefined,
        .dma = undefined,
        .pins = gpio.Gpio.init(),
        .pinfunc = pfs.Pfs.init(),
        .checksum = crc.Crc.init(),
        .dataops = doc.Doc.init(),
        .accuracy = cac.Cac.init(),
        .comparators = acmphs.Acmphs.init(),
        .capture = ceu.Ceu.init(),
        .analog = dac.Dac.init(),
        .adc = adc.Adc.init(),
        .shutoff = poeg.Poeg.init(),
        .protection = prcr.Prcr.init(),
        // Patched in attach(): the backup file has to point at this
        // board's own protection model, not a copy of it.
        .backup = undefined,
        .battery_switch = undefined,
        .oscillators = undefined,
        .subclk = undefined,
        .loco = undefined,
        .tree = undefined,
        .low_power = undefined,
        .plls = undefined,
        .gpt_clock = undefined,
        .voltage = undefined,
        .brownout = undefined,
        .ratios = undefined,
        .branches = undefined,
        .chip_attribution = undefined,
        .domains = undefined,
        .display = undefined,
        .raster = undefined,
        .serial = sci.Sci.init(),
        .spi = spi.Spi.init(),
        .sd = sd_card.Card.init(allocator),
        .flash = xspi.Xspi.init(allocator),
        .octa = undefined,
        .cipher = dotf.Dotf.init(),
        .card = sdhi.Sdhi.init(allocator),
        .options = mram.Mram.init(allocator),
        .ecc = sram.Sram.init(),
        .audio = ssie.Ssie.init(),
        .microphone = pdm.Pdm.init(),
        .clock = rtc.Rtc.init(),
        .can = canfd.Canfd.init(),
        .mailbox = ipc.Ipc.init(),
        .npu = npu.Npu.init(),
        .lowpower = ulpt.Ulpt.init(),
        .interval = agt.Agt.init(),
        .pwm = gpt.Gpt.init(),
        .ptp = gptp.Gptp.init(),
        .monitors = lvd.Lvd.init(),
        .watchdog = wdt.Wdt.init(),
        .heartbeat = iwdt.Iwdt.init(),
        .link = mipi_phy.MipiPhy.init(),
        .receiver = mipi_csi.MipiCsi.init(),
        .host = mipi_dsi.MipiDsi.init(),
        .causes = reset.Reset.init(),
        .control = scb.Scb.init(),
        .clears = fault_clear.Clears.init(),
        .caches = cache.Cache.init(),
        .regions = mpu.Mpu.init(),
        .guard = mpu_guard.Guard.init(),
        .partitions = sau.Sau.init(),
    };
}
