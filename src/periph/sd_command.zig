//! The SPI-mode command set this card model answers.
//!
//! Its own file because the index is the one thing a caller outside the card
//! needs to name: the trace formats it, the card dispatches on it, and a test
//! asserts against it without reaching into the state machine that runs it.

/// The commands answered here. Non-exhaustive: anything else gets the plain
/// R1 a real card gives a command it does not implement in this mode.
pub const Command = enum(u8) {
    go_idle = 0,
    send_if_cond = 8,
    send_csd = 9,
    stop = 12,
    set_blocklen = 16,
    read_single = 17,
    read_multi = 18,
    write_single = 24,
    write_multi = 25,
    erase_start = 32,
    erase_end = 33,
    erase = 38,
    app_op_cond = 41,
    app_cmd = 55,
    read_ocr = 58,
    crc_on_off = 59,
    _,
};
