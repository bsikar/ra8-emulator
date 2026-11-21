//! The ELC event numbers the console channel raises (HUM Ch 19 Table 19.3,
//! FSP `bsp_elc.h` for ra8d2: SCI8_RXI 0x122, _TXI 0x123, _TEI 0x124). A
//! firmware that routes one of these writes the same number into an IELSR
//! slot, and src/chip/periph/icu/icu.zig matches the raised event to that slot.
//!
//! Only the console channel has modelled event numbers, the same limit dev
//! draws: the other nine channels raise nothing until something needs them.
pub const rxi: u16 = 0x122;
pub const txi: u16 = 0x123;
pub const tei: u16 = 0x124;

/// ELC console channel on FPB-RA8E1 (`R20UT5474EG0100` Table 2 p. 13).
pub const ra8e1_console_channel: usize = 9;

/// ICU event numbers for the board console SCI (`RXI`, `TXI`, `TEI`).
pub const ConsoleEvents = struct { rxi: u16, txi: u16, tei: u16 };

/// RA8D2/RA8P1 `SCI8` default console events.
pub const ra8d2_console: ConsoleEvents = .{ .rxi = rxi, .txi = txi, .tei = tei };
/// RA8E1 `SCI9` event numbers (`R01UH1129EJ0110` Table 13.4).
pub const ra8e1_console: ConsoleEvents = .{ .rxi = 0x163, .txi = 0x164, .tei = 0x165 };
