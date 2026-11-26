//! SDHI register offsets, status bits, options, and command indices.

pub const off = struct {
    pub const sd_cmd: u32 = 0x000;
    pub const sd_arg: u32 = 0x008;
    pub const sd_stop: u32 = 0x010;
    pub const sd_seccnt: u32 = 0x014;
    pub const sd_rsp10: u32 = 0x018;
    pub const sd_rsp32: u32 = 0x020;
    pub const sd_rsp54: u32 = 0x028;
    pub const sd_rsp76: u32 = 0x030;
    pub const sd_info1: u32 = 0x038;
    pub const sd_info2: u32 = 0x03C;
    pub const sd_option: u32 = 0x050;
    pub const sd_buf0: u32 = 0x060;
    pub const soft_rst: u32 = 0x1C0;
};

/// The status bits the firmware polls.
pub const status = struct {
    /// SD_INFO1.RSPEND, a response was received.
    pub const rspend: u32 = 0x0000_0001;
    /// SD_INFO2.BRE, the read buffer holds a block.
    pub const bre: u32 = 0x0000_0100;
    /// SD_INFO2.BWE, the write buffer has room.
    pub const bwe: u32 = 0x0000_0200;
};

/// SD_OPTION's bus-width selectors, and what they decode to.
pub const option = struct {
    pub const width_1bit: u32 = 0x0000_8000;
    pub const width_8bit: u32 = 0x0000_2000;
};

/// SOFT_RST bit 0: clear asserts reset, set releases it.
pub const soft_rst = struct {
    pub const release: u32 = 0x0000_0001;
};

/// The commands the engine decodes. The index is the low six bits of
/// SD_CMD.
pub const cmd = struct {
    pub const go_idle: u32 = 0;
    pub const send_cid: u32 = 2;
    pub const send_rca: u32 = 3;
    pub const select: u32 = 7;
    pub const if_cond: u32 = 8;
    pub const send_csd: u32 = 9;
    pub const stop: u32 = 12;
    pub const set_blocklen: u32 = 16;
    pub const read_single: u32 = 17;
    pub const read_multi: u32 = 18;
    pub const write_single: u32 = 24;
    pub const write_multi: u32 = 25;
    pub const op_cond: u32 = 41;
    pub const app_cmd: u32 = 55;
    pub const index_mask: u32 = 0x3F;
};
