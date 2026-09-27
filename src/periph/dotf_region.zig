//! DOTF conversion area: which XSPI addresses a channel decrypts over.
//!
//! CONVAREAST and CONVAREAD do not hold a byte address. The bottom twelve
//! bits are reserved and the hardware scales the stored value by 4 KB, so a
//! region is 4 KB aligned and 4 KB granular (ra8_dotf_regs.h, HUM Ch 45.3.1
//! and 45.3.2 p 3049). The two registers also read back differently: the
//! start register's reserved field reads as zero, the end register's reads
//! as one, which the header quotes from the HUM outright ("These bits are
//! read as 1"). A driver that reads CONVAREAD back and compares it against
//! what it wrote is reading a value the hardware changed under it.
//!
//! Each channel is also bound to one XSPI window and decrypts nothing
//! outside it: DOTF0 over XSPI0 at 0x8000_0000..0x9FFF_FFFF, DOTF1 over
//! XSPI1 at 0x7000_0000..0x7FFF_FFFF (ra8_dotf_regs.h
//! ra8_dotf_xspi_window_t, HUM Ch 45.3 p 3049).

/// The 4 KB granule the address registers are scaled in.
pub const granule: u32 = 0x0000_1000;

/// CONVAREAST / CONVAREAD field split: the high twenty bits carry the value.
pub const field = struct {
    pub const address: u32 = 0xFFFF_F000;
    pub const reserved: u32 = 0x0000_0FFF;
};

/// What the reserved field of each register reads back as.
pub const reserved_reads = struct {
    pub const start: u32 = 0x0000_0000;
    pub const end: u32 = field.reserved;
};

/// One channel's XSPI window: the only addresses it can be asked to cover.
pub const Window = struct {
    lo: u32,
    hi: u32,

    pub fn holds(self: Window, target: u32) bool {
        return target >= self.lo and target <= self.hi;
    }
};

/// The window bound to a channel. A channel index this part does not have
/// covers nothing.
pub fn window(channel: usize) Window {
    return switch (channel) {
        0 => .{ .lo = 0x8000_0000, .hi = 0x9FFF_FFFF },
        1 => .{ .lo = 0x7000_0000, .hi = 0x7FFF_FFFF },
        else => .{ .lo = 0, .hi = 0 },
    };
}

/// The byte address a stored register value names.
pub fn address(stored: u32) u32 {
    return stored & field.address;
}

/// CONVAREAST as firmware reads it back.
pub fn startReadback(stored: u32) u32 {
    return address(stored) | reserved_reads.start;
}

/// CONVAREAD as firmware reads it back, reserved bits standing at one.
pub fn endReadback(stored: u32) u32 {
    return address(stored) | reserved_reads.end;
}

/// True when the pair names a region at all. An end below its start covers
/// nothing, which is how an unprogrammed channel reads.
pub fn programmed(start: u32, end: u32) bool {
    return address(end) >= address(start) and address(end) != 0;
}

/// True when the programmed region covers this address. The end register
/// names the last 4 KB page, so the region runs to the top of that page.
pub fn covers(start: u32, end: u32, target: u32) bool {
    if (!programmed(start, end)) return false;
    return target >= address(start) and target <= address(end) +| (granule - 1);
}

/// How many 4 KB pages the region spans.
pub fn pages(start: u32, end: u32) u32 {
    if (!programmed(start, end)) return 0;
    return ((address(end) - address(start)) / granule) + 1;
}
