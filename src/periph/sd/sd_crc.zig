//! CRC16-CCITT (polynomial 0x1021, seeded zero), the checksum that follows a
//! data block on an SD card in SPI mode.
//!
//! Its own file because both directions need it and neither owns it: the card
//! stages one behind every block it hands out, and checks the one the host
//! sends behind every block it takes. Matches the firmware driver's
//! `ra8_sdmmc_spi_crc16`, so a block staged here validates there.

/// The CCITT polynomial, the one the SD physical layer names for a data block.
pub const poly: u16 = 0x1021;

/// The top bit of the register, shifted out on every step.
const msb: u16 = 0x8000;

pub fn crc16(data: []const u8) u16 {
    var crc: u16 = 0;
    for (data) |byte| {
        crc ^= @as(u16, byte) << 8;
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            const carried = crc & msb != 0;
            crc <<= 1;
            if (carried) crc ^= poly;
        }
    }
    return crc;
}
