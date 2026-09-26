//! What the host puts on the e-paper line and what the controller puts back:
//! the IT8951's preamble words, its user commands, the pixel-format decode,
//! the device-info block, and the read burst a host clocks out of it.
//!
//! Its own file for the same reason sd_reply.zig is: this is vocabulary and
//! staging with no protocol decisions in it. eink.zig decides what to
//! answer; this holds the answer and hands it over one byte per exchange,
//! which is the only rate the wire has.

/// The three words a transaction opens with (IT8951 DS 3.4, table 3-3).
pub const preamble = struct {
    pub const command: u16 = 0x6000;
    pub const write: u16 = 0x0000;
    pub const read: u16 = 0x1000;
};

/// The user commands the `ra8_epaper` driver issues (IT8951 DS 4.2).
pub const Command = enum(u16) {
    sys_run = 0x0001,
    sleep = 0x0003,
    reg_read = 0x0010,
    reg_write = 0x0011,
    load_area = 0x0021,
    load_end = 0x0022,
    display_area = 0x0034,
    vcom = 0x0039,
    device_info = 0x0302,
    _,
};

/// Where each command's arguments sit in its own data-word stream.
pub const arg = struct {
    pub const reg_address: u16 = 0;
    pub const reg_value: u16 = 1;
    /// LD_IMG_AREA arg0: endianness, pixel format and rotation.
    pub const load_mode: u16 = 0;
    pub const load_width: u16 = 3;
    pub const load_height: u16 = 4;
    pub const load_first_pixel: u16 = 5;
    pub const display_waveform: u16 = 4;
    pub const vcom_direction: u16 = 0;
    pub const vcom_value: u16 = 1;
};

pub const vcom = struct {
    pub const get: u16 = 0x0000;
    pub const set: u16 = 0x0001;
    /// What a vendor-provisioned driver board powers up holding, in
    /// millivolts. dev's value, and a modelled controller's rather than any
    /// real panel's: a real one carries its VCOM on the flex cable.
    pub const power_on_mv: u16 = 1530;
};

/// The one register whose value the controller owns rather than the host:
/// LUT busy status, zero meaning idle, which is what the display poll waits
/// for.
pub const reg = struct {
    pub const lutafsr: u16 = 0x1224;
    pub const idle: u16 = 0;
};

/// The panel geometry the device-info block reports.
pub const panel = struct {
    pub const width: u16 = 128;
    pub const height: u16 = 128;
};

/// Byte assembly and the LD_IMG_AREA mode word's format field.
pub const wire = struct {
    pub const byte_bits: u4 = 8;
    pub const byte_mask: u16 = 0xFF;
    pub const word_bits: u16 = 16;
    pub const format_shift: u4 = 4;
    pub const format_mask: u16 = 0x3;
    /// The line when the controller is not driving it.
    pub const idle_byte: u8 = 0x00;
    /// Bytes in a read burst: the dummy word, then the value word.
    pub const burst_bytes: usize = 4;
};

/// Pixels one 16-bit data word carries, by the mode word's format field:
/// 2 bpp = 0, 3 bpp = 1, 4 bpp = 2, 8 bpp = 3.
pub fn pixelsPerWord(code: u16) u16 {
    return switch (code & wire.format_mask) {
        0 => wire.word_bits / 2,
        1 => wire.word_bits / 3,
        2 => wire.word_bits / 4,
        else => wire.word_bits / 8,
    };
}

/// The forty-byte GET_DEV_INFO block, as twenty words. The driver drains and
/// discards it, so only the geometry is filled in.
pub const info = struct {
    pub const words: u16 = 20;

    pub fn word(index: u16) u16 {
        return switch (index) {
            0 => panel.width,
            1 => panel.height,
            else => 0,
        };
    }
};

/// A read burst: the dummy word the controller clocks out first, then the
/// value. The driver's read_data16 takes exactly these four bytes.
pub const Burst = struct {
    buf: [wire.burst_bytes]u8 = .{0} ** wire.burst_bytes,
    len: usize = 0,
    pos: usize = 0,

    pub fn pending(self: *const Burst) bool {
        return self.pos < self.len;
    }

    /// The next byte of the burst. Only call it with one pending.
    pub fn next(self: *Burst) u8 {
        const byte = self.buf[self.pos];
        self.pos += 1;
        return byte;
    }

    /// Stage the dummy word and the value behind it.
    pub fn stage(self: *Burst, value: u16) void {
        self.buf[0] = wire.idle_byte;
        self.buf[1] = wire.idle_byte;
        self.buf[2] = @intCast((value >> wire.byte_bits) & wire.byte_mask);
        self.buf[3] = @intCast(value & wire.byte_mask);
        self.len = self.buf.len;
        self.pos = 0;
    }
};
